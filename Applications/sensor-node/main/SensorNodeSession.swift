// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// One network session of the sensor node, from network bring-up to teardown.
// Protocol decisions stay in the static runtime: this file moves its publish
// actions to the carrier and its inbound frames back.

import AxolotyProtocol
import AxolotyStaticRuntime
import AxolotyWire

enum SensorNodeTiming {
    static let bringUpDeadlineMS: UInt32 = 30_000
    static let readingPeriodMS: UInt64 = 2_000
    static let metricsEveryReadings: UInt32 = 5
    static let idleTicks: UInt32 = 10
    static let retryBaseTicks: UInt32 = 1_000
    static let retryCeilingTicks: UInt32 = 30_000
    static let maximumFailedSessions: UInt32 = 10
    static let nameCapacity = 48
}

/// The step a session had reached when it ended. The closed set of names is the
/// `stage` field of the session-ended record, so an operator can tell which
/// step of bring-up failed without a debug build.
enum SensorNodeStage {
    case network, lastWill, connect, subscribe, advertise, serving

    /// The session-ended record for this stage.
    var endedRecord: StaticString {
        switch self {
        case .network: "{\"event\":\"sensor-node-session-ended\",\"stage\":\"network\"}\n"
        case .lastWill: "{\"event\":\"sensor-node-session-ended\",\"stage\":\"last-will\"}\n"
        case .connect: "{\"event\":\"sensor-node-session-ended\",\"stage\":\"connect\"}\n"
        case .subscribe: "{\"event\":\"sensor-node-session-ended\",\"stage\":\"subscribe\"}\n"
        case .advertise: "{\"event\":\"sensor-node-session-ended\",\"stage\":\"advertise\"}\n"
        case .serving: "{\"event\":\"sensor-node-session-ended\",\"stage\":\"serving\"}\n"
        }
    }
}

/// Counters reported on the metrics line. They survive a session.
///
/// The four `Us` fields are plain counters of platform-clock microseconds, with
/// no sampling buffer: the last and the largest duration of one reading (from
/// encoding through the carrier publish returning) and of one served inbound
/// frame (from `runtime.receive` through the Resolve publish returning). They
/// are zero until one has completed.
struct SensorNodeCounters {
    var sessions: UInt32 = 0
    var readings: UInt32 = 0
    var resolves: UInt32 = 0
    var rejected: UInt32 = 0
    var publishFailures: UInt32 = 0
    var readingLastUs: UInt32 = 0
    var readingMaxUs: UInt32 = 0
    var frameLastUs: UInt32 = 0
    var frameMaxUs: UInt32 = 0

    /// Records one completed reading that started at `startUs`.
    mutating func noteReading(since startUs: UInt64, _ platform: EmbeddedPlatformCapabilities) {
        readingLastUs = sensorNodeElapsedUs(since: startUs, platform)
        readingMaxUs = max(readingMaxUs, readingLastUs)
    }

    /// Records one served frame that started at `startUs`.
    mutating func noteFrame(since startUs: UInt64, _ platform: EmbeddedPlatformCapabilities) {
        frameLastUs = sensorNodeElapsedUs(since: startUs, platform)
        frameMaxUs = max(frameMaxUs, frameLastUs)
    }
}

/// Writes one static line to the platform log.
func sensorNodeLog(_ platform: EmbeddedPlatformCapabilities, _ text: StaticString) {
    _ = try? platform.writeLog(text.utf8Start, length: UInt32(text.utf8CodeUnitCount))
}

@inline(__always)
private func sensorNodeNowUS(_ platform: EmbeddedPlatformCapabilities) -> UInt64 {
    (try? platform.nowMicroseconds()) ?? 0
}

/// Microseconds since `startUs`, saturating at `UInt32.max`.
@inline(__always)
private func sensorNodeElapsedUs(since startUs: UInt64, _ platform: EmbeddedPlatformCapabilities) -> UInt32 {
    let elapsed = sensorNodeNowUS(platform) &- startUs
    return elapsed > UInt64(UInt32.max) ? UInt32.max : UInt32(elapsed)
}

@inline(__always)
private func sensorNodeNowMS(_ platform: EmbeddedPlatformCapabilities) -> UInt64 {
    ((try? platform.nowMicroseconds()) ?? 0) / 1_000
}

/// Appends literal text and decimal values into one bounded metrics line.
private struct MetricsLine {
    let buffer: UnsafeMutableBufferPointer<UInt8>
    var count = 0

    mutating func append(_ text: StaticString) {
        for index in 0..<text.utf8CodeUnitCount where count < buffer.count {
            buffer[count] = text.utf8Start[index]
            count += 1
        }
    }

    mutating func append(_ value: UInt32) {
        var divisor: UInt32 = 1
        while value / divisor >= 10 { divisor *= 10 }
        while divisor > 0, count < buffer.count {
            buffer[count] = UInt8(48 + (value / divisor) % 10)
            count += 1
            divisor /= 10
        }
    }
}

/// Bytes of the metrics line buffer. The longest possible line has the fixed
/// text, thirteen fields, and every value at `UInt32.max` (ten digits): 353
/// bytes with the closing newline. The buffer holds it with room to spare, and
/// `MetricsLine` would truncate rather than overflow if a field were added.
private let sensorNodeMetricsLineCapacity = 384

/// Reports the node's footprint and work counters as one JSON line.
private func logSensorNodeMetrics(_ platform: EmbeddedPlatformCapabilities, counters: SensorNodeCounters) {
    var metrics = axoloty_platform_metrics_v1()
    guard (try? platform.readMetrics(into: &metrics)) != nil else { return }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: sensorNodeMetricsLineCapacity) { storage in
        var line = MetricsLine(buffer: storage)
        line.append("{\"event\":\"sensor-node-metrics\",\"sessions\":")
        line.append(counters.sessions)
        line.append(",\"readings\":")
        line.append(counters.readings)
        line.append(",\"resolves\":")
        line.append(counters.resolves)
        line.append(",\"rejected\":")
        line.append(counters.rejected)
        line.append(",\"publishFailures\":")
        line.append(counters.publishFailures)
        line.append(",\"readingLastUs\":")
        line.append(counters.readingLastUs)
        line.append(",\"readingMaxUs\":")
        line.append(counters.readingMaxUs)
        line.append(",\"frameLastUs\":")
        line.append(counters.frameLastUs)
        line.append(",\"frameMaxUs\":")
        line.append(counters.frameMaxUs)
        line.append(",\"freeHeap\":")
        line.append(metrics.free_internal_heap)
        line.append(",\"minimumFreeHeap\":")
        line.append(metrics.minimum_free_internal_heap)
        line.append(",\"stackRemaining\":")
        line.append(metrics.main_stack_high_water)
        line.append(",\"stackSize\":")
        line.append(metrics.main_stack_size)
        line.append("}\n")
        _ = try? platform.writeLog(UnsafePointer(storage.baseAddress!), length: UInt32(line.count))
    }
}

/// Publishes one drained runtime action on its profile route.
private func publishSensorAction(
    _ publication: BorrowedProtocolPublication,
    carrier: EmbeddedCarrierCapabilities,
    topic: UnsafeMutablePointer<UInt8>, topicCapacity: Int
) -> Bool {
    guard case .profile(let filter, let filterKind) = publication.target,
          let length = writeSensorRoute(
            into: topic, capacity: topicCapacity,
            event: publication.routingKey.capability.wireEventType,
            filter: filter, filterKind: filterKind,
            source: publication.routingKey.sourceID,
            correlation: publication.routingKey.correlationID
          ) else { return false }
    return publication.payload.withBytes { bytes, count in
        (try? carrier.publish(
            topic: UnsafePointer(topic), topicLength: UInt32(length),
            payload: bytes.assumingMemoryBound(to: UInt8.self), payloadLength: UInt32(count)
        )) != nil
    }
}

/// Sends one local operation and publishes what the runtime produced.
///
/// - Returns: `false` when the runtime refused it or a publish failed.
private func sendSensorOperation(
    _ operation: ProtocolLocalOperation,
    runtime: inout SensorNodeRuntime,
    carrier: EmbeddedCarrierCapabilities,
    topic: UnsafeMutablePointer<UInt8>, topicCapacity: Int,
    nowMS: UInt32
) -> Bool {
    guard runtime.send(operation, nowMS: nowMS) == .accepted else { return false }
    var published = true
    runtime.drain { action in
        if case .publish(let publication) = action,
           !publishSensorAction(publication, carrier: carrier, topic: topic, topicCapacity: topicCapacity) {
            published = false
        }
    }
    return published
}

/// Configures the Deadvertise a carrier with a last will publishes for us.
private func configureSensorLastWill(
    carrier: EmbeddedCarrierCapabilities,
    topic: UnsafeMutablePointer<UInt8>, topicCapacity: Int,
    payload: UnsafeMutablePointer<UInt8>, payloadCapacity: Int
) -> Bool {
    guard (try? carrier.supportsLastWill()) == true else { return true }
    guard let topicLength = writeSensorRoute(
            into: topic, capacity: topicCapacity, event: .deadvertise,
            filter: nil, filterKind: .direct, source: SensorNodeIdentity.agent, correlation: nil
          ),
          let payloadLength = encodeSensorDeadvertisePayload(into: payload, capacity: payloadCapacity) else {
        return false
    }
    return (try? carrier.configureLastWill(
        topic: UnsafePointer(topic), topicLength: UInt32(topicLength),
        payload: UnsafePointer(payload), payloadLength: UInt32(payloadLength)
    )) != nil
}

/// Runs one session: bring-up, the serve loop, and teardown.
///
/// - Returns: `true` when the session got as far as advertising.
func runSensorNodeSession(
    _ capabilities: EmbeddedCapabilities,
    runtime: inout SensorNodeRuntime,
    counters: inout SensorNodeCounters
) -> Bool {
    let platform = capabilities.platform
    let carrier = capabilities.carrier
    let topicCapacity = Int(EmbeddedApplicationRequirements.current.maxTopicLength)
    let payloadCapacity = Int(EmbeddedApplicationRequirements.current.maxPayloadSize)
    runtime.resetTransport()
    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: topicCapacity) { topic in
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: payloadCapacity) { payload in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: SensorNodeTiming.nameCapacity) { name in
                let topicBase = topic.baseAddress!
                let payloadBase = payload.baseAddress!
                let nameLength = (try? platform.copyDeviceDisplayName(
                    into: name.baseAddress!, capacity: UInt32(name.count)
                )) ?? 0
                let nameSlice = ByteSlice(bytes: UnsafePointer(name.baseAddress!), length: Int(nameLength))

                var connected = false
                var reachedNetwork = false
                var stage = SensorNodeStage.network
                defer {
                    if connected { _ = try? carrier.disconnect() }
                    _ = try? platform.cleanupNetwork()
                    sensorNodeLog(platform, stage.endedRecord)
                }

                guard let network = try? platform.prepareNetwork(deadlineMilliseconds: SensorNodeTiming.bringUpDeadlineMS),
                      network & 3 == 3 else {
                    return false
                }
                stage = .lastWill
                guard configureSensorLastWill(
                    carrier: carrier, topic: topicBase, topicCapacity: topic.count,
                    payload: payloadBase, payloadCapacity: payload.count
                ) else {
                    return false
                }
                stage = .connect
                guard (try? carrier.connect(deadlineMilliseconds: SensorNodeTiming.bringUpDeadlineMS)) != nil else {
                    return false
                }
                connected = true

                stage = .subscribe
                let interest = sensorNodeDiscoverInterest()
                guard (try? carrier.subscribe(
                    topic: interest.utf8Start, length: UInt32(interest.utf8CodeUnitCount),
                    deadlineMilliseconds: SensorNodeTiming.bringUpDeadlineMS
                )) != nil else {
                    return false
                }
                stage = .advertise
                guard let advertiseLength = encodeSensorObjectPayload(
                        into: payloadBase, capacity: payload.count, name: nameSlice
                      ),
                      sendSensorOperation(
                        .advertise(
                            sourceID: SensorNodeIdentity.agent,
                            payload: ByteSlice(bytes: UnsafePointer(payloadBase), length: advertiseLength)
                        ),
                        runtime: &runtime, carrier: carrier,
                        topic: topicBase, topicCapacity: topic.count,
                        nowMS: UInt32(truncatingIfNeeded: sensorNodeNowMS(platform))
                      ) else {
                    return false
                }
                stage = .serving
                reachedNetwork = true
                sensorNodeLog(platform, "{\"event\":\"sensor-node-advertised\"}\n")

                var nextReadingMS = sensorNodeNowMS(platform)
                while true {
                    let nowMS = sensorNodeNowMS(platform)
                    if nowMS >= nextReadingMS {
                        nextReadingMS = nowMS + SensorNodeTiming.readingPeriodMS
                        counters.readings &+= 1
                        let readingStartUs = sensorNodeNowUS(platform)
                        guard let length = encodeSensorObjectPayload(
                                into: payloadBase, capacity: payload.count, name: nameSlice,
                                reading: (sequence: counters.readings, value: Int(counters.readings % 100))
                              ),
                              sendSensorOperation(
                                .channel(
                                    sourceID: SensorNodeIdentity.agent,
                                    payload: ByteSlice(bytes: UnsafePointer(payloadBase), length: length),
                                    identifier: sensorNodeSlice(SensorNodeIdentity.channel)
                                ),
                                runtime: &runtime, carrier: carrier,
                                topic: topicBase, topicCapacity: topic.count,
                                nowMS: UInt32(truncatingIfNeeded: nowMS)
                              ) else {
                            counters.publishFailures &+= 1
                            return reachedNetwork
                        }
                        counters.noteReading(since: readingStartUs, platform)
                        if counters.readings % SensorNodeTiming.metricsEveryReadings == 0 {
                            logSensorNodeMetrics(platform, counters: counters)
                        }
                    }

                    var topicLength: UInt32 = 0
                    var payloadLength: UInt32 = 0
                    // A frame larger than these buffers stays queued in the
                    // carrier, so `insufficientCapacity` ends the session; the
                    // reconnect discards it.
                    guard let polled = try? carrier.pollOneEvent(
                        topic: topicBase, topicCapacity: UInt32(topic.count), topicLength: &topicLength,
                        payload: payloadBase, payloadCapacity: UInt32(payload.count), payloadLength: &payloadLength
                    ) else {
                        return reachedNetwork
                    }
                    switch polled {
                    case .closed:
                        return reachedNetwork
                    case .noEvent:
                        _ = try? platform.delay(ticks: SensorNodeTiming.idleTicks)
                    case .event:
                        guard serveSensorFrame(
                            topic: topicBase, topicLength: Int(topicLength), topicCapacity: topic.count,
                            payload: payloadBase, payloadLength: Int(payloadLength), payloadCapacity: payload.count,
                            name: nameSlice, platform: platform, carrier: carrier, runtime: &runtime, counters: &counters,
                            nowMS: UInt32(truncatingIfNeeded: nowMS)
                        ) else {
                            counters.publishFailures &+= 1
                            return reachedNetwork
                        }
                    }
                }
            }
        }
    }
}

/// Processes one inbound frame and answers a matching Discover.
///
/// The request is copied out of the receive buffers before the same buffers
/// carry the response.
///
/// A frame that earns a Resolve is timed from `runtime.receive` through the
/// Resolve publish returning, which includes the carrier's call into the network
/// stack.
///
/// - Returns: `false` when an answer could not be published.
private func serveSensorFrame(
    topic: UnsafeMutablePointer<UInt8>, topicLength: Int, topicCapacity: Int,
    payload: UnsafeMutablePointer<UInt8>, payloadLength: Int, payloadCapacity: Int,
    name: ByteSlice,
    platform: EmbeddedPlatformCapabilities,
    carrier: EmbeddedCarrierCapabilities,
    runtime: inout SensorNodeRuntime,
    counters: inout SensorNodeCounters,
    nowMS: UInt32
) -> Bool {
    let frameStartUs = sensorNodeNowUS(platform)
    let outcome = runtime.receive(
        topic: ByteSlice(bytes: UnsafePointer(topic), length: topicLength),
        payload: ByteSlice(bytes: UnsafePointer(payload), length: payloadLength),
        nowMS: nowMS
    )
    if case .rejected = outcome { counters.rejected &+= 1 }
    var request: UUID16?
    runtime.drain { action in
        if case .deliver(let delivery) = action,
           delivery.routingKey.capability == .discover,
           sensorDiscoverMatches(delivery.payload) {
            request = delivery.routingKey.correlationID
        }
    }
    guard let request else { return true }
    guard let length = encodeSensorObjectPayload(into: payload, capacity: payloadCapacity, name: name) else {
        return false
    }
    counters.resolves &+= 1
    let sent = sendSensorOperation(
        .resolve(
            sourceID: SensorNodeIdentity.agent,
            correlationID: request,
            payload: ByteSlice(bytes: UnsafePointer(payload), length: length)
        ),
        runtime: &runtime, carrier: carrier,
        topic: topic, topicCapacity: topicCapacity,
        nowMS: nowMS
    )
    if sent { counters.noteFrame(since: frameStartUs, platform) }
    return sent
}
