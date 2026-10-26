// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Binds the stable application ABI to the device smoke application's seam.
//
// The ABI hands the application validated platform and carrier capabilities.
// This file turns them back into the plain C function pointers the application
// already consumes. The seam closures capture nothing, so the installed value
// stays the only shared state and every operation is one synchronous call.

/// The capabilities the generated entry validated for this image.
nonisolated(unsafe) private var installedCapabilities: EmbeddedCapabilities?

/// Runs the device smoke application through the stable application ABI.
///
/// - Parameter capabilities: Validated platform and carrier operations.
/// - Returns: The bounded outcome the generated C entry reports.
public func startDeviceSmoke(_ capabilities: EmbeddedCapabilities) -> EmbeddedApplicationResult {
    installedCapabilities = capabilities
    let status = startDeviceSmoke(capabilityDeviceSmokeSeam())
    installedCapabilities = nil
    return status == 0 ? .completed : .failed(.failed)
}

/// Returns the capabilities the entry validated for this image.
@inline(__always)
private func activeCapabilities() -> EmbeddedCapabilities {
    installedCapabilities!
}

@inline(__always)
private func carrierCapabilities() -> EmbeddedCarrierCapabilities {
    activeCapabilities().carrier
}

@inline(__always)
private func writeLog(_ bytes: UnsafePointer<UInt8>, length: UInt32) {
    _ = try? activeCapabilities().platform.writeLog(bytes, length: length)
}

@inline(__always)
private func writeLiteral(_ text: StaticString) {
    text.withUTF8Buffer { buffer in
        writeLog(buffer.baseAddress!, length: UInt32(buffer.count))
    }
}

@inline(__always)
private func writeCString(_ text: UnsafePointer<CChar>) {
    var length = 0
    while text[length] != 0 { length += 1 }
    writeLog(UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self), length: UInt32(length))
}

@inline(__always)
private func writeDecimal(_ value: UInt32) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 10) { digits in
        var remaining = value
        var index = digits.count
        repeat {
            index -= 1
            digits[index] = UInt8(48) + UInt8(remaining % 10)
            remaining /= 10
        } while remaining != 0
        writeLog(digits.baseAddress! + index, length: UInt32(digits.count - index))
    }
}

@inline(__always)
private func exchangeMilestone(_ value: UInt32) {
    switch DeviceSmokeExchangeMilestone(rawValue: value) {
    case .connected: writeLiteral("axoloty:milestone:connected\n")
    case .subscribed: writeLiteral("axoloty:milestone:subscribed\n")
    case .reconnected: writeLiteral("axoloty:milestone:reconnected\n")
    case .advertised: writeLiteral("axoloty:milestone:advertised\n")
    case .resolved: writeLiteral("axoloty:milestone:resolved\n")
    case .none: break
    }
}

@inline(__always)
private func metric(_ field: (axoloty_platform_metrics_v1) -> UInt32) -> UInt32 {
    withUnsafeTemporaryAllocation(of: axoloty_platform_metrics_v1.self, capacity: 1) { storage in
        let output = storage.baseAddress!
        output.initialize(to: axoloty_platform_metrics_v1())
        guard (try? activeCapabilities().platform.readMetrics(into: output)) != nil else { return 0 }
        return field(output.pointee)
    }
}

@inline(__always)
private func nowMicroseconds() -> Int64 {
    Int64(bitPattern: (try? activeCapabilities().platform.nowMicroseconds()) ?? 0)
}

@inline(__always)
private func beginHeapTrace() -> Int32 {
    (try? activeCapabilities().platform.beginHeapTrace()) == nil ? 0 : 1
}

@inline(__always)
private func endHeapTrace() -> UInt32 {
    (try? activeCapabilities().platform.endHeapTrace()) ?? 0
}

@inline(__always)
private func networkConfigured() -> Int32 {
    (try? activeCapabilities().platform.isNetworkConfigured()) == true ? 1 : 0
}

@inline(__always)
private func networkRole() -> UInt32 {
    (try? activeCapabilities().platform.networkRole()) ?? 0
}

@inline(__always)
private func networkScenario() -> UInt32 {
    (try? activeCapabilities().platform.networkScenario()) ?? 0
}

@inline(__always)
private func prepareNetwork(_ deadline: UInt32) -> UInt32 {
    (try? activeCapabilities().platform.prepareNetwork(deadlineMilliseconds: deadline)) ?? 0
}

@inline(__always)
private func reconnectNetwork(_ deadline: UInt32) -> UInt32 {
    (try? activeCapabilities().platform.reconnectNetwork(deadlineMilliseconds: deadline)) ?? 0
}

@inline(__always)
private func cleanupNetwork() -> UInt32 {
    (try? activeCapabilities().platform.cleanupNetwork()) ?? 0
}

@inline(__always)
private func copyProbeTopic(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int32) -> Int32 {
    guard capacity > 0 else { return -1 }
    guard let length = try? carrierCapabilities().copyProbeTopic(
        into: buffer, capacity: UInt32(capacity)
    ) else { return -1 }
    return Int32(length)
}

@inline(__always)
private func copyProbePayload(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int32) -> Int32 {
    guard capacity >= 0 else { return -1 }
    guard let length = try? carrierCapabilities().copyProbePayload(
        into: buffer, capacity: UInt32(capacity)
    ) else { return -1 }
    return Int32(length)
}

@inline(__always)
private func deviceDisplayName(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int32) -> Int32 {
    guard capacity > 0 else { return -1 }
    guard let length = try? activeCapabilities().platform.copyDeviceDisplayName(
        into: buffer, capacity: UInt32(capacity)
    ) else { return -1 }
    return Int32(length)
}

/// Runs one carrier operation and reports whether it succeeded.
@inline(__always)
private func carrierResult(_ body: () throws(EmbeddedCapabilityError) -> Void) -> Int32 {
    (try? body()) == nil ? 0 : 1
}

/// Builds the capability-backed seam the device smoke application runs against.
private func capabilityDeviceSmokeSeam() -> DeviceSmokeSeam {
    DeviceSmokeSeam(
        print: { writeCString($0) },
        printUInt: { label, value in
            writeCString(label)
            writeDecimal(value)
        },
        nowMicroseconds: nowMicroseconds,
        delay: { _ = try? activeCapabilities().platform.delay(ticks: $0) },
        restart: { _ = try? activeCapabilities().platform.restart() },
        freeInternalHeap: { metric { $0.free_internal_heap } },
        minFreeInternalHeap: { metric { $0.minimum_free_internal_heap } },
        largestInternalBlock: { metric { $0.largest_internal_block } },
        mainStackHighWater: { metric { $0.main_stack_high_water } },
        mainStackSize: { metric { $0.main_stack_size } },
        resetReason: { metric { $0.reset_reason } },
        heapTraceBegin: beginHeapTrace,
        heapTraceEnd: endHeapTrace,
        networkConfigured: networkConfigured,
        networkRole: networkRole,
        networkScenario: networkScenario,
        networkPrepare: prepareNetwork,
        networkReconnect: reconnectNetwork,
        networkCopyTopic: copyProbeTopic,
        networkCopyPayload: copyProbePayload,
        networkCleanup: cleanupNetwork,
        // The probe belongs to the selected transport: both carriers export
        // this neutral operation and the linker resolves the selected one, so
        // the application names an operation, not a carrier. Its record names
        // are that transport's evidence contract, not the application's.
        runCarrierProbe: runCarrierNetworkProbe,
        carrier: DeviceSmokeCarrierOperations(
            supportsLastWill: { (try? carrierCapabilities().supportsLastWill()) == true ? 1 : 0 },
            configureLastWill: { topic, topicLength, payload, payloadLength in
                guard topicLength > 0, payloadLength >= 0 else { return 0 }
                return carrierResult { () throws(EmbeddedCapabilityError) -> Void in
                    try carrierCapabilities().configureLastWill(
                        topic: topic, topicLength: UInt32(topicLength),
                        payload: payload, payloadLength: UInt32(payloadLength)
                    )
                }
            },
            connect: { deadline in carrierResult { () throws(EmbeddedCapabilityError) -> Void in
                try carrierCapabilities().connect(deadlineMilliseconds: deadline)
            } },
            subscribe: { topic, length, deadline in
                guard length > 0 else { return 0 }
                return carrierResult { () throws(EmbeddedCapabilityError) -> Void in
                    try carrierCapabilities().subscribe(
                        topic: topic, length: UInt32(length), deadlineMilliseconds: deadline
                    )
                }
            },
            unsubscribe: { topic, length, deadline in
                guard length > 0 else { return 0 }
                return carrierResult { () throws(EmbeddedCapabilityError) -> Void in
                    try carrierCapabilities().unsubscribe(
                        topic: topic, length: UInt32(length), deadlineMilliseconds: deadline
                    )
                }
            },
            publish: { topic, topicLength, payload, payloadLength in
                guard topicLength > 0, payloadLength >= 0 else { return 0 }
                return carrierResult { () throws(EmbeddedCapabilityError) -> Void in
                    try carrierCapabilities().publish(
                        topic: topic, topicLength: UInt32(topicLength),
                        payload: payload, payloadLength: UInt32(payloadLength)
                    )
                }
            },
            pollOneEvent: { topic, topicCapacity, topicLength, payload, payloadCapacity, payloadLength in
                guard topicCapacity > 0, payloadCapacity >= 0 else { return -1 }
                var producedTopicLength: UInt32 = 0
                var producedPayloadLength: UInt32 = 0
                guard let outcome = try? carrierCapabilities().pollOneEvent(
                    topic: topic, topicCapacity: UInt32(topicCapacity), topicLength: &producedTopicLength,
                    payload: payload, payloadCapacity: UInt32(payloadCapacity),
                    payloadLength: &producedPayloadLength
                ) else { return -1 }
                switch outcome {
                case .event:
                    topicLength.pointee = Int32(producedTopicLength)
                    payloadLength.pointee = Int32(producedPayloadLength)
                    return 1
                case .noEvent:
                    return 0
                case .closed:
                    return -2
                }
            },
            waitForReconnect: { deadline in carrierResult { () throws(EmbeddedCapabilityError) -> Void in
                try carrierCapabilities().waitForReconnect(deadlineMilliseconds: deadline)
            } },
            disconnect: { carrierResult { () throws(EmbeddedCapabilityError) -> Void in try carrierCapabilities().disconnect() } }
        ),
        exchangeMilestone: exchangeMilestone,
        deviceDisplayName: deviceDisplayName
    )
}
