// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host implementation of the device-smoke seam for the broker-tier exchange.
// The application still owns the agent and emits the same JSONL records as a
// device run. This seam supplies a real MQTTNIO client through the public
// EmbeddedMQTTClient boundary.

import DeviceSmokeApplication
import EmbeddedMQTTClient
import Foundation
import MQTTNIO
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum HostAgentConfiguration {
    nonisolated(unsafe) static var brokerHost = "127.0.0.1"
    nonisolated(unsafe) static var brokerPort = 1883
    nonisolated(unsafe) static var role: UInt32 = 1
    nonisolated(unsafe) static var clientID = "axoloty-host-smoke-agent"
    nonisolated(unsafe) static var controlDirectory = URL(fileURLWithPath: "/tmp/axoloty-host-agent")
    nonisolated(unsafe) static var inProcess = false

    static let agentID = "32400000-0000-4000-8000-000000000001"
    static let objectID = "32400000-0000-4000-8000-000000000002"
    static let namespace = "axoloty-embedded"

    static func load(from environment: [String: String]) throws {
        brokerHost = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        brokerPort = try parsePort(environment["WIRE_BROKER_PORT"] ?? "1883")
        role = try parseRole(environment["HOST_AGENT_ROLE"] ?? "1")
        clientID = environment["HOST_AGENT_CLIENT_ID"] ?? "axoloty-host-smoke-agent"
        guard !clientID.isEmpty else { throw HostAgentError.configuration("HOST_AGENT_CLIENT_ID is empty") }
        controlDirectory = URL(fileURLWithPath: environment["HOST_AGENT_CONTROL_DIR"] ?? "/tmp/axoloty-host-agent")
        inProcess = environment["HOST_AGENT_BROKER_MODE"] == "in-process"
        try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
    }

    static func parsePort(_ value: String) throws -> Int {
        guard let port = Int(value), (1...65_535).contains(port) else {
            throw HostAgentError.configuration("invalid WIRE_BROKER_PORT")
        }
        return port
    }

    static func parseRole(_ value: String) throws -> UInt32 {
        guard let role = UInt32(value), role == 1 || role == 2 else {
            throw HostAgentError.configuration("HOST_AGENT_ROLE must be 1 or 2")
        }
        return role
    }

    static func markerURL(_ name: String) -> URL {
        controlDirectory.appendingPathComponent(name)
    }

    static func mark(_ name: String) {
        let url = markerURL(name)
        try? Data("ok\n".utf8).write(to: url, options: .atomic)
    }

    static func markerExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(name).path)
    }

    static func waitForMarker(_ name: String, deadlineMS: UInt32) -> Bool {
        let deadline = Date().addingTimeInterval(Double(deadlineMS) / 1_000.0)
        while !markerExists(name) {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }
}

enum HostAgentError: Error, CustomStringConvertible {
    case configuration(String)
    case transport(String)
    case protocolFailure(String)

    var description: String {
        switch self {
        case .configuration(let message): return message
        case .transport(let message): return message
        case .protocolFailure(let message): return message
        }
    }
}

fileprivate struct HostMQTTMessage: Sendable {
    let topic: String
    let payload: [UInt8]
}

/// A synchronous façade over one real MQTTNIO client.
final class HostMQTTSession: @unchecked Sendable {
    static let shared = HostMQTTSession()

    private let stateLock = NIOLock()
    private let messageCondition = NSCondition()
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var client: MQTTClient?
    private var subscriptions: [String] = []
    private var messages: [HostMQTTMessage] = []
    private var configuredWill: (topic: String, payload: [UInt8])?
    private var reconnectWill: (topic: String, payload: [UInt8])?
    private var forceDisconnected = false

    private init() {}

    func configureLastWill(topic: UnsafePointer<UInt8>, topicLength: Int32,
                           payload: UnsafePointer<UInt8>, payloadLength: Int32) -> Bool {
        guard topicLength > 0, payloadLength >= 0 else { return false }
        let topicBytes = Array(UnsafeBufferPointer(start: topic, count: Int(topicLength)))
        let payloadBytes = Array(UnsafeBufferPointer(start: payload, count: Int(payloadLength)))
        let topicText = String(decoding: topicBytes, as: UTF8.self)
        guard !topicText.isEmpty else { return false }
        stateLock.withLock { configuredWill = (topicText, payloadBytes) }
        return true
    }

    func armReconnectWill(topic: String, payload: [UInt8]) {
        stateLock.withLock { reconnectWill = (topic, payload) }
    }

    func connect() -> Bool {
        let will = stateLock.withLock { configuredWill }
        for attempt in 0..<3 {
            let candidate = makeClient()
            do {
                _ = try candidate.connect(cleanSession: true, will: mqttWill(will)).wait()
                stateLock.withLock { client = candidate; forceDisconnected = false }
                HostAgentConfiguration.mark("connected")
                return true
            } catch {
                shutdownClient(candidate)
                if attempt < 2 { usleep(100_000) }
            }
        }
        return false
    }

    func subscribe(topic: UnsafePointer<UInt8>, topicLength: Int32) -> Bool {
        guard let topicText = decode(topic, length: topicLength) else { return false }
        guard let client = stateLock.withLock({ self.client }) else { return false }
        for attempt in 0..<3 {
            do {
                _ = try client.subscribe(to: [MQTTSubscribeInfo(topicFilter: topicText, qos: .atMostOnce)]).wait()
                stateLock.withLock {
                    if !subscriptions.contains(topicText) { subscriptions.append(topicText) }
                }
                HostAgentConfiguration.mark("subscribed")
                return true
            } catch {
                if attempt < 2 { usleep(100_000) }
            }
        }
        return false
    }

    func publish(topic: UnsafePointer<UInt8>, topicLength: Int32,
                 payload: UnsafePointer<UInt8>, payloadLength: Int32) -> Bool {
        guard let topicText = decode(topic, length: topicLength), payloadLength >= 0 else { return false }
        let payloadBytes = Array(UnsafeBufferPointer(start: payload, count: Int(payloadLength)))
        guard let client = stateLock.withLock({ self.client }) else { return false }
        do {
            _ = try client.publish(
                to: topicText,
                payload: ByteBuffer(bytes: payloadBytes),
                qos: .atMostOnce,
                retain: false
            ).wait()
            return true
        } catch {
            return false
        }
    }

    func waitForReconnect(deadlineMS: UInt32) -> Bool {
        if HostAgentConfiguration.inProcess,
           !HostAgentConfiguration.waitForMarker("reconnect-requested", deadlineMS: deadlineMS) {
            return false
        }

        guard let oldClient = stateLock.withLock({ client }) else { return false }
        stateLock.withLock { client = nil }
        // A reconnect is not an abnormal disconnect. Close the old session
        // cleanly so its configured last will is reserved for the broker
        // disconnect injection later in the exchange.
        _ = try? oldClient.disconnect().wait()
        shutdownClient(oldClient)

        let will = stateLock.withLock { reconnectWill ?? configuredWill }
        for attempt in 0..<3 {
            let candidate = makeClient()
            do {
                _ = try candidate.connect(cleanSession: true, will: mqttWill(will)).wait()
                for topic in stateLock.withLock({ subscriptions }) {
                    _ = try candidate.subscribe(
                        to: [MQTTSubscribeInfo(topicFilter: topic, qos: .atMostOnce)]
                    ).wait()
                }
                stateLock.withLock { client = candidate; forceDisconnected = false }
                HostAgentConfiguration.mark("reconnected")
                return true
            } catch {
                shutdownClient(candidate)
                if attempt < 2 { usleep(100_000) }
            }
        }
        return false
    }

    fileprivate func nextMessage(matching predicate: (HostMQTTMessage) -> Bool, deadlineMS: UInt32) -> HostMQTTMessage? {
        let deadline = Date().addingTimeInterval(Double(deadlineMS) / 1_000.0)
        while true {
            messageCondition.lock()
            if let index = messages.firstIndex(where: predicate) {
                let message = messages.remove(at: index)
                messageCondition.unlock()
                return message
            }
            if Date() >= deadline {
                messageCondition.unlock()
                return nil
            }
            _ = messageCondition.wait(until: Date().addingTimeInterval(0.05))
            messageCondition.unlock()
        }
    }

    func disconnect() -> Bool {
        guard let client = stateLock.withLock({ self.client }) else {
            return stateLock.withLock { forceDisconnected }
        }
        do {
            _ = try client.disconnect().wait()
            stateLock.withLock { self.client = nil }
            shutdownClient(client)
            return true
        } catch {
            stateLock.withLock { forceDisconnected = true; self.client = nil }
            shutdownClient(client)
            return false
        }
    }

    func markInjectedDisconnect() {
        let oldClient = stateLock.withLock { () -> MQTTClient? in
            forceDisconnected = true
            defer { client = nil }
            return client
        }
        if let oldClient { shutdownClient(oldClient) }
    }

    private func makeClient() -> MQTTClient {
        let client = MQTTClient(
            host: HostAgentConfiguration.brokerHost,
            port: HostAgentConfiguration.brokerPort,
            identifier: HostAgentConfiguration.clientID,
            eventLoopGroupProvider: .shared(eventLoopGroup),
            logger: nil,
            configuration: MQTTClient.Configuration(
                keepAliveInterval: .seconds(30),
                timeout: .seconds(5)
            )
        )
        client.addPublishListener(named: "host-agent-client") { [weak self] result in
            guard case let .success(info) = result, let self else { return }
            var payload = info.payload
            let bytes = payload.readBytes(length: payload.readableBytes) ?? []
            self.messageCondition.lock()
            self.messages.append(HostMQTTMessage(topic: info.topicName, payload: bytes))
            self.messageCondition.broadcast()
            self.messageCondition.unlock()
        }
        return client
    }

    private func mqttWill(_ will: (topic: String, payload: [UInt8])?) -> (topicName: String, payload: ByteBuffer, qos: MQTTQoS, retain: Bool)? {
        will.map {
            (topicName: $0.topic, payload: ByteBuffer(bytes: $0.payload), qos: MQTTQoS.atMostOnce, retain: false)
        }
    }

    private func decode(_ pointer: UnsafePointer<UInt8>, length: Int32) -> String? {
        guard length > 0 else { return nil }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
    }

    private func shutdownClient(_ client: MQTTClient) {
        let semaphore = DispatchSemaphore(value: 0)
        client.shutdown(queue: .global()) { _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + .seconds(2))
    }

    deinit {
        if let client = stateLock.withLock({ self.client }) { shutdownClient(client) }
        try? eventLoopGroup.syncShutdownGracefully()
    }
}

@_cdecl("axoloty_mqtt_configure_last_will")
func hostMQTTConfigureLastWill(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 {
    HostMQTTSession.shared.configureLastWill(
        topic: topic, topicLength: topicLength,
        payload: payload, payloadLength: payloadLength
    ) ? 1 : 0
}

@_cdecl("axoloty_mqtt_connect_wait")
func hostMQTTConnectWait(_ deadlineMS: UInt32) -> Int32 {
    _ = deadlineMS
    return HostMQTTSession.shared.connect() ? 1 : 0
}

@_cdecl("axoloty_mqtt_subscribe_wait")
func hostMQTTSubscribeWait(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ deadlineMS: UInt32
) -> Int32 {
    _ = deadlineMS
    return HostMQTTSession.shared.subscribe(topic: topic, topicLength: topicLength) ? 1 : 0
}

@_cdecl("axoloty_mqtt_publish")
func hostMQTTPublish(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 {
    HostMQTTSession.shared.publish(
        topic: topic, topicLength: topicLength,
        payload: payload, payloadLength: payloadLength
    ) ? 1 : 0
}

@_cdecl("axoloty_mqtt_wait_loopback")
func hostMQTTWaitLoopback(_ deadlineMS: UInt32) -> Int32 {
    _ = deadlineMS
    return 1
}

@_cdecl("axoloty_mqtt_reconnect_wait")
func hostMQTTReconnectWait(_ deadlineMS: UInt32) -> Int32 {
    HostMQTTSession.shared.waitForReconnect(deadlineMS: deadlineMS) ? 1 : 0
}

@_cdecl("axoloty_mqtt_disconnect")
func hostMQTTDisconnect() -> Int32 {
    HostMQTTSession.shared.disconnect() ? 1 : 0
}

@_silgen_name("axoloty_static_agent_prepare")
private func hostStaticAgentPrepare(
    _ role: Int32, _ kind: Int32,
    _ topic: UnsafeMutablePointer<UInt8>, _ topicCapacity: Int32,
    _ payload: UnsafeMutablePointer<UInt8>, _ payloadCapacity: Int32,
    _ topicLength: UnsafeMutablePointer<Int32>, _ payloadLength: UnsafeMutablePointer<Int32>
) -> Int32

@_silgen_name("axoloty_static_agent_receive")
private func hostStaticAgentReceive(
    _ role: Int32,
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32,
    _ outputTopic: UnsafeMutablePointer<UInt8>, _ outputTopicCapacity: Int32,
    _ outputPayload: UnsafeMutablePointer<UInt8>, _ outputPayloadCapacity: Int32,
    _ outputTopicLength: UnsafeMutablePointer<Int32>, _ outputPayloadLength: UnsafeMutablePointer<Int32>
) -> Int32

private func preparedMessage(role: UInt32, kind: Int32) -> (topic: [UInt8], payload: [UInt8])? {
    var topic = Array(repeating: UInt8(0), count: 256)
    var payload = Array(repeating: UInt8(0), count: 2_048)
    var topicLength: Int32 = 0
    var payloadLength: Int32 = 0
    let prepared = topic.withUnsafeMutableBufferPointer { topicBuffer in
        payload.withUnsafeMutableBufferPointer { payloadBuffer in
            hostStaticAgentPrepare(
                Int32(role), kind,
                topicBuffer.baseAddress!, Int32(topicBuffer.count),
                payloadBuffer.baseAddress!, Int32(payloadBuffer.count),
                &topicLength, &payloadLength
            )
        }
    }
    guard prepared != 0, topicLength > 0, payloadLength >= 0 else { return nil }
    topic.removeSubrange(Int(topicLength)..<topic.count)
    payload.removeSubrange(Int(payloadLength)..<payload.count)
    return (topic, payload)
}

private func receiveMessage(role: UInt32, _ message: HostMQTTMessage) -> (action: Int32, response: (topic: [UInt8], payload: [UInt8])?) {
    var outputTopic = Array(repeating: UInt8(0), count: 256)
    var outputPayload = Array(repeating: UInt8(0), count: 2_048)
    var outputTopicLength: Int32 = 0
    var outputPayloadLength: Int32 = 0
    let action = message.topic.utf8.withContiguousStorageIfAvailable { topicBytes in
        message.payload.withUnsafeBufferPointer { payloadBytes in
            outputTopic.withUnsafeMutableBufferPointer { topicOutput in
                outputPayload.withUnsafeMutableBufferPointer { payloadOutput in
                    hostStaticAgentReceive(
                        Int32(role),
                        topicBytes.baseAddress!, Int32(topicBytes.count),
                        payloadBytes.baseAddress!, Int32(payloadBytes.count),
                        topicOutput.baseAddress!, Int32(topicOutput.count),
                        payloadOutput.baseAddress!, Int32(payloadOutput.count),
                        &outputTopicLength, &outputPayloadLength
                    )
                }
            }
        }
    } ?? -1
    guard action == 1, outputTopicLength > 0, outputPayloadLength >= 0 else {
        return (action, nil)
    }
    outputTopic.removeSubrange(Int(outputTopicLength)..<outputTopic.count)
    outputPayload.removeSubrange(Int(outputPayloadLength)..<outputPayload.count)
    return (action, (outputTopic, outputPayload))
}

private func runHostAgentExchange(_ deadlineMS: UInt32, filter: UnsafePointer<UInt8>, length: Int32) -> UInt32 {
    let session = HostMQTTSession.shared
    let role = HostAgentConfiguration.role
    let filterText = String(decoding: UnsafeBufferPointer(start: filter, count: Int(length)), as: UTF8.self)
    var client = EmbeddedMQTTClient()
    var result: UInt32 = 1 | 2

    guard let deadvertise = preparedMessage(role: role, kind: 4) else { return result }
    let configured = deadvertise.topic.withUnsafeBufferPointer { topic in
        deadvertise.payload.withUnsafeBufferPointer { payload in
            client.configureLastWill(
                topic: topic.baseAddress!, topicLength: Int32(topic.count),
                payload: payload.baseAddress!, payloadLength: Int32(payload.count)
            )
        }
    }
    guard configured, client.connect(deadlineMS: deadlineMS) else { return 0 }
    result |= 4

    let subscribed = filterText.utf8.withContiguousStorageIfAvailable { bytes in
        client.subscribe(topic: bytes.baseAddress!, topicLength: Int32(bytes.count), deadlineMS: deadlineMS)
    } ?? false
    guard subscribed else { return result }
    result |= 8

    session.armReconnectWill(topic: String(decoding: deadvertise.topic, as: UTF8.self), payload: deadvertise.payload)
    guard client.waitForReconnect(deadlineMS: deadlineMS) else { return result }
    result |= 512

    guard role == 1, let advertise = preparedMessage(role: role, kind: 1) else {
        let disconnected = client.disconnect()
        return result | (disconnected ? 256 : 0)
    }
    let advertisePublished = advertise.topic.withUnsafeBufferPointer { topic in
        advertise.payload.withUnsafeBufferPointer { payload in
            client.publish(
                topic: topic.baseAddress!, topicLength: Int32(topic.count),
                payload: payload.baseAddress!, payloadLength: Int32(payload.count)
            )
        }
    }
    guard advertisePublished else { return result }
    result |= 16
    HostAgentConfiguration.mark("advertised")

    guard let discover = session.nextMessage(matching: { $0.topic.contains("/DSC/") }, deadlineMS: deadlineMS) else {
        return result
    }
    let response = receiveMessage(role: role, discover)
    guard response.action == 1, let responsePayload = response.response else { return result }
    result |= 32
    let resolved = responsePayload.topic.withUnsafeBufferPointer { topic in
        responsePayload.payload.withUnsafeBufferPointer { payload in
            client.publish(
                topic: topic.baseAddress!, topicLength: Int32(topic.count),
                payload: payload.baseAddress!, payloadLength: Int32(payload.count)
            )
        }
    }
    guard resolved else { return result }
    result |= 64
    HostAgentConfiguration.mark("resolved")

    if HostAgentConfiguration.inProcess {
        guard HostAgentConfiguration.waitForMarker("disconnect-requested", deadlineMS: deadlineMS) else { return result }
        session.markInjectedDisconnect()
    } else {
        let published = deadvertise.topic.withUnsafeBufferPointer { topic in
            deadvertise.payload.withUnsafeBufferPointer { payload in
                client.publish(
                    topic: topic.baseAddress!, topicLength: Int32(topic.count),
                    payload: payload.baseAddress!, payloadLength: Int32(payload.count)
                )
            }
        }
        guard published else { return result }
    }
    result |= 128

    if client.disconnect() { result |= 256 }
    return result
}

@inline(__always)
private func hostPrint(_ message: UnsafePointer<CChar>) {
    fputs(message, stdout)
    fflush(stdout)
}

@inline(__always)
private func hostPrintUInt(_ label: UnsafePointer<CChar>, _ value: UInt32) {
    fputs(label, stdout)
    fputs(String(value), stdout)
    fflush(stdout)
}

@inline(__always)
private func hostNowMicroseconds() -> Int64 {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return Int64(now.tv_sec) * 1_000_000 + Int64(now.tv_nsec) / 1_000
}

@inline(__always)
private func hostDelay(_ ticks: UInt32) {
    usleep(useconds_t(ticks) * 1_000)
}

@inline(__always)
private func hostRestart() {
    HostAgentConfiguration.mark("restart")
    fputs("{\"host\":\"restart\"}\n", stdout)
    fflush(stdout)
    exit(0)
}

@inline(__always) private func hostNetworkConfigured() -> Int32 { 1 }
@inline(__always) private func hostNetworkRole() -> UInt32 { HostAgentConfiguration.role }
@inline(__always) private func hostNetworkScenario() -> UInt32 { 0 }
@inline(__always) private func hostNetworkPrepare(_ deadline: UInt32) -> UInt32 { _ = deadline; return 3 }
@inline(__always) private func hostNetworkCopyTopic(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int32) -> Int32 {
    let value = Array("axoloty/host/loopback".utf8)
    guard capacity > Int32(value.count) else { return 0 }
    for index in value.indices { buffer[index] = value[index] }
    return Int32(value.count)
}
@inline(__always) private func hostNetworkCopyPayload(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int32) -> Int32 {
    let value = Array("host-loopback".utf8)
    guard capacity >= Int32(value.count) else { return 0 }
    for index in value.indices { buffer[index] = value[index] }
    return Int32(value.count)
}
@inline(__always) private func hostNetworkCleanup() -> UInt32 { 1 }
@inline(__always) private func hostFreeInternalHeap() -> UInt32 { 262_144 }
@inline(__always) private func hostMinFreeInternalHeap() -> UInt32 { 196_608 }
@inline(__always) private func hostLargestInternalBlock() -> UInt32 { 131_072 }
@inline(__always) private func hostMainStackHighWater() -> UInt32 { 4_096 }
@inline(__always) private func hostMainStackSize() -> UInt32 { 131_072 }
@inline(__always) private func hostResetReason() -> UInt32 { 0 }
@inline(__always) private func hostHeapTraceBegin() -> Int32 { 1 }
@inline(__always) private func hostHeapTraceEnd() -> UInt32 { 0 }

private func hostAgentTest(
    _ deadline: UInt32, _ filter: UnsafePointer<UInt8>, _ length: Int32
) -> UInt32 {
    runHostAgentExchange(deadline, filter: filter, length: length)
}

private func hostDeviceDisplayName(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int32) -> Int32 {
    let value = Array("Host Smoke".utf8)
    guard capacity > Int32(value.count) else { return -1 }
    for index in value.indices { buffer[index] = value[index] }
    return Int32(value.count)
}

func hostAgentSmokeSeam() -> DeviceSmokeSeam {
    DeviceSmokeSeam(
        print: hostPrint,
        printUInt: hostPrintUInt,
        nowMicroseconds: hostNowMicroseconds,
        delay: hostDelay,
        restart: hostRestart,
        freeInternalHeap: hostFreeInternalHeap,
        minFreeInternalHeap: hostMinFreeInternalHeap,
        largestInternalBlock: hostLargestInternalBlock,
        mainStackHighWater: hostMainStackHighWater,
        mainStackSize: hostMainStackSize,
        resetReason: hostResetReason,
        heapTraceBegin: hostHeapTraceBegin,
        heapTraceEnd: hostHeapTraceEnd,
        networkConfigured: hostNetworkConfigured,
        networkRole: hostNetworkRole,
        networkScenario: hostNetworkScenario,
        networkPrepare: hostNetworkPrepare,
        networkCopyTopic: hostNetworkCopyTopic,
        networkCopyPayload: hostNetworkCopyPayload,
        networkCleanup: hostNetworkCleanup,
        agentTest: hostAgentTest,
        deviceDisplayName: hostDeviceDisplayName
    )
}
