// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host self-test for the embedded Zenoh transport seam.
//
// Proves EmbeddedZenohClient enforces operation order and the 256/2048 bounds
// before the carrier C seam is entered. It compiles the real client against a
// host-only fake carrier; it never compiles or links zenoh-pico.

import ZenohHostTest

@main
private struct EmbeddedZenohHostTest {
    private static let failOpen: UInt32 = 1 << 0
    private static let failSubscribe: UInt32 = 1 << 1
    private static let failPublish: UInt32 = 1 << 2
    private static let failPoll: UInt32 = 1 << 3
    private static let failUnsubscribe: UInt32 = 1 << 4
    private static let failClose: UInt32 = 1 << 5

    static func main() {
        precondition(host_zenoh_sample_validation_tests() != 0, "sample validation vectors")
        host_zenoh_reset()

        let key = Array("sample/key".utf8)
        let payload = Array("sample/payload".utf8)
        let sampleKey = Array("inbound/key".utf8)
        let samplePayload = Array("inbound/payload".utf8)

        key.withUnsafeBufferPointer { keyBuffer in
            payload.withUnsafeBufferPointer { payloadBuffer in
                let keyPointer = keyBuffer.baseAddress!
                let payloadPointer = payloadBuffer.baseAddress!
                let keySpan = Span(_unsafeStart: keyPointer, count: key.count)
                let payloadSpan = Span(_unsafeStart: payloadPointer, count: payload.count)

                var client = EmbeddedZenohClient()
                var outKey = [UInt8](repeating: 0, count: 256)
                var outPayload = [UInt8](repeating: 0, count: 2_048)
                var outKeyLength: Int32 = 0
                var outPayloadLength: Int32 = 0

                // Invalid order is rejected before the carrier is entered.
                precondition(!client.subscribe(key: keySpan, deadlineMS: 1))
                precondition(!client.unsubscribe())
                precondition(!client.close())
                precondition(!client.publish(
                    key: keySpan, payload: payloadSpan))
                outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                    outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                        precondition(!client.poll(
                            key: outKeyBuffer.baseAddress!, keyCapacity: Int32(outKeyBuffer.count),
                            keyLength: &outKeyLength,
                            payload: outPayloadBuffer.baseAddress!, payloadCapacity: Int32(outPayloadBuffer.count),
                            payloadLength: &outPayloadLength, deadlineMS: 1))
                    }
                }
                precondition(host_zenoh_call_count(0) == 0 && host_zenoh_call_count(1) == 0)
                precondition(host_zenoh_call_count(2) == 0 && host_zenoh_call_count(3) == 0)
                precondition(host_zenoh_call_count(4) == 0 && host_zenoh_call_count(5) == 0)

                // A failed open keeps the client idle, so a retry is safe.
                host_zenoh_set_failures(failOpen)
                precondition(!client.open(endpoint: keySpan, deadlineMS: 1))
                host_zenoh_set_failures(0)
                precondition(client.open(endpoint: keySpan, deadlineMS: 1))
                precondition(!client.open(endpoint: keySpan, deadlineMS: 1))

                // A failed subscribe keeps the session open.
                host_zenoh_set_failures(failSubscribe)
                precondition(!client.subscribe(key: keySpan, deadlineMS: 1))
                host_zenoh_set_failures(0)
                precondition(client.subscribe(key: keySpan, deadlineMS: 1))

                // Bounds are enforced before the carrier is entered.
                let publishCalls = host_zenoh_call_count(2)
                let oversizedKey = [UInt8](repeating: 0, count: 257)
                let oversizedPayload = [UInt8](repeating: 0, count: 2_049)
                oversizedKey.withUnsafeBufferPointer { oversizedKeyBuffer in
                    precondition(!client.publish(
                        key: Span(_unsafeStart: oversizedKeyBuffer.baseAddress!, count: oversizedKeyBuffer.count),
                        payload: payloadSpan
                    ))
                }
                oversizedPayload.withUnsafeBufferPointer { oversizedPayloadBuffer in
                    precondition(!client.publish(
                        key: keySpan,
                        payload: Span(_unsafeStart: oversizedPayloadBuffer.baseAddress!, count: oversizedPayloadBuffer.count)
                    ))
                }
                precondition(host_zenoh_call_count(2) == publishCalls)

                // A failed publish is reported; a retry succeeds.
                host_zenoh_set_failures(failPublish)
                precondition(!client.publish(key: keySpan, payload: payloadSpan))
                host_zenoh_set_failures(0)
                precondition(client.publish(key: keySpan, payload: payloadSpan))

                // Out-of-bounds poll capacities are rejected before the carrier.
                let pollCalls = host_zenoh_call_count(3)
                outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                    outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                        precondition(!client.poll(
                            key: outKeyBuffer.baseAddress!, keyCapacity: 0, keyLength: &outKeyLength,
                            payload: outPayloadBuffer.baseAddress!, payloadCapacity: Int32(outPayloadBuffer.count),
                            payloadLength: &outPayloadLength, deadlineMS: 1))
                        precondition(!client.poll(
                            key: outKeyBuffer.baseAddress!, keyCapacity: Int32(outKeyBuffer.count),
                            keyLength: &outKeyLength,
                            payload: outPayloadBuffer.baseAddress!, payloadCapacity: 2_049,
                            payloadLength: &outPayloadLength, deadlineMS: 1))
                    }
                }
                precondition(host_zenoh_call_count(3) == pollCalls)

                // No sample yet: poll reports false without writing lengths.
                outKeyLength = -1
                outPayloadLength = -1
                outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                    outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                        precondition(!client.poll(
                            key: outKeyBuffer.baseAddress!, keyCapacity: Int32(outKeyBuffer.count),
                            keyLength: &outKeyLength,
                            payload: outPayloadBuffer.baseAddress!, payloadCapacity: Int32(outPayloadBuffer.count),
                            payloadLength: &outPayloadLength, deadlineMS: 1))
                    }
                }

                // A provided sample is copied into caller storage, and a
                // carrier poll failure is reported without consuming it.
                sampleKey.withUnsafeBufferPointer { sampleKeyBuffer in
                    samplePayload.withUnsafeBufferPointer { samplePayloadBuffer in
                        host_zenoh_set_sample(
                            sampleKeyBuffer.baseAddress!, Int32(sampleKey.count),
                            samplePayloadBuffer.baseAddress!, Int32(samplePayload.count))
                    }
                }
                host_zenoh_set_failures(failPoll)
                outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                    outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                        precondition(!client.poll(
                            key: outKeyBuffer.baseAddress!, keyCapacity: Int32(outKeyBuffer.count),
                            keyLength: &outKeyLength,
                            payload: outPayloadBuffer.baseAddress!, payloadCapacity: Int32(outPayloadBuffer.count),
                            payloadLength: &outPayloadLength, deadlineMS: 1))
                    }
                }
                host_zenoh_set_failures(0)
                outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                    outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                        precondition(client.poll(
                            key: outKeyBuffer.baseAddress!, keyCapacity: Int32(outKeyBuffer.count),
                            keyLength: &outKeyLength,
                            payload: outPayloadBuffer.baseAddress!, payloadCapacity: Int32(outPayloadBuffer.count),
                            payloadLength: &outPayloadLength, deadlineMS: 1))
                        precondition(outKeyLength == Int32(sampleKey.count))
                        precondition(outPayloadLength == Int32(samplePayload.count))
                        for index in 0..<sampleKey.count {
                            precondition(outKeyBuffer[index] == sampleKey[index])
                        }
                        for index in 0..<samplePayload.count {
                            precondition(outPayloadBuffer[index] == samplePayload[index])
                        }
                    }
                }

                // Unsubscribe returns to the open state; publishing is refused.
                host_zenoh_set_failures(failUnsubscribe)
                precondition(!client.unsubscribe())
                host_zenoh_set_failures(0)
                precondition(client.unsubscribe())
                precondition(!client.publish(key: keySpan, payload: payloadSpan))
                precondition(client.subscribe(key: keySpan, deadlineMS: 1))

                // Close is terminal.
                host_zenoh_set_failures(failClose)
                precondition(!client.close())
                host_zenoh_set_failures(0)
                precondition(client.close())
                precondition(!client.close())
                precondition(!client.open(endpoint: keySpan, deadlineMS: 1))
            }
        }
    }
}
