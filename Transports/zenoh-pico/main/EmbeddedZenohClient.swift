// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Carrier mechanics for the embedded Zenoh transport.
//
// This file owns the bounded, synchronous, non-allocating client surface the
// device side of the Zenoh transport exposes: open, subscribe, publish, poll,
// unsubscribe, close. Key (Zenoh key expression) and payload bytes are borrowed
// from caller storage, consumed synchronously, and never retained. Receive is
// polled, not pushed: a C callback copies one bounded frame into facade-owned
// storage and this value never stores a pointer into it.
//
// The C seam is the Core-owned Axoloty Zenoh facade ABI, declared by
// `axoloty_zenoh.h` and implemented on the device by the `zenoh-pico` backend
// (`zenoh_pico_facade.c`). This file is the single adaptation point: it turns
// borrowed spans into that ABI's bounded calls and its result codes into
// booleans. It restates none of the ABI; the bounds below are the device
// client's own wire limits, mirroring `WireBufferConfig`.
//
// A transport contains no protocol rule. This file knows carrier operations
// and byte bounds only; it never names a routing key, a frame boundary, or a
// profile decision.

#if EMBEDDED_ZENOH_HOST_TEST
import CAxolotyZenoh
// Host self-tests compile this firmware-local overlay without resolving the
// Embedded Swift package graph. Keep the production limits in sync here.
private enum WireBufferConfig {
    static let maxTopicLength = 256
    static let maxPayloadSize = 2_048
}
#else
import AxolotyWire
#endif

/// Bounded, synchronous Zenoh operations for the embedded device gate.
///
/// Every byte buffer passed here is consumed synchronously and is never
/// retained by this value. The session and subscription handles are opaque and
/// belong to the facade, so a failed call never leaves a usable handle behind.
struct EmbeddedZenohClient {
    private enum State {
        case idle
        case opened
        case subscribed
        case closed
    }

    private var state = State.idle
    private var session: OpaquePointer?
    private var subscription: OpaquePointer?

    init() {}

    /// Opens one session for a borrowed connect endpoint.
    ///
    /// The facade bounds its own unicast open, so no deadline is taken here.
    /// A failed open leaves the client idle, which makes a retry safe.
    mutating func open(endpoint: Span<UInt8>, multicastScouting: Bool) -> Bool {
        guard state == .idle, !endpoint.isEmpty,
              endpoint.count <= WireBufferConfig.maxTopicLength,
              session == nil else { return false }
        var opened: OpaquePointer?
        let result = endpoint.withUnsafeBytes { bytes in
            var config = axoloty_zenoh_config_t(
                mode: AXOLOTY_ZENOH_MODE_CLIENT,
                connect_endpoint: bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                connect_endpoint_length: UInt32(endpoint.count),
                multicast_scouting_enabled: multicastScouting)
            return axoloty_zenoh_open(&config, &opened)
        }
        guard result == AXOLOTY_ZENOH_OK, let handle = opened else { return false }
        session = handle
        state = .opened
        return true
    }

    /// Declares one bounded subscription with its own receive queue.
    mutating func subscribe(key: Span<UInt8>) -> Bool {
        guard state == .opened, !key.isEmpty,
              key.count <= WireBufferConfig.maxTopicLength,
              let handle = session, subscription == nil else { return false }
        var declared: OpaquePointer?
        let result = key.withUnsafeBytes { bytes in
            axoloty_zenoh_subscribe(
                handle, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt32(key.count), &declared)
        }
        guard result == AXOLOTY_ZENOH_OK, let subscriptionHandle = declared else { return false }
        subscription = subscriptionHandle
        state = .subscribed
        return true
    }

    /// Publishes one bounded key and payload.
    ///
    /// The facade copies both into Zenoh-owned values before it calls Zenoh, so
    /// the spans do not outlive this call.
    func publish(key: Span<UInt8>, payload: Span<UInt8>) -> Bool {
        guard state == .subscribed, !key.isEmpty,
              key.count <= WireBufferConfig.maxTopicLength,
              payload.count <= WireBufferConfig.maxPayloadSize,
              let handle = session else { return false }
        return key.withUnsafeBytes { keyBytes in
            payload.withUnsafeBytes { payloadBytes in
                axoloty_zenoh_publish(
                    handle,
                    keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(key.count),
                    payloadBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt32(payload.count)) == AXOLOTY_ZENOH_OK
            }
        }
    }

    /// Copies the oldest queued frame into caller storage.
    ///
    /// Returns the facade result code so the caller can tell a complete frame
    /// from an empty queue and from a reported drop. The caller owns every byte
    /// written, and a frame that does not fit the supplied capacity is left
    /// queued.
    func poll(
        key: UnsafeMutablePointer<UInt8>, keyCapacity: UInt32, keyLength: UnsafeMutablePointer<UInt32>,
        payload: UnsafeMutablePointer<UInt8>, payloadCapacity: UInt32, payloadLength: UnsafeMutablePointer<UInt32>
    ) -> axoloty_zenoh_result_t {
        guard state == .subscribed,
              keyCapacity > 0, keyCapacity <= UInt32(WireBufferConfig.maxTopicLength),
              payloadCapacity <= UInt32(WireBufferConfig.maxPayloadSize),
              let handle = session, let subscriptionHandle = subscription else {
            return AXOLOTY_ZENOH_INVALID_ARGUMENT
        }
        return axoloty_zenoh_poll(
            handle, subscriptionHandle,
            key, keyCapacity, keyLength,
            payload, payloadCapacity, payloadLength)
    }

    /// Reads the current receive queue depth, or -1 when it cannot be read.
    func queueDepth() -> Int32 {
        guard let handle = session, let subscriptionHandle = subscription else { return -1 }
        var depth: UInt32 = 0
        guard axoloty_zenoh_queue_depth(handle, subscriptionHandle, &depth) == AXOLOTY_ZENOH_OK else {
            return -1
        }
        return Int32(bitPattern: depth)
    }

    /// Removes the current subscription and keeps the session open.
    mutating func unsubscribe() -> Bool {
        guard state == .subscribed, let handle = session, let subscriptionHandle = subscription else {
            return false
        }
        guard axoloty_zenoh_unsubscribe(handle, subscriptionHandle) == AXOLOTY_ZENOH_OK else { return false }
        subscription = nil
        state = .opened
        return true
    }

    /// Closes the session. Close is terminal.
    mutating func close() -> Bool {
        guard state == .opened || state == .subscribed, let handle = session else { return false }
        let result = axoloty_zenoh_close(handle)
        session = nil
        subscription = nil
        state = .closed
        return result == AXOLOTY_ZENOH_OK
    }
}
