// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Failure returned when a platform or carrier operation cannot complete.
public enum EmbeddedCapabilityError: Error {
    /// A table has an unsupported version, size, capability set, or function.
    case invalidABI
    /// The operation rejected an argument or its caller-owned buffer.
    case invalidArgument
    /// The operation needs a larger caller-owned buffer.
    case insufficientCapacity
    /// The carrier has closed.
    case closed
    /// The requested operation is unavailable or failed.
    case operationFailed
    /// The selected application did not declare this operation.
    case capabilityUnavailable
}

/// Typed access to the immutable platform and carrier tables supplied at entry.
///
/// The tables and their contexts must remain alive for the synchronous
/// application entry call. Methods do not retain or return their pointers.
public struct EmbeddedCapabilities {
    /// Platform operations supplied by the selected board integration.
    public let platform: EmbeddedPlatformCapabilities
    /// Carrier operations supplied by the selected transport.
    public let carrier: EmbeddedCarrierCapabilities

    /// Validates both version 1 tables before constructing typed capabilities.
    public init?(
        validatingPlatform platform: UnsafePointer<axoloty_platform_v1>?,
        carrier: UnsafePointer<axoloty_carrier_v1>?,
        requirements: EmbeddedRequirements
    ) {
        guard let platform, let carrier,
              axoloty_platform_v1_validate_requirements(
                platform, requirements.platformCapabilities, requirements.platformFunctions
              ) != 0,
              axoloty_carrier_v1_validate_requirements(
                carrier, requirements.carrierCapabilities, requirements.carrierFunctions
              ) != 0 else {
            return nil
        }
        self.platform = EmbeddedPlatformCapabilities(table: platform, requirements: requirements)
        self.carrier = EmbeddedCarrierCapabilities(table: carrier, requirements: requirements)
    }
}

/// Typed platform operations backed by `axoloty_platform_v1`.
public struct EmbeddedPlatformCapabilities {
    private let table: UnsafePointer<axoloty_platform_v1>
    private let requirements: EmbeddedRequirements

    fileprivate init(table: UnsafePointer<axoloty_platform_v1>, requirements: EmbeddedRequirements) {
        self.table = table
        self.requirements = requirements
    }

    /// Returns monotonic microseconds since platform startup.
    public func nowMicroseconds() throws(EmbeddedCapabilityError) -> UInt64 {
        var value: UInt64 = 0
        guard requirements.requiresPlatformFunction(0) else { throw .capabilityUnavailable }
        guard let call = table.pointee.clock_now_microseconds else { throw .invalidABI }
        try checked(call(table.pointee.context, &value))
        return value
    }

    /// Delays for the requested scheduler ticks.
    public func delay(ticks: UInt32) throws(EmbeddedCapabilityError) {
        guard requirements.requiresPlatformFunction(1) else { throw .capabilityUnavailable }
        guard let call = table.pointee.delay_ticks else { throw .invalidABI }
        try checked(call(table.pointee.context, ticks))
    }

    /// Restarts the device. A successful platform implementation does not return.
    public func restart() throws(EmbeddedCapabilityError) {
        guard requirements.requiresPlatformFunction(2) else { throw .capabilityUnavailable }
        guard let call = table.pointee.restart else { throw .invalidABI }
        try checked(call(table.pointee.context))
    }

    /// Writes a borrowed byte sequence to the platform log synchronously.
    public func writeLog(_ bytes: UnsafePointer<UInt8>, length: UInt32) throws(EmbeddedCapabilityError) {
        guard requirements.requiresPlatformFunction(3) else { throw .capabilityUnavailable }
        guard let call = table.pointee.write_log else { throw .invalidABI }
        try checked(call(table.pointee.context, bytes, length))
    }

    /// Reads bounded platform diagnostics into caller-owned storage.
    public func readMetrics(into output: UnsafeMutablePointer<axoloty_platform_metrics_v1>) throws(EmbeddedCapabilityError) {
        guard requirements.requiresPlatformFunction(6) else { throw .capabilityUnavailable }
        guard let call = table.pointee.read_metrics else { throw .invalidABI }
        try checked(call(table.pointee.context, output))
    }

    /// Starts a bounded platform heap trace.
    public func beginHeapTrace() throws(EmbeddedCapabilityError) {
        guard requirements.requiresPlatformFunction(4) else { throw .capabilityUnavailable }
        guard let call = table.pointee.heap_trace_begin else { throw .invalidABI }
        try checked(call(table.pointee.context))
    }

    /// Ends the active heap trace and writes the allocation count.
    public func endHeapTrace() throws(EmbeddedCapabilityError) -> UInt32 {
        guard requirements.requiresPlatformFunction(5) else { throw .capabilityUnavailable }
        var count: UInt32 = 0
        guard let call = table.pointee.heap_trace_end else { throw .invalidABI }
        try checked(call(table.pointee.context, &count))
        return count
    }

    /// Returns whether operator network configuration is present.
    public func isNetworkConfigured() throws(EmbeddedCapabilityError) -> Bool {
        guard requirements.requiresPlatformFunction(7) else { throw .capabilityUnavailable }
        var value: UInt32 = 0
        guard let call = table.pointee.network_configured else { throw .invalidABI }
        try checked(call(table.pointee.context, &value))
        return value != 0
    }

    /// Returns the selected network role.
    public func networkRole() throws(EmbeddedCapabilityError) -> UInt32 {
        guard requirements.requiresPlatformFunction(8) else { throw .capabilityUnavailable }
        var value: UInt32 = 0
        guard let call = table.pointee.network_role else { throw .invalidABI }
        try checked(call(table.pointee.context, &value))
        return value
    }

    /// Returns the selected network scenario.
    public func networkScenario() throws(EmbeddedCapabilityError) -> UInt32 {
        guard requirements.requiresPlatformFunction(9) else { throw .capabilityUnavailable }
        var value: UInt32 = 0
        guard let call = table.pointee.network_scenario else { throw .invalidABI }
        try checked(call(table.pointee.context, &value))
        return value
    }

    /// Prepares platform networking before the supplied deadline.
    public func prepareNetwork(deadlineMilliseconds: UInt32) throws(EmbeddedCapabilityError) -> UInt32 {
        guard requirements.requiresPlatformFunction(10) else { throw .capabilityUnavailable }
        var result: UInt32 = 0
        guard let call = table.pointee.network_prepare else { throw .invalidABI }
        try checked(call(table.pointee.context, deadlineMilliseconds, &result))
        return result
    }

    /// Reconnects platform networking before the supplied deadline.
    public func reconnectNetwork(deadlineMilliseconds: UInt32) throws(EmbeddedCapabilityError) -> UInt32 {
        guard requirements.requiresPlatformFunction(12) else { throw .capabilityUnavailable }
        var result: UInt32 = 0
        guard let call = table.pointee.network_reconnect else { throw .invalidABI }
        try checked(call(table.pointee.context, deadlineMilliseconds, &result))
        return result
    }

    /// Copies the configured display name into caller-owned storage.
    public func copyDeviceDisplayName(
        into buffer: UnsafeMutablePointer<UInt8>, capacity: UInt32
    ) throws(EmbeddedCapabilityError) -> UInt32 {
        guard requirements.requiresPlatformFunction(13) else { throw .capabilityUnavailable }
        var length: UInt32 = 0
        guard let call = table.pointee.device_display_name else { throw .invalidABI }
        try checked(call(table.pointee.context, buffer, capacity, &length))
        guard length <= capacity else { throw .invalidABI }
        return length
    }

    /// Cleans up platform networking and returns its platform result bits.
    public func cleanupNetwork() throws(EmbeddedCapabilityError) -> UInt32 {
        guard requirements.requiresPlatformFunction(11) else { throw .capabilityUnavailable }
        var result: UInt32 = 0
        guard let call = table.pointee.network_cleanup else { throw .invalidABI }
        try checked(call(table.pointee.context, &result))
        return result
    }

}

/// Typed carrier operations backed by `axoloty_carrier_v1`.
public struct EmbeddedCarrierCapabilities {
    private let table: UnsafePointer<axoloty_carrier_v1>
    private let requirements: EmbeddedRequirements

    fileprivate init(table: UnsafePointer<axoloty_carrier_v1>, requirements: EmbeddedRequirements) {
        self.table = table
        self.requirements = requirements
    }

    /// Reports whether the carrier supports last-will configuration.
    public func supportsLastWill() throws(EmbeddedCapabilityError) -> Bool {
        guard requirements.requiresCarrierFunction(0) else { throw .capabilityUnavailable }
        var supported: UInt32 = 0
        guard let call = table.pointee.supports_last_will else { throw .invalidABI }
        try checked(call(table.pointee.context, &supported))
        return supported != 0
    }

    /// Configures a borrowed last-will topic and payload synchronously.
    public func configureLastWill(
        topic: UnsafePointer<UInt8>, topicLength: UInt32,
        payload: UnsafePointer<UInt8>, payloadLength: UInt32
    ) throws(EmbeddedCapabilityError) {
        guard requirements.requiresCarrierFunction(1) else { throw .capabilityUnavailable }
        guard topicLength <= requirements.maxTopicLength else { throw .invalidArgument }
        guard payloadLength <= requirements.maxPayloadSize else { throw .invalidArgument }
        guard let call = table.pointee.configure_last_will else { throw .invalidABI }
        try checked(call(table.pointee.context, topic, topicLength, payload, payloadLength))
    }

    /// Connects before the supplied deadline.
    public func connect(deadlineMilliseconds: UInt32) throws(EmbeddedCapabilityError) {
        guard requirements.requiresCarrierFunction(2) else { throw .capabilityUnavailable }
        guard let call = table.pointee.connect else { throw .invalidABI }
        try checked(call(table.pointee.context, deadlineMilliseconds))
    }

    /// Subscribes to a borrowed topic before the supplied deadline.
    public func subscribe(
        topic: UnsafePointer<UInt8>, length: UInt32, deadlineMilliseconds: UInt32
    ) throws(EmbeddedCapabilityError) {
        guard requirements.requiresCarrierFunction(3) else { throw .capabilityUnavailable }
        guard length <= requirements.maxTopicLength else { throw .invalidArgument }
        guard let call = table.pointee.subscribe else { throw .invalidABI }
        try checked(call(table.pointee.context, topic, length, deadlineMilliseconds))
    }

    /// Removes a subscription before the supplied deadline.
    public func unsubscribe(
        topic: UnsafePointer<UInt8>, length: UInt32, deadlineMilliseconds: UInt32
    ) throws(EmbeddedCapabilityError) {
        guard requirements.requiresCarrierFunction(4) else { throw .capabilityUnavailable }
        guard length <= requirements.maxTopicLength else { throw .invalidArgument }
        guard let call = table.pointee.unsubscribe else { throw .invalidABI }
        try checked(call(table.pointee.context, topic, length, deadlineMilliseconds))
    }

    /// Publishes borrowed topic and payload bytes synchronously.
    public func publish(
        topic: UnsafePointer<UInt8>, topicLength: UInt32,
        payload: UnsafePointer<UInt8>, payloadLength: UInt32
    ) throws(EmbeddedCapabilityError) {
        guard requirements.requiresCarrierFunction(5) else { throw .capabilityUnavailable }
        guard topicLength <= requirements.maxTopicLength else { throw .invalidArgument }
        guard payloadLength <= requirements.maxPayloadSize else { throw .invalidArgument }
        guard let call = table.pointee.publish else { throw .invalidABI }
        try checked(call(table.pointee.context, topic, topicLength, payload, payloadLength))
    }

    /// Polls into caller-owned buffers without retaining either pointer.
    public func pollOneEvent(
        topic: UnsafeMutablePointer<UInt8>, topicCapacity: UInt32, topicLength: UnsafeMutablePointer<UInt32>,
        payload: UnsafeMutablePointer<UInt8>, payloadCapacity: UInt32, payloadLength: UnsafeMutablePointer<UInt32>
    ) throws(EmbeddedCapabilityError) -> EmbeddedCarrierPollResult {
        guard requirements.requiresCarrierFunction(6) else { throw .capabilityUnavailable }
        guard let call = table.pointee.poll_one_event else { throw .invalidABI }
        let boundedTopicCapacity = min(topicCapacity, requirements.maxTopicLength)
        let boundedPayloadCapacity = min(payloadCapacity, requirements.maxPayloadSize)
        let status = call(table.pointee.context, topic, boundedTopicCapacity, topicLength,
                          payload, boundedPayloadCapacity, payloadLength)
        switch status {
        case AXOLOTY_ABI_STATUS_OK:
            guard topicLength.pointee <= boundedTopicCapacity,
                  topicLength.pointee <= requirements.maxTopicLength,
                  payloadLength.pointee <= boundedPayloadCapacity,
                  payloadLength.pointee <= requirements.maxPayloadSize else {
                throw .invalidABI
            }
            return .event
        case AXOLOTY_ABI_STATUS_NO_EVENT: return .noEvent
        case AXOLOTY_ABI_STATUS_CLOSED: return .closed
        case AXOLOTY_ABI_STATUS_BUFFER_TOO_SMALL: throw .insufficientCapacity
        default: try checked(status); return .noEvent
        }
    }

    /// Waits for a transport reconnect before the supplied deadline.
    public func waitForReconnect(deadlineMilliseconds: UInt32) throws(EmbeddedCapabilityError) {
        guard requirements.requiresCarrierFunction(7) else { throw .capabilityUnavailable }
        guard let call = table.pointee.wait_for_reconnect else { throw .invalidABI }
        try checked(call(table.pointee.context, deadlineMilliseconds))
    }

    /// Disconnects the carrier.
    public func disconnect() throws(EmbeddedCapabilityError) {
        guard requirements.requiresCarrierFunction(8) else { throw .capabilityUnavailable }
        guard let call = table.pointee.disconnect else { throw .invalidABI }
        try checked(call(table.pointee.context))
    }

    /// Copies the carrier-selected probe topic into caller-owned storage.
    public func copyProbeTopic(
        into buffer: UnsafeMutablePointer<UInt8>, capacity: UInt32
    ) throws(EmbeddedCapabilityError) -> UInt32 {
        guard requirements.requiresCarrierFunction(9) else { throw .capabilityUnavailable }
        var length: UInt32 = 0
        guard let call = table.pointee.copy_probe_topic else { throw .invalidABI }
        let boundedCapacity = min(capacity, requirements.maxTopicLength)
        try checked(call(table.pointee.context, buffer, boundedCapacity, &length))
        guard length <= boundedCapacity, length <= requirements.maxTopicLength else { throw .invalidABI }
        return length
    }

    /// Copies the carrier-selected probe payload into caller-owned storage.
    public func copyProbePayload(
        into buffer: UnsafeMutablePointer<UInt8>, capacity: UInt32
    ) throws(EmbeddedCapabilityError) -> UInt32 {
        guard requirements.requiresCarrierFunction(10) else { throw .capabilityUnavailable }
        var length: UInt32 = 0
        guard let call = table.pointee.copy_probe_payload else { throw .invalidABI }
        let boundedCapacity = min(capacity, requirements.maxPayloadSize)
        try checked(call(table.pointee.context, buffer, boundedCapacity, &length))
        guard length <= boundedCapacity, length <= requirements.maxPayloadSize else { throw .invalidABI }
        return length
    }
}

/// Outcome of one bounded carrier poll.
public enum EmbeddedCarrierPollResult {
    /// One complete frame was copied into the caller's buffers.
    case event
    /// No complete frame is ready.
    case noEvent
    /// The carrier is closed.
    case closed
}

@inline(__always)
private func checked(_ status: Int32) throws(EmbeddedCapabilityError) {
    switch status {
    case AXOLOTY_ABI_STATUS_OK: return
    case AXOLOTY_ABI_STATUS_INVALID_ARGUMENT: throw .invalidArgument
    case AXOLOTY_ABI_STATUS_BUFFER_TOO_SMALL: throw .insufficientCapacity
    case AXOLOTY_ABI_STATUS_CLOSED: throw .closed
    default: throw .operationFailed
    }
}
