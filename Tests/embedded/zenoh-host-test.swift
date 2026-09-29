// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host self-test for the embedded Zenoh transport seam.
//
// Proves EmbeddedZenohClient enforces operation order, handle lifetime, and the
// 256/2048 bounds before the carrier C seam is entered, and that it reads the
// Core-owned facade result codes back. It compiles the real client against a
// host-only fake carrier; it never compiles or links zenoh-pico.

import CAxolotyZenoh
import ZenohHostTest

@main
private struct EmbeddedZenohHostTest {
    static func main() {
        precondition(host_zenoh_sample_validation_tests() != 0, "sample validation vectors")
        precondition(host_zenoh_queue_tests() != 0, "bounded receive queue conformance")
        host_zenoh_reset()

        let endpoint = Array("tcp/127.0.0.1:7447".utf8)
        let key = Array("sample/key".utf8)
        let payload = Array("sample/payload".utf8)
        let sampleKey = Array("inbound/key".utf8)
        let samplePayload = Array("inbound/payload".utf8)

        endpoint.withUnsafeBufferPointer { endpointBuffer in
            key.withUnsafeBufferPointer { keyBuffer in
                payload.withUnsafeBufferPointer { payloadBuffer in
                    let endpointSpan = Span(_unsafeStart: endpointBuffer.baseAddress!, count: endpoint.count)
                    let keySpan = Span(_unsafeStart: keyBuffer.baseAddress!, count: key.count)
                    let payloadSpan = Span(_unsafeStart: payloadBuffer.baseAddress!, count: payload.count)

                    var client = EmbeddedZenohClient()
                    var outKey = [UInt8](repeating: 0, count: 256)
                    var outPayload = [UInt8](repeating: 0, count: 2_048)
                    var outKeyLength: UInt32 = 0
                    var outPayloadLength: UInt32 = 0

                    // Invalid order is rejected before the carrier is entered.
                    precondition(!client.subscribe(key: keySpan))
                    precondition(!client.unsubscribe())
                    precondition(!client.close())
                    precondition(!client.publish(key: keySpan, payload: payloadSpan))
                    precondition(client.queueDepth() == -1)
                    outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                        outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                            precondition(client.poll(
                                key: outKeyBuffer.baseAddress!, keyCapacity: UInt32(outKeyBuffer.count),
                                keyLength: &outKeyLength,
                                payload: outPayloadBuffer.baseAddress!, payloadCapacity: UInt32(outPayloadBuffer.count),
                                payloadLength: &outPayloadLength) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
                        }
                    }
                    precondition(host_zenoh_call_count(0) == 0 && host_zenoh_call_count(1) == 0)
                    precondition(host_zenoh_call_count(2) == 0 && host_zenoh_call_count(3) == 0)
                    precondition(host_zenoh_call_count(4) == 0 && host_zenoh_call_count(5) == 0)

                    // A failed open keeps the client idle, so a retry is safe.
                    host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_OPEN))
                    precondition(!client.open(endpoint: endpointSpan, multicastScouting: false))
                    host_zenoh_set_failures(0)
                    precondition(client.open(endpoint: endpointSpan, multicastScouting: true))
                    precondition(host_zenoh_session_multicast(0) == 1)
                    precondition(host_zenoh_session_endpoint_length(0) == UInt32(endpoint.count))
                    precondition(!client.open(endpoint: endpointSpan, multicastScouting: false))

                    // A failed subscribe keeps the session open.
                    host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_SUBSCRIBE))
                    precondition(!client.subscribe(key: keySpan))
                    host_zenoh_set_failures(0)
                    precondition(client.subscribe(key: keySpan))

                    // Bounds are enforced before the carrier is entered.
                    let publishCalls = host_zenoh_call_count(2)
                    let subscribeCalls = host_zenoh_call_count(1)
                    let oversizedKey = [UInt8](repeating: 0, count: 257)
                    let oversizedPayload = [UInt8](repeating: 0, count: 2_049)
                    oversizedKey.withUnsafeBufferPointer { oversizedKeyBuffer in
                        precondition(!client.publish(
                            key: Span(_unsafeStart: oversizedKeyBuffer.baseAddress!, count: oversizedKeyBuffer.count),
                            payload: payloadSpan
                        ))
                        precondition(!client.subscribe(
                            key: Span(_unsafeStart: oversizedKeyBuffer.baseAddress!, count: oversizedKeyBuffer.count)
                        ))
                    }
                    oversizedPayload.withUnsafeBufferPointer { oversizedPayloadBuffer in
                        precondition(!client.publish(
                            key: keySpan,
                            payload: Span(_unsafeStart: oversizedPayloadBuffer.baseAddress!, count: oversizedPayloadBuffer.count)
                        ))
                    }
                    precondition(host_zenoh_call_count(2) == publishCalls)
                    precondition(host_zenoh_call_count(1) == subscribeCalls)

                    // A failed publish is reported; a retry succeeds and the
                    // borrowed spans are consumed, never retained.
                    host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_PUBLISH))
                    precondition(!client.publish(key: keySpan, payload: payloadSpan))
                    host_zenoh_set_failures(0)
                    precondition(client.publish(key: keySpan, payload: payloadSpan))
                    precondition(host_zenoh_publish_key_length() == UInt32(key.count))
                    precondition(host_zenoh_publish_payload_length() == UInt32(payload.count))

                    // Out-of-bounds poll capacities are rejected before the carrier.
                    let pollCalls = host_zenoh_call_count(3)
                    outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                        outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                            precondition(client.poll(
                                key: outKeyBuffer.baseAddress!, keyCapacity: 0, keyLength: &outKeyLength,
                                payload: outPayloadBuffer.baseAddress!, payloadCapacity: UInt32(outPayloadBuffer.count),
                                payloadLength: &outPayloadLength) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
                            precondition(client.poll(
                                key: outKeyBuffer.baseAddress!, keyCapacity: UInt32(outKeyBuffer.count),
                                keyLength: &outKeyLength,
                                payload: outPayloadBuffer.baseAddress!, payloadCapacity: 2_049,
                                payloadLength: &outPayloadLength) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
                        }
                    }
                    precondition(host_zenoh_call_count(3) == pollCalls)

                    // No frame yet: the queue-empty code is reported.
                    outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                        outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                            precondition(client.poll(
                                key: outKeyBuffer.baseAddress!, keyCapacity: UInt32(outKeyBuffer.count),
                                keyLength: &outKeyLength,
                                payload: outPayloadBuffer.baseAddress!, payloadCapacity: UInt32(outPayloadBuffer.count),
                                payloadLength: &outPayloadLength) == AXOLOTY_ZENOH_QUEUE_EMPTY)
                        }
                    }
                    precondition(client.queueDepth() == 0)

                    // A provided frame is copied into caller storage, and a
                    // carrier poll failure is reported without consuming it.
                    sampleKey.withUnsafeBufferPointer { sampleKeyBuffer in
                        samplePayload.withUnsafeBufferPointer { samplePayloadBuffer in
                            host_zenoh_set_sample(
                                sampleKeyBuffer.baseAddress!, Int32(sampleKey.count),
                                samplePayloadBuffer.baseAddress!, Int32(samplePayload.count))
                        }
                    }
                    precondition(client.queueDepth() == 1)
                    host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_POLL))
                    outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                        outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                            precondition(client.poll(
                                key: outKeyBuffer.baseAddress!, keyCapacity: UInt32(outKeyBuffer.count),
                                keyLength: &outKeyLength,
                                payload: outPayloadBuffer.baseAddress!, payloadCapacity: UInt32(outPayloadBuffer.count),
                                payloadLength: &outPayloadLength) == AXOLOTY_ZENOH_TRANSPORT_ERROR)
                        }
                    }
                    host_zenoh_set_failures(0)
                    outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                        outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                            precondition(client.poll(
                                key: outKeyBuffer.baseAddress!, keyCapacity: UInt32(outKeyBuffer.count),
                                keyLength: &outKeyLength,
                                payload: outPayloadBuffer.baseAddress!, payloadCapacity: UInt32(outPayloadBuffer.count),
                                payloadLength: &outPayloadLength) == AXOLOTY_ZENOH_OK)
                            precondition(outKeyLength == UInt32(sampleKey.count))
                            precondition(outPayloadLength == UInt32(samplePayload.count))
                            for index in 0..<sampleKey.count {
                                precondition(outKeyBuffer[index] == sampleKey[index])
                            }
                            for index in 0..<samplePayload.count {
                                precondition(outPayloadBuffer[index] == samplePayload[index])
                            }
                        }
                    }

                    // A too-small output buffer keeps the frame queued.
                    sampleKey.withUnsafeBufferPointer { sampleKeyBuffer in
                        samplePayload.withUnsafeBufferPointer { samplePayloadBuffer in
                            host_zenoh_set_sample(
                                sampleKeyBuffer.baseAddress!, Int32(sampleKey.count),
                                samplePayloadBuffer.baseAddress!, Int32(samplePayload.count))
                        }
                    }
                    outKey.withUnsafeMutableBufferPointer { outKeyBuffer in
                        outPayload.withUnsafeMutableBufferPointer { outPayloadBuffer in
                            precondition(client.poll(
                                key: outKeyBuffer.baseAddress!, keyCapacity: 1, keyLength: &outKeyLength,
                                payload: outPayloadBuffer.baseAddress!, payloadCapacity: UInt32(outPayloadBuffer.count),
                                payloadLength: &outPayloadLength) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
                            precondition(client.queueDepth() == 1)
                            precondition(client.poll(
                                key: outKeyBuffer.baseAddress!, keyCapacity: UInt32(outKeyBuffer.count),
                                keyLength: &outKeyLength,
                                payload: outPayloadBuffer.baseAddress!, payloadCapacity: UInt32(outPayloadBuffer.count),
                                payloadLength: &outPayloadLength) == AXOLOTY_ZENOH_OK)
                        }
                    }

                    // Unsubscribe returns to the open state; publishing is refused.
                    host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_UNSUBSCRIBE))
                    precondition(!client.unsubscribe())
                    host_zenoh_set_failures(0)
                    precondition(client.unsubscribe())
                    precondition(!client.publish(key: keySpan, payload: payloadSpan))
                    precondition(client.subscribe(key: keySpan))

                    // A reported close failure still closes the session, so a
                    // close is terminal whether it reported success or not.
                    host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_CLOSE))
                    precondition(!client.close())
                    host_zenoh_set_failures(0)
                    precondition(!client.close())
                    precondition(!client.open(endpoint: endpointSpan, multicastScouting: false))

                    // The same contract read straight from the facade ABI: a
                    // second close of a closed slot is NOT_OPEN, and the state
                    // of that handle is still readable.
                    var rawSession: OpaquePointer?
                    var rawConfig = axoloty_zenoh_config_t(
                        mode: AXOLOTY_ZENOH_MODE_CLIENT,
                        connect_endpoint: nil,
                        connect_endpoint_length: 0,
                        multicast_scouting_enabled: false)
                    precondition(axoloty_zenoh_open(&rawConfig, &rawSession) == AXOLOTY_ZENOH_OK)
                    let openSession = rawSession!
                    var state = AXOLOTY_ZENOH_SESSION_CLOSED
                    precondition(axoloty_zenoh_state(openSession, &state) == AXOLOTY_ZENOH_OK)
                    precondition(state.rawValue == AXOLOTY_ZENOH_SESSION_OPEN.rawValue)
                    var routers: UInt32 = 99
                    precondition(axoloty_zenoh_connected_router_count(openSession, &routers) == AXOLOTY_ZENOH_OK)
                    precondition(routers == 1)
                    host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_CLOSE))
                    precondition(axoloty_zenoh_close(openSession) == AXOLOTY_ZENOH_TRANSPORT_ERROR)
                    precondition(axoloty_zenoh_close(openSession) == AXOLOTY_ZENOH_NOT_OPEN)
                    precondition(axoloty_zenoh_state(openSession, &state) == AXOLOTY_ZENOH_OK)
                    precondition(state.rawValue == AXOLOTY_ZENOH_SESSION_CLOSED.rawValue)
                    precondition(axoloty_zenoh_connected_router_count(openSession, &routers) == AXOLOTY_ZENOH_NOT_OPEN)
                    precondition(routers == 0)
                    host_zenoh_set_failures(0)

                    // A null or foreign handle is rejected without mutation.
                    precondition(axoloty_zenoh_state(nil, &state) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
                    precondition(axoloty_zenoh_close(nil) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
                    precondition(axoloty_zenoh_publish(
                        OpaquePointer(bitPattern: 0x1234), keyBuffer.baseAddress, UInt32(key.count),
                        payloadBuffer.baseAddress, UInt32(payload.count)) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
                }
            }
        }
    }
}
