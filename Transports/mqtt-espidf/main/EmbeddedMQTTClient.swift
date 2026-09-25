// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#if EMBEDDED_MQTT_HOST_TEST
import MQTTCarrierInterop
// Host self-tests compile this firmware-local overlay without resolving the
// Embedded Swift package graph. Keep the production limits in sync here.
private enum WireBufferConfig {
    static let maxTopicLength = 256
    static let maxPayloadSize = 2_048
}
#else
import AxolotyWire
#endif

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
        guard state == .idle, !topic.isEmpty,
              topic.count <= WireBufferConfig.maxTopicLength,
              payload.count <= WireBufferConfig.maxPayloadSize else { return false }
        return axoloty_mqtt_configure_last_will(topic, payload) != 0
    }

    public mutating func connect(deadlineMS: UInt32) -> Bool {
        guard state == .idle, axoloty_mqtt_connect_wait(deadlineMS) != 0 else { return false }
        state = .connected
        return true
    }

    public mutating func subscribe(
        topic: Span<UInt8>,
        deadlineMS: UInt32
    ) -> Bool {
        guard state == .connected, !topic.isEmpty,
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
