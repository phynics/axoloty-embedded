// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import MQTTHostTest

@main
private struct EmbeddedMQTTHostTest {
    private static let failWill: UInt32 = 1 << 0
    private static let failConnect: UInt32 = 1 << 1
    private static let failSubscribe: UInt32 = 1 << 2
    private static let failPublish: UInt32 = 1 << 3
    private static let failLoopback: UInt32 = 1 << 4
    private static let failReconnect: UInt32 = 1 << 5
    private static let failDisconnect: UInt32 = 1 << 6
    private static let failUnsubscribe: UInt32 = 1 << 7
    private static let failPoll: UInt32 = 1 << 8

    static func main() {
        precondition(host_identity_tests() != 0, "client identity vectors")
        precondition(host_callback_validation_tests() != 0, "callback validation vectors")
        host_mqtt_reset()

        let topic = Array("coaty/test/topic".utf8)
        let payload = Array("payload".utf8)
        topic.withUnsafeBufferPointer { topicBuffer in
            payload.withUnsafeBufferPointer { payloadBuffer in
                let topicPointer = topicBuffer.baseAddress!
                let payloadPointer = payloadBuffer.baseAddress!
                let topicSpan = Span(_unsafeStart: topicPointer, count: topic.count)
                let payloadSpan = Span(_unsafeStart: payloadPointer, count: payload.count)
                var client = EmbeddedMQTTClient()

                // Invalid order is rejected before entering the HAL.
                precondition(!client.disconnect())
                precondition(!client.publish(topic: topicSpan, payload: payloadSpan))
                precondition(!client.waitForLoopback(deadlineMS: 1))
                precondition(!client.waitForReconnect(deadlineMS: 1))
                precondition(host_mqtt_call_count(3) == 0 && host_mqtt_call_count(4) == 0)

                host_mqtt_set_failures(failWill)
                precondition(!client.configureLastWill(
                    topic: topicSpan, payload: payloadSpan))
                host_mqtt_set_failures(0)
                precondition(client.configureLastWill(
                    topic: topicSpan, payload: payloadSpan))
                precondition(host_mqtt_call_count(0) == 2)

                // A failed connect keeps the client in idle, so retry is safe.
                host_mqtt_set_failures(failConnect)
                precondition(!client.connect(deadlineMS: 1))
                host_mqtt_set_failures(0)
                precondition(client.connect(deadlineMS: 1))
                precondition(!client.configureLastWill(
                    topic: topicSpan, payload: payloadSpan))

                // A failed subscribe keeps the client connected.
                host_mqtt_set_failures(failSubscribe)
                precondition(!client.subscribe(topic: topicSpan, deadlineMS: 1))
                host_mqtt_set_failures(0)
                precondition(client.subscribe(topic: topicSpan, deadlineMS: 1))

                host_mqtt_set_failures(failPublish | failLoopback)
                precondition(!client.publish(topic: topicSpan, payload: payloadSpan))
                precondition(!client.waitForLoopback(deadlineMS: 1))
                host_mqtt_set_failures(0)
                precondition(client.publish(topic: topicSpan, payload: payloadSpan))
                precondition(client.waitForLoopback(deadlineMS: 1))

                var receivedTopic = Array(repeating: UInt8(0), count: 32)
                var receivedPayload = Array(repeating: UInt8(0), count: 8)
                var receivedTopicLength: Int32 = 0
                var receivedPayloadLength: Int32 = 0
                let noEvent = receivedTopic.withUnsafeMutableBufferPointer { topicOutput in
                    receivedPayload.withUnsafeMutableBufferPointer { payloadOutput in
                        client.pollOneEvent(
                            topic: topicOutput.baseAddress!, topicCapacity: Int32(topicOutput.count),
                            topicLength: &receivedTopicLength,
                            payload: payloadOutput.baseAddress!, payloadCapacity: Int32(payloadOutput.count),
                            payloadLength: &receivedPayloadLength
                        )
                    }
                }
                precondition(noEvent == 0)
                host_mqtt_queue_event()
                let received = receivedTopic.withUnsafeMutableBufferPointer { topicOutput in
                    receivedPayload.withUnsafeMutableBufferPointer { payloadOutput in
                        client.pollOneEvent(
                            topic: topicOutput.baseAddress!, topicCapacity: Int32(topicOutput.count),
                            topicLength: &receivedTopicLength,
                            payload: payloadOutput.baseAddress!, payloadCapacity: Int32(payloadOutput.count),
                            payloadLength: &receivedPayloadLength
                        )
                    }
                }
                precondition(received == 1)
                precondition(String(decoding: receivedTopic.prefix(Int(receivedTopicLength)), as: UTF8.self) == "coaty/3/test")
                precondition(String(decoding: receivedPayload.prefix(Int(receivedPayloadLength)), as: UTF8.self) == "{}")
                host_mqtt_set_failures(failPoll)
                let rejectedPoll = receivedTopic.withUnsafeMutableBufferPointer { topicOutput in
                    receivedPayload.withUnsafeMutableBufferPointer { payloadOutput in
                        client.pollOneEvent(
                            topic: topicOutput.baseAddress!, topicCapacity: Int32(topicOutput.count),
                            topicLength: &receivedTopicLength,
                            payload: payloadOutput.baseAddress!, payloadCapacity: Int32(payloadOutput.count),
                            payloadLength: &receivedPayloadLength
                        )
                    }
                }
                precondition(rejectedPoll == -1)
                host_mqtt_set_failures(0)

                host_mqtt_set_failures(failUnsubscribe)
                precondition(!client.unsubscribe(
                    topic: topicSpan, deadlineMS: 1))
                host_mqtt_set_failures(0)
                precondition(client.unsubscribe(
                    topic: topicSpan, deadlineMS: 1))
                precondition(host_mqtt_call_count(7) == 2 && host_mqtt_call_count(8) == 3)

                // Reconnect remains subscribed and asks the HAL to resubscribe.
                host_mqtt_set_failures(failReconnect)
                precondition(!client.waitForReconnect(deadlineMS: 1))
                host_mqtt_set_failures(0)
                precondition(client.waitForReconnect(deadlineMS: 1))
                precondition(host_mqtt_resubscription_count() == 1)

                // Bounds are enforced before every transport call.
                let oversizedTopic = [UInt8](repeating: 0, count: 257)
                let oversizedPayload = [UInt8](repeating: 0, count: 2_049)
                oversizedTopic.withUnsafeBufferPointer { oversizedTopicBuffer in
                    precondition(!client.publish(
                        topic: Span(_unsafeStart: oversizedTopicBuffer.baseAddress!, count: oversizedTopicBuffer.count),
                        payload: payloadSpan
                    ))
                }
                oversizedPayload.withUnsafeBufferPointer { oversizedPayloadBuffer in
                    precondition(!client.publish(
                        topic: topicSpan,
                        payload: Span(_unsafeStart: oversizedPayloadBuffer.baseAddress!, count: oversizedPayloadBuffer.count)
                    ))
                }
                precondition(host_mqtt_call_count(3) == 2)

                host_mqtt_set_failures(failDisconnect)
                precondition(!client.disconnect())
                host_mqtt_set_failures(0)
                precondition(client.disconnect())
                precondition(!client.disconnect())
                precondition(!client.connect(deadlineMS: 1))
                precondition(host_mqtt_call_count(6) == 2)
            }
        }
    }
}
