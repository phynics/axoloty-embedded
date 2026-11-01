// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#if EMBEDDED_MQTT_HOST_TEST
import MQTTCarrierInterop
#endif
#if EMBEDDED_MQTT_HOST_PACKAGE
import HostCarrierBounds
#endif

/// The bounds this carrier admits: the topic and payload capacities the
/// composition took from the selected application (`EmbeddedCarrierBounds`),
/// the same values the C side sizes its buffers to.
private enum WireBufferConfig {
    static let maxTopicLength = EmbeddedCarrierBounds.maxTopicLength
    static let maxPayloadSize = EmbeddedCarrierBounds.maxPayloadSize
}

/// Bounded, synchronous MQTT operations for the single-device embedded gate.
///
/// ESP-MQTT owns the client handle and callback in C. Every byte buffer passed
/// here is consumed synchronously and is never retained by this value.
public struct EmbeddedMQTTClient {
    private enum State {
        case idle
        case connected
        case subscribed
        case disconnected
    }

    private var state = State.idle

    public init() {}

    public mutating func configureLastWill(
        topic: Span<UInt8>,
        payload: Span<UInt8>
    ) -> Bool {
        // A disconnected client starts a new session, so it takes a last will again.
        guard state == .idle || state == .disconnected, !topic.isEmpty,
              topic.count <= WireBufferConfig.maxTopicLength,
              payload.count <= WireBufferConfig.maxPayloadSize else { return false }
        return axoloty_mqtt_configure_last_will(topic, payload) != 0
    }

    public mutating func connect(deadlineMS: UInt32) -> Bool {
        // A disconnected client may connect again: a node that lost its broker
        // reconnects without a restart. Disconnect destroyed the C client.
        guard state == .idle || state == .disconnected, axoloty_mqtt_connect_wait(deadlineMS) != 0 else { return false }
        state = .connected
        return true
    }

    public mutating func subscribe(
        topic: Span<UInt8>,
        deadlineMS: UInt32
    ) -> Bool {
        // The C layer owns the filter set and admits up to four concurrent
        // filters; Swift tracks the lifecycle phase only, so subscribing
        // while subscribed installs another filter and stays subscribed.
        guard state == .connected || state == .subscribed, !topic.isEmpty,
              topic.count <= WireBufferConfig.maxTopicLength,
              axoloty_mqtt_subscribe_wait(topic, deadlineMS) != 0 else { return false }
        state = .subscribed
        return true
    }

    public func publish(
        topic: Span<UInt8>,
        payload: Span<UInt8>
    ) -> Bool {
        guard state == .subscribed, !topic.isEmpty,
              topic.count <= WireBufferConfig.maxTopicLength,
              payload.count <= WireBufferConfig.maxPayloadSize else { return false }
        return axoloty_mqtt_publish(topic, payload) != 0
    }

    public func unsubscribe(
        topic: Span<UInt8>,
        deadlineMS: UInt32
    ) -> Bool {
        guard state == .subscribed, !topic.isEmpty,
              topic.count <= WireBufferConfig.maxTopicLength else { return false }
        _ = deadlineMS
        return axoloty_mqtt_unsubscribe(topic) != 0
    }

    /// Copies one complete queued carrier frame into caller-owned fixed storage.
    /// Returns one for a frame, zero when the queue is empty, and a negative
    /// status for overflow, invalid storage, or a closed carrier.
    public func pollOneEvent(
        topic: UnsafeMutablePointer<UInt8>, topicCapacity: Int32,
        topicLength: UnsafeMutablePointer<Int32>,
        payload: UnsafeMutablePointer<UInt8>, payloadCapacity: Int32,
        payloadLength: UnsafeMutablePointer<Int32>
    ) -> Int32 {
        guard state == .subscribed,
              topicCapacity > 0, topicCapacity <= Int32(WireBufferConfig.maxTopicLength),
              payloadCapacity >= 0, payloadCapacity <= Int32(WireBufferConfig.maxPayloadSize) else { return -1 }
        let result = axoloty_mqtt_poll_one_event(
            topic, topicCapacity, topicLength, payload, payloadCapacity, payloadLength
        )
        if result == 1 && (topicLength.pointee <= 0 || topicLength.pointee > topicCapacity ||
                           payloadLength.pointee < 0 || payloadLength.pointee > payloadCapacity) {
            return -1
        }
        return result
    }

    public func waitForLoopback(deadlineMS: UInt32) -> Bool {
        state == .subscribed && axoloty_mqtt_wait_loopback(deadlineMS) != 0
    }

    public func waitForReconnect(deadlineMS: UInt32) -> Bool {
        state == .subscribed && axoloty_mqtt_reconnect_wait(deadlineMS) != 0
    }

    public mutating func disconnect() -> Bool {
        guard state == .connected || state == .subscribed else { return false }
        guard axoloty_mqtt_disconnect() != 0 else { return false }
        state = .disconnected
        return true
    }
}

// The application owns one synchronous agent exchange at a time. This
// transport-owned adapter keeps the stateful client behind the application's
// carrier function table without making the application import this module.
nonisolated(unsafe) private var applicationExchangeClient = EmbeddedMQTTClient()

func embeddedExchangeConfigureLastWill(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 {
    guard topicLength > 0, topicLength <= Int32(WireBufferConfig.maxTopicLength),
          payloadLength >= 0, payloadLength <= Int32(WireBufferConfig.maxPayloadSize) else { return 0 }
    return applicationExchangeClient.configureLastWill(
        topic: Span(_unsafeStart: topic, count: Int(topicLength)),
        payload: Span(_unsafeStart: payload, count: Int(payloadLength))
    ) ? 1 : 0
}

func embeddedExchangeSupportsLastWill() -> Int32 { 1 }

func embeddedExchangeConnect(_ deadlineMS: UInt32) -> Int32 {
    applicationExchangeClient.connect(deadlineMS: deadlineMS) ? 1 : 0
}

func embeddedExchangeSubscribe(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ deadlineMS: UInt32
) -> Int32 {
    guard topicLength > 0, topicLength <= Int32(WireBufferConfig.maxTopicLength) else { return 0 }
    return applicationExchangeClient.subscribe(
        topic: Span(_unsafeStart: topic, count: Int(topicLength)), deadlineMS: deadlineMS
    ) ? 1 : 0
}

func embeddedExchangeUnsubscribe(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32, _ deadlineMS: UInt32
) -> Int32 {
    guard topicLength > 0, topicLength <= Int32(WireBufferConfig.maxTopicLength) else { return 0 }
    return applicationExchangeClient.unsubscribe(
        topic: Span(_unsafeStart: topic, count: Int(topicLength)), deadlineMS: deadlineMS
    ) ? 1 : 0
}

func embeddedExchangePublish(
    _ topic: UnsafePointer<UInt8>, _ topicLength: Int32,
    _ payload: UnsafePointer<UInt8>, _ payloadLength: Int32
) -> Int32 {
    guard topicLength > 0, topicLength <= Int32(WireBufferConfig.maxTopicLength),
          payloadLength >= 0, payloadLength <= Int32(WireBufferConfig.maxPayloadSize) else { return 0 }
    return applicationExchangeClient.publish(
        topic: Span(_unsafeStart: topic, count: Int(topicLength)),
        payload: Span(_unsafeStart: payload, count: Int(payloadLength))
    ) ? 1 : 0
}

func embeddedExchangePollOneEvent(
    _ topic: UnsafeMutablePointer<UInt8>, _ topicCapacity: Int32, _ topicLength: UnsafeMutablePointer<Int32>,
    _ payload: UnsafeMutablePointer<UInt8>, _ payloadCapacity: Int32, _ payloadLength: UnsafeMutablePointer<Int32>
) -> Int32 {
    applicationExchangeClient.pollOneEvent(
        topic: topic, topicCapacity: topicCapacity, topicLength: topicLength,
        payload: payload, payloadCapacity: payloadCapacity, payloadLength: payloadLength
    )
}

func embeddedExchangeWaitForReconnect(_ deadlineMS: UInt32) -> Int32 {
    applicationExchangeClient.waitForReconnect(deadlineMS: deadlineMS) ? 1 : 0
}

func embeddedExchangeDisconnect() -> Int32 {
    applicationExchangeClient.disconnect() ? 1 : 0
}

@_cdecl("axoloty_mqtt_v1_supports_last_will")
public func axoloty_mqtt_v1_supports_last_will(
    _ context: UnsafeMutableRawPointer?, _ supported: UnsafeMutablePointer<UInt32>?
) -> Int32 {
    _ = context
    guard let supported else { return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT }
    supported.pointee = embeddedExchangeSupportsLastWill() == 0 ? 0 : 1
    return AXOLOTY_ABI_STATUS_OK
}

@_cdecl("axoloty_mqtt_v1_configure_last_will")
public func axoloty_mqtt_v1_configure_last_will(
    _ context: UnsafeMutableRawPointer?, _ topic: UnsafePointer<UInt8>?, _ topicLength: UInt32,
    _ payload: UnsafePointer<UInt8>?, _ payloadLength: UInt32
) -> Int32 {
    _ = context
    guard let topic, let payload, topicLength <= UInt32(Int32.max), payloadLength <= UInt32(Int32.max) else {
        return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT
    }
    return embeddedExchangeConfigureLastWill(topic, Int32(topicLength), payload, Int32(payloadLength)) != 0
        ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_mqtt_v1_connect")
public func axoloty_mqtt_v1_connect(_ context: UnsafeMutableRawPointer?, _ deadline: UInt32) -> Int32 {
    _ = context
    return embeddedExchangeConnect(deadline) != 0 ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_mqtt_v1_subscribe")
public func axoloty_mqtt_v1_subscribe(
    _ context: UnsafeMutableRawPointer?, _ topic: UnsafePointer<UInt8>?, _ length: UInt32, _ deadline: UInt32
) -> Int32 {
    _ = context
    guard let topic, length <= UInt32(Int32.max) else { return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT }
    return embeddedExchangeSubscribe(topic, Int32(length), deadline) != 0
        ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_mqtt_v1_unsubscribe")
public func axoloty_mqtt_v1_unsubscribe(
    _ context: UnsafeMutableRawPointer?, _ topic: UnsafePointer<UInt8>?, _ length: UInt32, _ deadline: UInt32
) -> Int32 {
    _ = context
    guard let topic, length <= UInt32(Int32.max) else { return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT }
    return embeddedExchangeUnsubscribe(topic, Int32(length), deadline) != 0
        ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_mqtt_v1_publish")
public func axoloty_mqtt_v1_publish(
    _ context: UnsafeMutableRawPointer?, _ topic: UnsafePointer<UInt8>?, _ topicLength: UInt32,
    _ payload: UnsafePointer<UInt8>?, _ payloadLength: UInt32
) -> Int32 {
    _ = context
    guard let topic, let payload, topicLength <= UInt32(Int32.max), payloadLength <= UInt32(Int32.max) else {
        return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT
    }
    return embeddedExchangePublish(topic, Int32(topicLength), payload, Int32(payloadLength)) != 0
        ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_mqtt_v1_poll_one_event")
public func axoloty_mqtt_v1_poll_one_event(
    _ context: UnsafeMutableRawPointer?, _ topic: UnsafeMutablePointer<UInt8>?, _ topicCapacity: UInt32,
    _ topicLength: UnsafeMutablePointer<UInt32>?, _ payload: UnsafeMutablePointer<UInt8>?,
    _ payloadCapacity: UInt32, _ payloadLength: UnsafeMutablePointer<UInt32>?
) -> Int32 {
    _ = context
    guard let topic, let topicLength, let payload, let payloadLength,
          topicCapacity <= UInt32(Int32.max), payloadCapacity <= UInt32(Int32.max) else {
        return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT
    }
    var copiedTopicLength: Int32 = 0
    var copiedPayloadLength: Int32 = 0
    let status = embeddedExchangePollOneEvent(
        topic, Int32(topicCapacity), &copiedTopicLength,
        payload, Int32(payloadCapacity), &copiedPayloadLength
    )
    if status == 1 {
        topicLength.pointee = UInt32(copiedTopicLength)
        payloadLength.pointee = UInt32(copiedPayloadLength)
        return AXOLOTY_ABI_STATUS_OK
    }
    if status == 0 { return AXOLOTY_ABI_STATUS_NO_EVENT }
    if status == -2 { return AXOLOTY_ABI_STATUS_CLOSED }
    return AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_mqtt_v1_wait_for_reconnect")
public func axoloty_mqtt_v1_wait_for_reconnect(_ context: UnsafeMutableRawPointer?, _ deadline: UInt32) -> Int32 {
    _ = context
    return embeddedExchangeWaitForReconnect(deadline) != 0 ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_mqtt_v1_wait_for_loopback")
public func axoloty_mqtt_v1_wait_for_loopback(_ context: UnsafeMutableRawPointer?, _ deadline: UInt32) -> Int32 {
    _ = context
    return applicationExchangeClient.waitForLoopback(deadlineMS: deadline)
        ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}

@_cdecl("axoloty_mqtt_v1_disconnect")
public func axoloty_mqtt_v1_disconnect(_ context: UnsafeMutableRawPointer?) -> Int32 {
    _ = context
    return embeddedExchangeDisconnect() != 0 ? AXOLOTY_ABI_STATUS_OK : AXOLOTY_ABI_STATUS_FAILED
}
