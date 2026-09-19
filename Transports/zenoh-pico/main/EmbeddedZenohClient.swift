// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Carrier mechanics for the embedded Zenoh transport.
//
// This file owns the bounded, synchronous, non-allocating client surface the
// device side of the Zenoh transport exposes: open, subscribe, publish, poll,
// unsubscribe, close. Topic (Zenoh key expression) and payload bytes are
// borrowed from caller storage, consumed synchronously, and never retained.
// Receive is polled, not pushed: the C carrier copies an inbound sample into
// caller storage and this value never stores a pointer into it.
//
// The `axoloty_zenoh_*` C functions are the device carrier seam. The portable
// Axoloty Zenoh facade ABI is Axoloty's to define (epic #796, tickets
// #801/#802/#803); the device-side implementation of that facade is the
// `zenoh-pico` backend (axoloty-embedded ticket, proposed in
// docs/proposed-issues.md). These declarations are the single adaptation point
// and must track the facade header once it lands.
//
// A transport contains no protocol rule. This file knows carrier operations
// and byte bounds only; it never names a routing key, a frame boundary, or a
// profile decision.

#if EMBEDDED_ZENOH_HOST_TEST
// Host self-tests compile this firmware-local overlay without resolving the
// Embedded Swift package graph. Keep the production limits in sync here.
private enum WireBufferConfig {
    static let maxTopicLength = 256
    static let maxPayloadSize = 2_048
}
#else
import AxolotyWire
#endif

#if EMBEDDED_ZENOH_HOST_TEST
// The host fixture supplies these symbols. The production build receives the
// same declarations from `zenoh_carrier.h` through BridgingHeader.h, so the
// seam adds no runtime layer.
@_silgen_name("axoloty_zenoh_open")
private func axoloty_zenoh_open(_ endpoint: UnsafePointer<UInt8>, _ endpointLength: Int32, _ deadlineMS: UInt32) -> Int32
@_silgen_name("axoloty_zenoh_subscribe")
private func axoloty_zenoh_subscribe(_ key: UnsafePointer<UInt8>, _ keyLength: Int32, _ deadlineMS: UInt32) -> Int32
@_silgen_name("axoloty_zenoh_publish")
private func axoloty_zenoh_publish(_ key: UnsafePointer<UInt8>, _ keyLength: Int32, _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32) -> Int32
@_silgen_name("axoloty_zenoh_poll")
private func axoloty_zenoh_poll(
    _ key: UnsafeMutablePointer<UInt8>, _ keyCapacity: Int32, _ keyLength: UnsafeMutablePointer<Int32>,
    _ payload: UnsafeMutablePointer<UInt8>, _ payloadCapacity: Int32, _ payloadLength: UnsafeMutablePointer<Int32>,
    _ deadlineMS: UInt32
) -> Int32
@_silgen_name("axoloty_zenoh_unsubscribe")
private func axoloty_zenoh_unsubscribe() -> Int32
@_silgen_name("axoloty_zenoh_close")
private func axoloty_zenoh_close() -> Int32
#endif

/// Bounded, synchronous Zenoh operations for the embedded device gate.
///
/// The C carrier owns the session and any worker task. Every byte buffer
/// passed here is consumed synchronously and is never retained by this value.
struct EmbeddedZenohClient {
    private enum State {
        case idle
        case opened
        case subscribed
        case closed
    }

    private var state = State.idle

    init() {}

    mutating func open(
        endpoint: UnsafePointer<UInt8>, endpointLength: Int32,
        deadlineMS: UInt32
    ) -> Bool {
        guard state == .idle, endpointLength > 0,
              endpointLength <= Int32(WireBufferConfig.maxTopicLength),
              axoloty_zenoh_open(endpoint, endpointLength, deadlineMS) != 0 else { return false }
        state = .opened
        return true
    }

    mutating func subscribe(
        key: UnsafePointer<UInt8>, keyLength: Int32,
        deadlineMS: UInt32
    ) -> Bool {
        guard state == .opened, keyLength > 0,
              keyLength <= Int32(WireBufferConfig.maxTopicLength),
              axoloty_zenoh_subscribe(key, keyLength, deadlineMS) != 0 else { return false }
        state = .subscribed
        return true
    }

    func publish(
        key: UnsafePointer<UInt8>, keyLength: Int32,
        payload: UnsafePointer<UInt8>, payloadLength: Int32
    ) -> Bool {
        guard state == .subscribed, keyLength > 0,
              keyLength <= Int32(WireBufferConfig.maxTopicLength),
              payloadLength >= 0, payloadLength <= Int32(WireBufferConfig.maxPayloadSize) else { return false }
        return axoloty_zenoh_publish(key, keyLength, payload, payloadLength) != 0
    }

    /// Copies the next inbound sample into caller storage.
    ///
    /// Returns false when no sample is available within the deadline, when the
    /// caller capacity is out of bounds, or when the carrier reports a
    /// malformed or oversize sample. The caller owns every byte written.
    func poll(
        key: UnsafeMutablePointer<UInt8>, keyCapacity: Int32, keyLength: UnsafeMutablePointer<Int32>,
        payload: UnsafeMutablePointer<UInt8>, payloadCapacity: Int32, payloadLength: UnsafeMutablePointer<Int32>,
        deadlineMS: UInt32
    ) -> Bool {
        guard state == .subscribed,
              keyCapacity > 0, keyCapacity <= Int32(WireBufferConfig.maxTopicLength),
              payloadCapacity >= 0, payloadCapacity <= Int32(WireBufferConfig.maxPayloadSize) else { return false }
        guard axoloty_zenoh_poll(
            key, keyCapacity, keyLength,
            payload, payloadCapacity, payloadLength,
            deadlineMS
        ) != 0 else { return false }
        return keyLength.pointee > 0 &&
            keyLength.pointee <= Int32(WireBufferConfig.maxTopicLength) &&
            payloadLength.pointee >= 0 &&
            payloadLength.pointee <= Int32(WireBufferConfig.maxPayloadSize)
    }

    mutating func unsubscribe() -> Bool {
        guard state == .subscribed, axoloty_zenoh_unsubscribe() != 0 else { return false }
        state = .opened
        return true
    }

    mutating func close() -> Bool {
        guard state == .opened || state == .subscribed, axoloty_zenoh_close() != 0 else { return false }
        state = .closed
        return true
    }
}
