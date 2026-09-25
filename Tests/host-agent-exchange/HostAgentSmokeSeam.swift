// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host implementation of the device-smoke seam for the broker-tier exchange.
// The application still owns the agent and emits the same JSONL records as a
// device run. This seam supplies a real MQTTNIO client through the public
// EmbeddedMQTTClient boundary.

import DeviceSmokeApplication
import EmbeddedMQTTClient
import Foundation
import MQTTNIO
import MQTTCarrierInterop
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

    static func load(from environment: [String: String]) throws(HostAgentError) {
        brokerHost = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        brokerPort = try parsePort(environment["WIRE_BROKER_PORT"] ?? "1883")
        role = try parseRole(environment["HOST_AGENT_ROLE"] ?? "1")
        clientID = environment["HOST_AGENT_CLIENT_ID"] ?? "axoloty-host-smoke-agent"
        guard !clientID.isEmpty else { throw HostAgentError.configuration("HOST_AGENT_CLIENT_ID is empty") }
        controlDirectory = URL(fileURLWithPath: environment["HOST_AGENT_CONTROL_DIR"] ?? "/tmp/axoloty-host-agent")
        inProcess = environment["HOST_AGENT_BROKER_MODE"] == "in-process"
        do {
            try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
        } catch {
            throw HostAgentError.configuration("cannot create HOST_AGENT_CONTROL_DIR: \(error)")
        }
    }

    static func parsePort(_ value: String) throws(HostAgentError) -> Int {
        guard let port = Int(value), (1...65_535).contains(port) else {
            throw HostAgentError.configuration("invalid WIRE_BROKER_PORT")
        }
        return port
    }

    static func parseRole(_ value: String) throws(HostAgentError) -> UInt32 {
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

private enum HostMQTTLimits {
    static let messageCount = 4
    static let topicBytes = 256
    static let payloadBytes = 2_048
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
    private var messageOverflowed = false
    private var configuredWill: (topic: String, payload: [UInt8])?
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

    func unsubscribe(topic: UnsafePointer<UInt8>, topicLength: Int32) -> Bool {
        guard let topicText = decode(topic, length: topicLength),
              let client = stateLock.withLock({ self.client }) else { return false }
        do {
            _ = try client.unsubscribe(from: [topicText]).wait()
            stateLock.withLock { subscriptions.removeAll { $0 == topicText } }
            return true
        } catch {
            return false
        }
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

        let will = stateLock.withLock { configuredWill }
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

    func pollOneEvent(
        topic: UnsafeMutablePointer<UInt8>, topicCapacity: Int32,
        topicLength: UnsafeMutablePointer<Int32>,
        payload: UnsafeMutablePointer<UInt8>, payloadCapacity: Int32,
        payloadLength: UnsafeMutablePointer<Int32>
    ) -> Int32 {
        if HostAgentConfiguration.inProcess &&
            HostAgentConfiguration.markerExists("disconnect-requested") {
            markInjectedDisconnect()
            return -2
        }
        if stateLock.withLock({ forceDisconnected }) { return -2 }

        messageCondition.lock()
        if messageOverflowed {
            messageOverflowed = false
            messageCondition.unlock()
            return -1
        }
        guard !messages.isEmpty else {
            messageCondition.unlock()
            return 0
        }
        let message = messages.removeFirst()
        messageCondition.unlock()

        let topicBytes = Array(message.topic.utf8)
        guard !topicBytes.isEmpty, topicCapacity > 0, payloadCapacity >= 0,
              topicBytes.count <= Int(topicCapacity),
              message.payload.count <= Int(payloadCapacity) else { return -1 }
        for index in topicBytes.indices { topic[index] = topicBytes[index] }
        for index in message.payload.indices { payload[index] = message.payload[index] }
        topicLength.pointee = Int32(topicBytes.count)
        payloadLength.pointee = Int32(message.payload.count)
        return 1
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
            if info.topicName.utf8.count > HostMQTTLimits.topicBytes ||
                bytes.count > HostMQTTLimits.payloadBytes ||
                self.messages.count >= HostMQTTLimits.messageCount {
                self.messageOverflowed = true
            } else {
                self.messages.append(HostMQTTMessage(topic: info.topicName, payload: bytes))
            }
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

@c @implementation public func axoloty_mqtt_configure_last_will(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 {
    HostMQTTSession.shared.configureLastWill(
        topic: topic, topicLength: topicLength,
        payload: payload, payloadLength: payloadLength
    ) ? 1 : 0
}

@c @implementation public func axoloty_mqtt_connect_wait(_ deadlineMS: UInt32) -> Int32 {
    _ = deadlineMS
    return HostMQTTSession.shared.connect() ? 1 : 0
}

@c @implementation public func axoloty_mqtt_subscribe_wait(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ deadlineMS: UInt32
) -> Int32 {
    _ = deadlineMS
    return HostMQTTSession.shared.subscribe(topic: topic, topicLength: topicLength) ? 1 : 0
}

@c @implementation public func axoloty_mqtt_unsubscribe(_ topic: UnsafePointer<UInt8>, _ topicLength: Int32) -> Int32 {
    HostMQTTSession.shared.unsubscribe(topic: topic, topicLength: topicLength) ? 1 : 0
}

@c @implementation public func axoloty_mqtt_publish(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 {
    HostMQTTSession.shared.publish(
        topic: topic, topicLength: topicLength,
        payload: payload, payloadLength: payloadLength
    ) ? 1 : 0
}

@c @implementation public func axoloty_mqtt_wait_loopback(_ deadlineMS: UInt32) -> Int32 {
    _ = deadlineMS
    return 1
}

@c @implementation public func axoloty_mqtt_reconnect_wait(_ deadlineMS: UInt32) -> Int32 {
    HostMQTTSession.shared.waitForReconnect(deadlineMS: deadlineMS) ? 1 : 0
}

@c @implementation public func axoloty_mqtt_poll_one_event(
    _ topic: UnsafeMutablePointer<UInt8>, _ topicCapacity: Int32, _ topicLength: UnsafeMutablePointer<Int32>,
    _ payload: UnsafeMutablePointer<UInt8>, _ payloadCapacity: Int32, _ payloadLength: UnsafeMutablePointer<Int32>
) -> Int32 {
    HostMQTTSession.shared.pollOneEvent(
        topic: topic, topicCapacity: topicCapacity, topicLength: topicLength,
        payload: payload, payloadCapacity: payloadCapacity, payloadLength: payloadLength
    )
}

@c @implementation public func axoloty_mqtt_disconnect() -> Int32 {
    HostMQTTSession.shared.disconnect() ? 1 : 0
}

nonisolated(unsafe) private var hostApplicationExchangeClient = EmbeddedMQTTClient()

private func hostExchangeConfigureLastWill(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 {
    guard topicLength > 0, topicLength <= 256,
          payloadLength >= 0, payloadLength <= 2_048 else { return 0 }
    return hostApplicationExchangeClient.configureLastWill(
        topic: Span(_unsafeStart: topic, count: Int(topicLength)),
        payload: Span(_unsafeStart: payload, count: Int(payloadLength))
    ) ? 1 : 0
}

private func hostExchangeConnect(_ deadlineMS: UInt32) -> Int32 {
    hostApplicationExchangeClient.connect(deadlineMS: deadlineMS) ? 1 : 0
}

private func hostExchangeSubscribe(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ deadlineMS: UInt32
) -> Int32 {
    guard topicLength > 0, topicLength <= 256 else { return 0 }
    return hostApplicationExchangeClient.subscribe(
        topic: Span(_unsafeStart: topic, count: Int(topicLength)), deadlineMS: deadlineMS
    ) ? 1 : 0
}

private func hostExchangeUnsubscribe(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ deadlineMS: UInt32
) -> Int32 {
    guard topicLength > 0, topicLength <= 256 else { return 0 }
    return hostApplicationExchangeClient.unsubscribe(
        topic: Span(_unsafeStart: topic, count: Int(topicLength)), deadlineMS: deadlineMS
    ) ? 1 : 0
}

private func hostExchangePublish(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 {
    guard topicLength > 0, topicLength <= 256,
          payloadLength >= 0, payloadLength <= 2_048 else { return 0 }
    return hostApplicationExchangeClient.publish(
        topic: Span(_unsafeStart: topic, count: Int(topicLength)),
        payload: Span(_unsafeStart: payload, count: Int(payloadLength))
    ) ? 1 : 0
}

private func hostExchangePollOneEvent(
    _ topic: UnsafeMutablePointer<UInt8>, _ topicCapacity: Int32, _ topicLength: UnsafeMutablePointer<Int32>,
    _ payload: UnsafeMutablePointer<UInt8>, _ payloadCapacity: Int32, _ payloadLength: UnsafeMutablePointer<Int32>
) -> Int32 {
    hostApplicationExchangeClient.pollOneEvent(
        topic: topic, topicCapacity: topicCapacity, topicLength: topicLength,
        payload: payload, payloadCapacity: payloadCapacity, payloadLength: payloadLength
    )
}

private func hostExchangeWaitForReconnect(_ deadlineMS: UInt32) -> Int32 {
    hostApplicationExchangeClient.waitForReconnect(deadlineMS: deadlineMS) ? 1 : 0
}

private func hostExchangeDisconnect() -> Int32 {
    hostApplicationExchangeClient.disconnect() ? 1 : 0
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
@inline(__always) private func hostNetworkScenario() -> UInt32 {
    HostAgentConfiguration.inProcess ? 3 : 0
}
@inline(__always) private func hostNetworkPrepare(_ deadline: UInt32) -> UInt32 { _ = deadline; return 3 }
@inline(__always) private func hostNetworkReconnect(_ deadline: UInt32) -> UInt32 { _ = deadline; return 3 }
@inline(__always) private func hostExchangeMilestone(_ value: UInt32) {
    guard let milestone = DeviceSmokeExchangeMilestone(rawValue: value) else { return }
    switch milestone {
    case .advertised: HostAgentConfiguration.mark("advertised")
    case .resolved: HostAgentConfiguration.mark("resolved")
    case .connected, .subscribed, .reconnected: break
    }
}
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
        networkReconnect: hostNetworkReconnect,
        networkCopyTopic: hostNetworkCopyTopic,
        networkCopyPayload: hostNetworkCopyPayload,
        networkCleanup: hostNetworkCleanup,
        carrier: DeviceSmokeCarrierOperations(
            configureLastWill: hostExchangeConfigureLastWill,
            connect: hostExchangeConnect,
            subscribe: hostExchangeSubscribe,
            unsubscribe: hostExchangeUnsubscribe,
            publish: hostExchangePublish,
            pollOneEvent: hostExchangePollOneEvent,
            waitForReconnect: hostExchangeWaitForReconnect,
            disconnect: hostExchangeDisconnect
        ),
        exchangeMilestone: hostExchangeMilestone,
        deviceDisplayName: hostDeviceDisplayName
    )
}
