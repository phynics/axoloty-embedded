// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host self-test for the embedded Zenoh transport seam.
//
// Proves the production carrier and probe enforce lifecycle order, the
// 256/2048 bounds, and multi-subscription handling; refuse the unsupported
// broker last-will without ever reporting success; observe router
// connectivity within a deadline with honest timeout and closed-session
// behavior; and emit the probe's record sequence. It compiles the real
// carrier and probe sources against the real portable session module and a
// host-only fake carrier; it never compiles or links zenoh-pico.

import CAxolotyZenoh
import ZenohHostTest

private func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

private func staticText(_ value: StaticString) -> String {
    String(decoding: UnsafeBufferPointer(start: value.utf8Start, count: value.utf8CodeUnitCount), as: UTF8.self)
}

private func withSpan<R>(_ bytes: [UInt8], count: Int, _ body: (Span<UInt8>) -> R) -> R {
    bytes.withUnsafeBufferPointer { buffer in
        body(Span(_unsafeStart: buffer.baseAddress!, count: count))
    }
}

private func withTwoSpans<R>(_ first: [UInt8], _ second: [UInt8], _ body: (Span<UInt8>, Span<UInt8>) -> R) -> R {
    first.withUnsafeBufferPointer { firstBuffer in
        second.withUnsafeBufferPointer { secondBuffer in
            body(Span(_unsafeStart: firstBuffer.baseAddress!, count: first.count),
                 Span(_unsafeStart: secondBuffer.baseAddress!, count: second.count))
        }
    }
}

private let probeTopicBytes: [UInt8] = Array("probe/topic".utf8)
private let probePayloadBytes: [UInt8] = Array("probe/payload".utf8)

@main
private struct EmbeddedZenohHostTest {
    static func main() {
        check(host_zenoh_sample_validation_tests() != 0, "sample validation vectors")
        check(host_zenoh_queue_tests() != 0, "bounded receive queue conformance")
        host_zenoh_reset()

        carrierLifecycle()
        partialProfileInterestCleanup()
        carrierBounds()
        carrierPollMapping()
        willIsUnsupported()
        reconnectObservation()
        schedulerTickConversion()
        probeRecords()
        facadeContract()
    }

    // MARK: - Lifecycle

    static func carrierLifecycle() {
        host_zenoh_reset()
        var carrier = ZenohCarrier()
        let key = Array("sample/key".utf8)
        let payload = Array("sample/payload".utf8)

        // Out-of-order operations are rejected before the carrier is entered.
        check(withSpan(key, count: key.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        } == false, "subscribe before connect")
        check(withSpan(key, count: key.count) {
            carrier.unsubscribe(topic: $0, deadlineMS: 1_000)
        } == false, "unsubscribe before connect")
        check(withTwoSpans(key, payload) {
            carrier.publish(topic: $0, payload: $1)
        } == false, "publish before connect")
        check(!carrier.disconnect(), "disconnect while idle")
        check(!carrier.waitForReconnect(deadlineMS: 100), "reconnect while idle")

        // A failed open keeps the carrier idle, so a retry is safe.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_OPEN))
        check(!carrier.connect(deadlineMS: 5_000), "failed open reports failure")
        host_zenoh_set_failures(0)
        check(carrier.connect(deadlineMS: 5_000), "open succeeds")
        check(!carrier.connect(deadlineMS: 5_000), "second open is rejected")

        // The operator endpoint reaches the facade untouched.
        let expectedEndpoint = Array("tcp/127.0.0.1:7447".utf8)
        check(host_zenoh_session_endpoint_length(0) == UInt32(expectedEndpoint.count), "endpoint length recorded")

        // Three profile filters install side by side; a repeat is idempotent.
        let hashFilter = Array("coaty/3/axoloty-embedded/#".utf8)
        let twoLevel = Array("coaty/3/axoloty-embedded/*/*".utf8)
        let threeLevel = Array("coaty/3/axoloty-embedded/*/*/*".utf8)
        check(withSpan(hashFilter, count: hashFilter.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "hash filter")
        check(withSpan(twoLevel, count: twoLevel.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "two-level filter")
        check(withSpan(threeLevel, count: threeLevel.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "three-level filter")
        check(withSpan(hashFilter, count: hashFilter.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "duplicate subscribe")
        check(host_zenoh_call_count(1) == 3, "duplicate subscribe declares nothing")

        // Removal is exact: unknown topics remove nothing.
        let unknown = Array("coaty/3/axoloty-embedded/NOPE".utf8)
        check(withSpan(unknown, count: unknown.count) {
            carrier.unsubscribe(topic: $0, deadlineMS: 1_000)
        } == false, "unknown unsubscribe")
        check(withSpan(twoLevel, count: twoLevel.count) {
            carrier.unsubscribe(topic: $0, deadlineMS: 1_000)
        }, "remove one filter")
        check(withTwoSpans(key, payload) {
            carrier.publish(topic: $0, payload: $1)
        }, "publish while subscribed")
        check(host_zenoh_publish_key_length() == UInt32(key.count), "publish key length")
        check(host_zenoh_publish_payload_length() == UInt32(payload.count), "publish payload length")

        // Teardown is terminal: a reported close failure still closes.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_CLOSE))
        check(!carrier.disconnect(), "failed close reports failure")
        host_zenoh_set_failures(0)
        check(!carrier.disconnect(), "second disconnect is rejected")
        check(!carrier.connect(deadlineMS: 5_000), "reconnect after close is rejected")
        check(!carrier.waitForReconnect(deadlineMS: 100), "reconnect after close is rejected")
    }

    // MARK: - Application partial profile-interest install

    static func partialProfileInterestCleanup() {
        var subscribeCalls = 0
        var unsubscribeCalls: [String] = []
        let subscribe: (UnsafePointer<UInt8>, Int32, UInt32) -> Int32 = { key, length, _ in
            subscribeCalls += 1
            // Fail the second shape after the first declaration succeeded.
            return subscribeCalls == 2 ? 0 : (length > 0 && key.pointee != 0 ? 1 : 0)
        }
        let unsubscribe: (UnsafePointer<UInt8>, Int32, UInt32) -> Int32 = { key, length, _ in
            unsubscribeCalls.append(String(
                decoding: UnsafeBufferPointer(start: key, count: Int(length)), as: UTF8.self
            ))
            return 1
        }
        let installed = installDeviceAgentProfileInterest(
            subscribe: subscribe,
            unsubscribe: unsubscribe,
            deadlineMS: 1_000
        )
        check(!installed, "partial profile-interest install reports failure")
        check(subscribeCalls == 2, "remaining shapes are not declared after failure")
        check(unsubscribeCalls == ["coaty/3/axoloty-embedded/#"], "earlier successful shape is removed")
    }

    // MARK: - Bounds

    static func carrierBounds() {
        host_zenoh_reset()
        var carrier = ZenohCarrier()
        check(carrier.connect(deadlineMS: 5_000), "open for bounds")
        let key = Array("sample/key".utf8)
        let payload = Array("sample/payload".utf8)
        let subscribesBefore = host_zenoh_call_count(1)
        let publishesBefore = host_zenoh_call_count(2)

        let oversizedKey = [UInt8](repeating: 0, count: 257)
        let oversizedPayload = [UInt8](repeating: 0, count: 2_049)
        check(withSpan(oversizedKey, count: oversizedKey.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        } == false, "oversized key subscribe")
        check(oversizedKey.withUnsafeBufferPointer { oversizedBuffer in
            payload.withUnsafeBufferPointer { payloadBuffer in
                carrier.publish(
                    topic: Span(_unsafeStart: oversizedBuffer.baseAddress!, count: oversizedKey.count),
                    payload: Span(_unsafeStart: payloadBuffer.baseAddress!, count: payload.count))
            }
        } == false, "oversized key publish")
        check(key.withUnsafeBufferPointer { keyBuffer in
            oversizedPayload.withUnsafeBufferPointer { oversizedBuffer in
                carrier.publish(
                    topic: Span(_unsafeStart: keyBuffer.baseAddress!, count: key.count),
                    payload: Span(_unsafeStart: oversizedBuffer.baseAddress!, count: oversizedPayload.count))
            }
        } == false, "oversized payload publish")
        check(host_zenoh_call_count(1) == subscribesBefore, "oversized subscribes never enter the carrier")
        check(host_zenoh_call_count(2) == publishesBefore, "oversized publishes never enter the carrier")

        // An empty payload is a legal sample.
        check(withSpan(key, count: key.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "subscribe for empty publish")
        let oneByte = [UInt8](repeating: 0, count: 1)
        check(oneByte.withUnsafeBufferPointer { oneBuffer in
            key.withUnsafeBufferPointer { keyBuffer in
                carrier.publish(
                    topic: Span(_unsafeStart: keyBuffer.baseAddress!, count: key.count),
                    payload: Span(_unsafeStart: oneBuffer.baseAddress!, count: 0))
            }
        }, "empty payload publishes")
        check(host_zenoh_publish_payload_length() == 0, "empty payload length")
        check(carrier.disconnect(), "bounds teardown")
    }

    // MARK: - Poll mapping

    static func carrierPollMapping() {
        host_zenoh_reset()
        var carrier = ZenohCarrier()
        check(carrier.connect(deadlineMS: 5_000), "open for poll")
        let key = Array("sample/key".utf8)
        var outKey = [UInt8](repeating: 0, count: 256)
        var outPayload = [UInt8](repeating: 0, count: 2_048)
        var outKeyLength: Int32 = 0
        var outPayloadLength: Int32 = 0

        func poll() -> Int32 {
            outKey.withUnsafeMutableBufferPointer { keyBuffer in
                outPayload.withUnsafeMutableBufferPointer { payloadBuffer in
                    carrier.pollOneEvent(
                        topic: keyBuffer.baseAddress!, topicCapacity: Int32(keyBuffer.count), topicLength: &outKeyLength,
                        payload: payloadBuffer.baseAddress!, payloadCapacity: Int32(payloadBuffer.count),
                        payloadLength: &outPayloadLength)
                }
            }
        }

        // Wrong states and capacities are rejected before any queue is read.
        check(poll() == -1, "poll before subscribe")
        check(withSpan(key, count: key.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "subscribe for poll")
        let pollsBefore = host_zenoh_call_count(3)
        outKey.withUnsafeMutableBufferPointer { keyBuffer in
            outPayload.withUnsafeMutableBufferPointer { payloadBuffer in
                check(carrier.pollOneEvent(
                    topic: keyBuffer.baseAddress!, topicCapacity: 0, topicLength: &outKeyLength,
                    payload: payloadBuffer.baseAddress!, payloadCapacity: Int32(payloadBuffer.count),
                    payloadLength: &outPayloadLength) == -1, "zero key capacity")
                check(carrier.pollOneEvent(
                    topic: keyBuffer.baseAddress!, topicCapacity: Int32(keyBuffer.count), topicLength: &outKeyLength,
                    payload: payloadBuffer.baseAddress!, payloadCapacity: 2_049,
                    payloadLength: &outPayloadLength) == -1, "oversize payload capacity")
            }
        }
        check(host_zenoh_call_count(3) == pollsBefore, "invalid capacities never enter the carrier")
        check(poll() == 0, "empty queue reports zero")

        // A queued frame copies out with its lengths.
        let sampleKey = Array("inbound/key".utf8)
        let samplePayload = Array("inbound/payload".utf8)
        sampleKey.withUnsafeBufferPointer { keyBuffer in
            samplePayload.withUnsafeBufferPointer { payloadBuffer in
                host_zenoh_set_sample(keyBuffer.baseAddress!, Int32(sampleKey.count),
                                      payloadBuffer.baseAddress!, Int32(samplePayload.count))
            }
        }
        check(poll() == 1, "queued frame reports one")
        check(outKeyLength == Int32(sampleKey.count), "frame key length")
        check(outPayloadLength == Int32(samplePayload.count), "frame payload length")
        for index in 0..<sampleKey.count { check(outKey[index] == sampleKey[index], "frame key byte") }
        for index in 0..<samplePayload.count { check(outPayload[index] == samplePayload[index], "frame payload byte") }

        // A frame that does not fit caller storage is retained, not lost.
        sampleKey.withUnsafeBufferPointer { keyBuffer in
            samplePayload.withUnsafeBufferPointer { payloadBuffer in
                host_zenoh_set_sample(keyBuffer.baseAddress!, Int32(sampleKey.count),
                                      payloadBuffer.baseAddress!, Int32(samplePayload.count))
            }
        }
        outKey.withUnsafeMutableBufferPointer { keyBuffer in
            outPayload.withUnsafeMutableBufferPointer { payloadBuffer in
                check(carrier.pollOneEvent(
                    topic: keyBuffer.baseAddress!, topicCapacity: 1, topicLength: &outKeyLength,
                    payload: payloadBuffer.baseAddress!, payloadCapacity: Int32(payloadBuffer.count),
                    payloadLength: &outPayloadLength) == -1, "small storage retains the frame")
            }
        }
        check(poll() == 1, "retained frame is served next")
        check(outKeyLength == Int32(sampleKey.count), "retained frame key length")

        // A carrier poll failure surfaces as an error without closing.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_POLL))
        sampleKey.withUnsafeBufferPointer { keyBuffer in
            samplePayload.withUnsafeBufferPointer { payloadBuffer in
                host_zenoh_set_sample(keyBuffer.baseAddress!, Int32(sampleKey.count),
                                      payloadBuffer.baseAddress!, Int32(samplePayload.count))
            }
        }
        check(poll() == -1, "carrier poll failure")
        host_zenoh_set_failures(0)
        check(carrier.disconnect(), "poll teardown")
        check(poll() == -2, "poll after close reports closed")
    }

    // MARK: - Unsupported last-will

    static func willIsUnsupported() {
        host_zenoh_reset()
        var carrier = ZenohCarrier()
        let topic = Array("axoloty/network/will".utf8)
        let payload = Array("axoloty-network-offline".utf8)
        // Refused while idle and while connected: the operation does not
        // exist in this profile, so success is never reported.
        check(withTwoSpans(topic, payload) {
            carrier.configureLastWill(topic: $0, payload: $1)
        } == false, "will refused while idle")
        check(carrier.connect(deadlineMS: 5_000), "open for will")
        check(withTwoSpans(topic, payload) {
            carrier.configureLastWill(topic: $0, payload: $1)
        } == false, "will refused while connected")
        check(embeddedExchangeConfigureLastWill(
            topic.withUnsafeBufferPointer { $0.baseAddress! }, Int32(topic.count),
            payload.withUnsafeBufferPointer { $0.baseAddress! }, Int32(payload.count)) == 0,
            "adapter will reports failure")
        check(carrier.disconnect(), "will teardown")
    }

    // MARK: - Router observation

    static func reconnectObservation() {
        host_zenoh_reset()
        var carrier = ZenohCarrier()
        check(!carrier.waitForReconnect(deadlineMS: 100), "reconnect while idle")
        check(carrier.connect(deadlineMS: 5_000), "open for reconnect")
        check(!carrier.waitForReconnect(deadlineMS: 100), "reconnect before subscribe")
        let key = Array("sample/key".utf8)
        check(withSpan(key, count: key.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "subscribe for reconnect")

        // A currently usable session succeeds immediately. This is only the
        // connectivity-wait contract; recovery evidence is a separate concern.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_ROUTER_DROP_AFTER_ONE))
        let startUS = host_zenoh_fake_time_us()
        check(carrier.waitForReconnect(deadlineMS: 200), "already-usable router succeeds")
        check(host_zenoh_fake_time_us() == startUS, "usable router does not wait")

        // An observed loss followed by restoration satisfies recovery.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_ROUTER_DROP_THEN_RESTORE))
        check(carrier.waitForReconnect(deadlineMS: 500), "observed loss and restoration succeeds")

        // If loss/restoration finished before the wait starts, a usable router
        // still satisfies the connectivity contract at entry.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_ROUTER_DROP_RESTORE_BEFORE_ENTRY))
        let restoredBeforeEntryUS = host_zenoh_fake_time_us()
        check(carrier.waitForReconnect(deadlineMS: 500), "restored router before entry succeeds")
        check(host_zenoh_fake_time_us() == restoredBeforeEntryUS, "already-restored router returns immediately")

        // No router within the deadline is an honest timeout, bounded by it.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_ROUTERS))
        let timeoutStartUS = host_zenoh_fake_time_us()
        check(!carrier.waitForReconnect(deadlineMS: 200), "absent router times out")
        let waitedUS = host_zenoh_fake_time_us() - timeoutStartUS
        check(waitedUS >= 200_000 && waitedUS < 500_000, "wait is bounded by the deadline")
        // A zero deadline still observes once without waiting.
        check(!carrier.waitForReconnect(deadlineMS: 0), "zero deadline with no router")
        check(host_zenoh_fake_time_us() == timeoutStartUS + waitedUS, "zero deadline never waits")
        host_zenoh_set_failures(0)
        check(carrier.waitForReconnect(deadlineMS: 0), "zero deadline with a router")

        // A closed session fails fast: it cannot recover without a reopen,
        // which this operation never performs behind the caller.
        check(carrier.disconnect(), "reconnect teardown")
        let closedStartUS = host_zenoh_fake_time_us()
        check(!carrier.waitForReconnect(deadlineMS: 5_000), "closed session fails fast")
        check(host_zenoh_fake_time_us() == closedStartUS, "closed session never waits out a deadline")
    }

    // MARK: - Scheduler tick conversion

    static func schedulerTickConversion() {
        host_zenoh_set_scheduler_hz(100)
        check(zenohPollingWaitTicks(milliseconds: 0, schedulerHz: 100) == 0, "zero wait maps to zero ticks")
        check(zenohPollingWaitTicks(milliseconds: 1, schedulerHz: 100) == 1, "sub-tick wait rounds up")
        check(zenohPollingWaitTicks(milliseconds: 10, schedulerHz: 100) == 1, "one tick duration maps to one")
        check(zenohPollingWaitTicks(milliseconds: 11, schedulerHz: 100) == 2, "fractional tick rounds up")

        host_zenoh_reset()
        host_zenoh_set_scheduler_hz(100)
        var carrier = ZenohCarrier()
        check(carrier.connect(deadlineMS: 5_000), "open at 100 Hz")
        let key = Array("sample/key".utf8)
        check(withSpan(key, count: key.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "subscribe at 100 Hz")

        // A 21 ms deadline with a 20 ms polling ceiling first waits 20 ms.
        // The final one-millisecond remainder rounds to one 10 ms tick, so
        // fake time reaches 30 ms rather than busy-spinning or timing out early.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_ROUTERS))
        let start = host_zenoh_fake_time_us()
        check(!carrier.waitForReconnect(deadlineMS: 21), "short remainder times out")
        let elapsed = host_zenoh_fake_time_us() - start
        check(elapsed == 30_000, "20 ms poll plus one rounded 100 Hz tick reaches 30 ms")
        host_zenoh_set_failures(0)
        check(carrier.disconnect(), "100 Hz teardown")
        host_zenoh_reset()
    }

    // MARK: - Probe records

    static func probeRecords() {
        host_zenoh_reset()
        let prepare: @convention(c) (UInt32) -> UInt32 = { _ in 3 }
        let reconnect: @convention(c) (UInt32) -> UInt32 = { _ in 3 }
        let copyTopic: @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32 = { buffer, capacity in
            guard capacity >= Int32(probeTopicBytes.count) else { return 0 }
            for index in probeTopicBytes.indices { buffer[index] = probeTopicBytes[index] }
            return Int32(probeTopicBytes.count)
        }
        let copyPayload: @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32 = { buffer, capacity in
            guard capacity >= Int32(probePayloadBytes.count) else { return 0 }
            for index in probePayloadBytes.indices { buffer[index] = probePayloadBytes[index] }
            return Int32(probePayloadBytes.count)
        }
        let cleanup: @convention(c) () -> UInt32 = { 1 }

        var records: [(String, String)] = []
        runCarrierNetworkProbe(
            networkPrepare: prepare, networkReconnect: reconnect,
            networkCopyTopic: copyTopic, networkCopyPayload: copyPayload,
            networkCleanup: cleanup,
            record: { id, ok in records.append((staticText(id), ok ? "passed" : "failed")) },
            recordUnsupported: { id in records.append((staticText(id), "unsupported")) }
        )
        let expected: [(String, String)] = [
            ("network:wifi", "passed"), ("network:ip", "passed"),
            ("network:rejectOutOfOrder", "passed"), ("network:lastWillUnsupported", "unsupported"),
            ("network:zenohConnect", "passed"), ("network:subscribe", "passed"),
            // The probe records usable current connectivity. This does not
            // establish the loss/restoration evidence required by device
            // qualification.
            ("network:reconnect", "passed"), ("network:rejectOversize", "passed"),
            ("network:publish", "passed"), ("network:receiveUnsupported", "unsupported"),
            ("network:disconnect", "passed"),
        ]
        check(records.count == expected.count, "probe emits every step once")
        for (index, step) in expected.enumerated() {
            check(records[index].0 == step.0, "probe step order: \(step.0)")
            check(records[index].1 == step.1, "probe step status: \(step.0)")
        }

        // Without a network every reachable step reports failure, and the
        // unsupported capabilities report that their stage was not reached.
        host_zenoh_reset()
        let offlinePrepare: @convention(c) (UInt32) -> UInt32 = { _ in 0 }
        var offline: [(String, String)] = []
        runCarrierNetworkProbe(
            networkPrepare: offlinePrepare, networkReconnect: reconnect,
            networkCopyTopic: copyTopic, networkCopyPayload: copyPayload,
            networkCleanup: cleanup,
            record: { id, ok in offline.append((staticText(id), ok ? "passed" : "failed")) },
            recordUnsupported: { id in offline.append((staticText(id), "unsupported")) }
        )
        let expectedOffline: [(String, String)] = [
            ("network:wifi", "failed"), ("network:ip", "failed"),
            ("network:zenohConnect", "failed"), ("network:lastWillUnsupported", "unsupported"),
            ("network:subscribe", "failed"), ("network:reconnect", "failed"),
            ("network:rejectOutOfOrder", "failed"), ("network:rejectOversize", "failed"),
            ("network:publish", "failed"), ("network:receiveUnsupported", "unsupported"),
            ("network:disconnect", "passed"),
        ]
        check(offline.count == expectedOffline.count, "offline probe emits every step once")
        for (index, step) in expectedOffline.enumerated() {
            check(offline[index].0 == step.0, "offline probe step order: \(step.0)")
            check(offline[index].1 == step.1, "offline probe step status: \(step.0)")
        }

    }

    // MARK: - Facade contract

    static func facadeContract() {
        host_zenoh_reset()
        let key = Array("sample/key".utf8)
        let payload = Array("sample/payload".utf8)

        // The same contract read straight from the facade ABI: a second close
        // of a closed slot is NOT_OPEN, and the state of that handle is still
        // readable.
        var rawSession: OpaquePointer?
        var rawConfig = axoloty_zenoh_config_t(
            mode: AXOLOTY_ZENOH_MODE_CLIENT,
            connect_endpoint: nil,
            connect_endpoint_length: 0,
            multicast_scouting_enabled: false)
        check(axoloty_zenoh_open(&rawConfig, &rawSession) == AXOLOTY_ZENOH_OK, "raw open")
        let openSession = rawSession!
        var state = AXOLOTY_ZENOH_SESSION_CLOSED
        check(axoloty_zenoh_state(openSession, &state) == AXOLOTY_ZENOH_OK, "raw state")
        check(state.rawValue == AXOLOTY_ZENOH_SESSION_OPEN.rawValue, "raw session is open")
        var routers: UInt32 = 99
        check(axoloty_zenoh_connected_router_count(openSession, &routers) == AXOLOTY_ZENOH_OK, "raw router count")
        check(routers == 1, "one router observed")
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_CLOSE))
        check(axoloty_zenoh_close(openSession) == AXOLOTY_ZENOH_TRANSPORT_ERROR, "close failure is reported")
        check(axoloty_zenoh_close(openSession) == AXOLOTY_ZENOH_NOT_OPEN, "second close is NOT_OPEN")
        check(axoloty_zenoh_state(openSession, &state) == AXOLOTY_ZENOH_OK, "closed state is readable")
        check(state.rawValue == AXOLOTY_ZENOH_SESSION_CLOSED.rawValue, "raw session is closed")
        check(axoloty_zenoh_connected_router_count(openSession, &routers) == AXOLOTY_ZENOH_NOT_OPEN, "routers unreadable when closed")
        check(routers == 0, "router count cleared")
        host_zenoh_set_failures(0)

        // A null or foreign handle is rejected without mutation.
        key.withUnsafeBufferPointer { keyBuffer in
            payload.withUnsafeBufferPointer { payloadBuffer in
                check(axoloty_zenoh_state(nil, &state) == AXOLOTY_ZENOH_INVALID_ARGUMENT, "null state")
                check(axoloty_zenoh_close(nil) == AXOLOTY_ZENOH_INVALID_ARGUMENT, "null close")
                check(axoloty_zenoh_publish(
                    OpaquePointer(bitPattern: 0x1234), keyBuffer.baseAddress, UInt32(key.count),
                    payloadBuffer.baseAddress, UInt32(payload.count)) == AXOLOTY_ZENOH_INVALID_ARGUMENT,
                    "foreign publish")
            }
        }
    }
}
