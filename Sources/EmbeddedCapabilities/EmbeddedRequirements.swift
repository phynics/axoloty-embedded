// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Marker emitted by composition only when heap diagnostics provide both trace operations.
///
/// Trace-enabled application entries use this constraint to make a missing
/// manifest trace contract a compile-time error.
public protocol EmbeddedHeapTraceInitializationRequirements {}

/// Fixed requirements generated from the selected application's `app.json`.
public struct EmbeddedRequirements {
    /// Required platform capability bits from the v1 platform ABI.
    public let platformCapabilities: UInt64
    /// Required carrier capability bits from the v1 carrier ABI.
    public let carrierCapabilities: UInt64
    /// Required platform function fields, indexed by the Interop catalog.
    public let platformFunctions: UInt64
    /// Required carrier function fields, indexed by the Interop catalog.
    public let carrierFunctions: UInt64
    /// Maximum accepted topic byte count.
    public let maxTopicLength: UInt32
    /// Maximum accepted payload byte count.
    public let maxPayloadSize: UInt32
    /// Maximum app state stride in bytes, counted across `.data` and `.bss`.
    public let applicationStateBytes: UInt32

    /// Returns whether the selected manifest requires a platform field.
    public func requiresPlatformFunction(_ index: UInt32) -> Bool {
        index < 64 && (platformFunctions & (UInt64(1) << index)) != 0
    }

    /// Returns whether the selected manifest requires a carrier field.
    public func requiresCarrierFunction(_ index: UInt32) -> Bool {
        index < 64 && (carrierFunctions & (UInt64(1) << index)) != 0
    }

    /// Creates one immutable manifest-derived requirement record.
    public init(
        platformCapabilities: UInt64,
        carrierCapabilities: UInt64,
        platformFunctions: UInt64,
        carrierFunctions: UInt64,
        maxTopicLength: UInt32,
        maxPayloadSize: UInt32,
        applicationStateBytes: UInt32
    ) {
        self.platformCapabilities = platformCapabilities
        self.carrierCapabilities = carrierCapabilities
        self.platformFunctions = platformFunctions
        self.carrierFunctions = carrierFunctions
        self.maxTopicLength = maxTopicLength
        self.maxPayloadSize = maxPayloadSize
        self.applicationStateBytes = applicationStateBytes
    }
}
