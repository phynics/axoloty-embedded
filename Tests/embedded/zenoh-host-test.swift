// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host self-test for the embedded Zenoh transport seam.
//
// Proves EmbeddedZenohClient enforces operation order and the 256/2048 bounds
// before the carrier C seam is entered. It compiles the real client against a
// host-only fake carrier; it never compiles or links zenoh-pico.

@_silgen_name("host_zenoh_reset")
private func hostZenohReset()
@_silgen_name("host_zenoh_set_failures")
private func hostZenohSetFailures(_ failures: UInt32)
@_silgen_name("host_zenoh_call_count")
private func hostZenohCallCount(_ operation: UInt32) -> UInt32
@_silgen_name("host_zenoh_set_sample")
private func hostZenohSetSample(
    _ key: UnsafePointer<UInt8>?, _ keyLength: Int32,
    _ payload: UnsafePointer<UInt8>?, _ payloadLength: Int32)
@_silgen_name("host_zenoh_sample_validation_tests")
private func hostZenohSampleValidationTests() -> Int32

@main
private struct EmbeddedZenohHostTest {
    private static let failOpen: UInt32 = 1 << 0
    private static let failSubscribe: UInt32 = 1 << 1
    private static let failPublish: UInt32 = 1 << 2
    private static let failPoll: UInt32 = 1 << 3
    private static let failUnsubscribe: UInt32 = 1 << 4
    private static let failClose: UInt32 = 1 << 5

    static func main() {
        precondition(hostZenohSampleValidationTests() != 0, "sample validation vectors")
        hostZenohReset()

        let key = Array("sample/key".utf8)
        let payload = Array("sample/payload".utf8)
        let sampleKey = Array("inbound/key".utf8)
        let samplePayload = Array("inbound/payload".utf8)

        key.withUnsafeBufferPointer { keyBuffer in
            payload.withUnsafeBufferPointer { payloadBuffer in
                let keyPointer = keyBuffer.baseAddress!
                let payloadPointer = payloadBuffer.baseAddress!
                let keyLength = Int32(key.count)
                let payloadLength = Int32(payload.count)

                var client = EmbeddedZenohClient()
                var outKey = [UInt8](repeating: 0, count: 256)
                var outPayload = [UInt8](repeating: 0, count: 2_048)
                var outKeyLength: Int32 = 0
                var outPayloadLength: Int32 = 0

                // Invalid order is rejected before the carrier is entered.
                precondition(!client.subscribe(key: keyPointer, keyLength: keyLength, deadlineMS: 1))
                precondition(!client.unsubscribe())
                precondition(!client.close())
                precondition(!client.publish(
                    key: keyPointer, keyLength: keyLength,
                    payload: payloadPointer, payloadLength: payloadLength))
                outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                    outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                        precondition(!client.poll(
                            key: outKeyBuffer.baseAddress!, keyCapacity: Int32(outKeyBuffer.count),
                            keyLength: &outKeyLength,
                            payload: outPayloadBuffer.baseAddress!, payloadCapacity: Int32(outPayloadBuffer.count),
                            payloadLength: &outPayloadLength, deadlineMS: 1))
                    }
                }
                precondition(hostZenohCallCount(0) == 0 && hostZenohCallCount(1) == 0)
                precondition(hostZenohCallCount(2) == 0 && hostZenohCallCount(3) == 0)
                precondition(hostZenohCallCount(4) == 0 && hostZenohCallCount(5) == 0)

                // A failed open keeps the client idle, so a retry is safe.
                hostZenohSetFailures(failOpen)
                precondition(!client.open(endpoint: keyPointer, endpointLength: keyLength, deadlineMS: 1))
                hostZenohSetFailures(0)
                precondition(client.open(endpoint: keyPointer, endpointLength: keyLength, deadlineMS: 1))
                precondition(!client.open(endpoint: keyPointer, endpointLength: keyLength, deadlineMS: 1))

                // A failed subscribe keeps the session open.
                hostZenohSetFailures(failSubscribe)
                precondition(!client.subscribe(key: keyPointer, keyLength: keyLength, deadlineMS: 1))
                hostZenohSetFailures(0)
                precondition(client.subscribe(key: keyPointer, keyLength: keyLength, deadlineMS: 1))

                // Bounds are enforced before the carrier is entered.
                let publishCalls = hostZenohCallCount(2)
                precondition(!client.publish(key: keyPointer, keyLength: 257, payload: payloadPointer, payloadLength: payloadLength))
                precondition(!client.publish(key: keyPointer, keyLength: keyLength, payload: payloadPointer, payloadLength: 2_049))
                precondition(hostZenohCallCount(2) == publishCalls)

                // A failed publish is reported; a retry succeeds.
                hostZenohSetFailures(failPublish)
                precondition(!client.publish(key: keyPointer, keyLength: keyLength, payload: payloadPointer, payloadLength: payloadLength))
                hostZenohSetFailures(0)
                precondition(client.publish(key: keyPointer, keyLength: keyLength, payload: payloadPointer, payloadLength: payloadLength))

                // Out-of-bounds poll capacities are rejected before the carrier.
                let pollCalls = hostZenohCallCount(3)
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
                precondition(hostZenohCallCount(3) == pollCalls)

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
                        hostZenohSetSample(
                            sampleKeyBuffer.baseAddress!, Int32(sampleKey.count),
                            samplePayloadBuffer.baseAddress!, Int32(samplePayload.count))
                    }
                }
                hostZenohSetFailures(failPoll)
                outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                    outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                        precondition(!client.poll(
                            key: outKeyBuffer.baseAddress!, keyCapacity: Int32(outKeyBuffer.count),
                            keyLength: &outKeyLength,
                            payload: outPayloadBuffer.baseAddress!, payloadCapacity: Int32(outPayloadBuffer.count),
                            payloadLength: &outPayloadLength, deadlineMS: 1))
                    }
                }
                hostZenohSetFailures(0)
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
                hostZenohSetFailures(failUnsubscribe)
                precondition(!client.unsubscribe())
                hostZenohSetFailures(0)
                precondition(client.unsubscribe())
                precondition(!client.publish(key: keyPointer, keyLength: keyLength, payload: payloadPointer, payloadLength: payloadLength))
                precondition(client.subscribe(key: keyPointer, keyLength: keyLength, deadlineMS: 1))

                // Close is terminal.
                hostZenohSetFailures(failClose)
                precondition(!client.close())
                hostZenohSetFailures(0)
                precondition(client.close())
                precondition(!client.close())
                precondition(!client.open(endpoint: keyPointer, endpointLength: keyLength, deadlineMS: 1))
            }
        }
    }
}
