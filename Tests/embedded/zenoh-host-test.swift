// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host self-test for the embedded Zenoh transport seam.
//
// Proves the production carrier and probe enforce lifecycle order, the
// composed key and payload bounds (the selected application's declared
// capacities, `EmbeddedCarrierBounds`), and multi-subscription handling; refuse the unsupported
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
        check(host_carrier_diagnostics_tests() != 0, "carrier diagnostics conformance")
        host_zenoh_reset()

        carrierLifecycle()
        keyExpressionGrammar()
        partialProfileInterestCleanup()
        willCapabilityScenarioGate()
        carrierBounds()
        carrierPollMapping()
        carrierComposedBounds()
        willIsUnsupported()
        reconnectObservation()
        idleKeepAlive()
        schedulerTickConversion()
        carrierDiagnostics()
        probeRecords()
        facadeContract()
        carrierABIQuery()
    }

    // MARK: - Production carrier ABI table

    static func carrierABIQuery() {
        guard let table = axoloty_carrier_get_v1() else { preconditionFailure("Zenoh carrier table missing") }
        check(axoloty_carrier_v1_validate_requirements(table, 1, 1) != 0,
              "Zenoh table supplies the last-will query function")
        var supported: UInt32 = 99
        check(table.pointee.supports_last_will!(table.pointee.context, &supported) == AXOLOTY_ABI_STATUS_OK,
              "Zenoh last-will support query succeeds")
        check(supported == 0, "Zenoh reports last-will unsupported")
        let topic: [UInt8] = Array("topic".utf8)
        let payload: [UInt8] = Array("payload".utf8)
        let configured = topic.withUnsafeBufferPointer { topicBuffer in
            payload.withUnsafeBufferPointer { payloadBuffer in
                table.pointee.configure_last_will!(table.pointee.context, topicBuffer.baseAddress,
                    UInt32(topic.count), payloadBuffer.baseAddress, UInt32(payload.count))
            }
        }
        check(configured == AXOLOTY_ABI_STATUS_FAILED, "Zenoh last-will configuration remains unavailable")
        var topicBytes = [UInt8](repeating: 0, count: 32)
        var payloadBytes = [UInt8](repeating: 0, count: 32)
        var topicLength: UInt32 = 0
        var payloadLength: UInt32 = 0
        let topicStatus = topicBytes.withUnsafeMutableBufferPointer { buffer in
            table.pointee.copy_probe_topic!(table.pointee.context, buffer.baseAddress,
                                             UInt32(buffer.count), &topicLength)
        }
        let payloadStatus = payloadBytes.withUnsafeMutableBufferPointer { buffer in
            table.pointee.copy_probe_payload!(table.pointee.context, buffer.baseAddress,
                                               UInt32(buffer.count), &payloadLength)
        }
        check(topicStatus == AXOLOTY_ABI_STATUS_OK && topicLength == 21,
              "Zenoh ABI probe copies configured deterministic topic")
        check(payloadStatus == AXOLOTY_ABI_STATUS_OK && payloadLength == 19,
              "Zenoh ABI probe copies configured deterministic payload")
        check(String(decoding: topicBytes.prefix(Int(topicLength)), as: UTF8.self) == "axoloty/network/probe",
              "Zenoh ABI topic bytes match network configuration")
        check(String(decoding: payloadBytes.prefix(Int(payloadLength)), as: UTF8.self) == "axoloty-zenoh-probe",
              "Zenoh ABI payload bytes match network configuration")

        host_zenoh_reset()
        check(table.pointee.connect!(table.pointee.context, 5_000) == AXOLOTY_ABI_STATUS_OK,
              "Zenoh ABI connect callback opens the production carrier")
        let exchangeKey = Array("abi/topic".utf8)
        let exchangePayload = Array("abi-payload".utf8)
        let subscribed = exchangeKey.withUnsafeBufferPointer { key in
            table.pointee.subscribe!(table.pointee.context, key.baseAddress, UInt32(key.count), 1_000)
        }
        check(subscribed == AXOLOTY_ABI_STATUS_OK, "Zenoh ABI subscribe callback succeeds")
        let published = exchangeKey.withUnsafeBufferPointer { key in
            exchangePayload.withUnsafeBufferPointer { payload in
                table.pointee.publish!(table.pointee.context, key.baseAddress, UInt32(key.count),
                    payload.baseAddress, UInt32(payload.count))
            }
        }
        check(published == AXOLOTY_ABI_STATUS_OK, "Zenoh ABI publish callback succeeds")
        check(table.pointee.wait_for_reconnect!(table.pointee.context, 1_000) == AXOLOTY_ABI_STATUS_OK,
              "Zenoh ABI reconnect callback observes configured router")
        var outTopic = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxTopicLength)
        var outPayload = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxPayloadSize)
        var outTopicLength: UInt32 = 0
        var outPayloadLength: UInt32 = 0
        let emptyPoll = outTopic.withUnsafeMutableBufferPointer { topic in
            outPayload.withUnsafeMutableBufferPointer { payload in
                table.pointee.poll_one_event!(table.pointee.context, topic.baseAddress, UInt32(topic.count),
                    &outTopicLength, payload.baseAddress, UInt32(payload.count), &outPayloadLength)
            }
        }
        check(emptyPoll == AXOLOTY_ABI_STATUS_NO_EVENT, "Zenoh ABI poll maps an empty queue")
        exchangeKey.withUnsafeBufferPointer { key in
            exchangePayload.withUnsafeBufferPointer { payload in
                host_zenoh_set_sample(key.baseAddress, Int32(key.count), payload.baseAddress, Int32(payload.count))
            }
        }
        let receivedBeforeSmallBuffer = ZenohCarrier.diagnostics.frames_received
        var smallTopic = [UInt8](repeating: 0, count: exchangeKey.count - 1)
        var smallPayload = [UInt8](repeating: 0, count: exchangePayload.count)
        var smallTopicLength: UInt32 = 77
        var smallPayloadLength: UInt32 = 88
        let tooSmall = smallTopic.withUnsafeMutableBufferPointer { topic in
            smallPayload.withUnsafeMutableBufferPointer { payload in
                table.pointee.poll_one_event!(table.pointee.context, topic.baseAddress,
                    UInt32(topic.count), &smallTopicLength, payload.baseAddress,
                    UInt32(payload.count), &smallPayloadLength)
            }
        }
        check(tooSmall == AXOLOTY_ABI_STATUS_BUFFER_TOO_SMALL,
              "Zenoh ABI poll distinguishes retained-frame capacity pressure")
        check(smallTopicLength == 77 && smallPayloadLength == 88,
              "Zenoh ABI small-buffer poll leaves output lengths untouched")
        check(ZenohCarrier.diagnostics.frames_received == receivedBeforeSmallBuffer,
              "Zenoh ABI small-buffer poll does not count a retained frame as received")
        let framePoll = outTopic.withUnsafeMutableBufferPointer { topic in
            outPayload.withUnsafeMutableBufferPointer { payload in
                table.pointee.poll_one_event!(table.pointee.context, topic.baseAddress, UInt32(topic.count),
                    &outTopicLength, payload.baseAddress, UInt32(payload.count), &outPayloadLength)
            }
        }
        check(framePoll == AXOLOTY_ABI_STATUS_OK && outTopicLength == UInt32(exchangeKey.count) &&
              outPayloadLength == UInt32(exchangePayload.count), "Zenoh ABI poll copies configured frame")
        check(Array(outTopic.prefix(Int(outTopicLength))) == exchangeKey &&
              Array(outPayload.prefix(Int(outPayloadLength))) == exchangePayload,
              "Zenoh ABI retry copies the exact retained frame bytes")
        check(ZenohCarrier.diagnostics.frames_received == receivedBeforeSmallBuffer + 1,
              "Zenoh ABI retained-frame retry counts exactly one received frame")
        let afterRetry = outTopic.withUnsafeMutableBufferPointer { topic in
            outPayload.withUnsafeMutableBufferPointer { payload in
                table.pointee.poll_one_event!(table.pointee.context, topic.baseAddress, UInt32(topic.count),
                    &outTopicLength, payload.baseAddress, UInt32(payload.count), &outPayloadLength)
            }
        }
        check(afterRetry == AXOLOTY_ABI_STATUS_NO_EVENT &&
              ZenohCarrier.diagnostics.frames_received == receivedBeforeSmallBuffer + 1,
              "Zenoh ABI retry consumes the pending frame once")
        let unsubscribed = exchangeKey.withUnsafeBufferPointer { key in
            table.pointee.unsubscribe!(table.pointee.context, key.baseAddress, UInt32(key.count), 1_000)
        }
        check(unsubscribed == AXOLOTY_ABI_STATUS_OK, "Zenoh ABI unsubscribe callback succeeds")
        check(table.pointee.disconnect!(table.pointee.context) == AXOLOTY_ABI_STATUS_OK,
              "Zenoh ABI disconnect callback succeeds")
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

        // The two key shapes the host binding installs go in side by side; a
        // repeat is idempotent. The hash-shaped filter is not a Zenoh key
        // expression: the router panics on it, so the carrier refuses it before
        // anything reaches the facade.
        let hashFilter = Array("axoloty/1/axoloty-embedded/#".utf8)
        let twoLevel = Array("axoloty/1/axoloty-embedded/*/*".utf8)
        let threeLevel = Array("axoloty/1/axoloty-embedded/*/*/*".utf8)
        check(withSpan(hashFilter, count: hashFilter.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        } == false, "hash filter is refused")
        check(host_zenoh_call_count(1) == 0, "refused hash filter declares nothing")
        check(withSpan(twoLevel, count: twoLevel.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "two-level filter")
        check(withSpan(threeLevel, count: threeLevel.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "three-level filter")
        check(withSpan(twoLevel, count: twoLevel.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "duplicate subscribe")
        check(host_zenoh_call_count(1) == 2, "duplicate subscribe declares nothing")

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

        // A reported close failure still closes. Closed is not a dead end: the
        // carrier takes a new session, so a node that lost its router recovers.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_CLOSE))
        check(!carrier.disconnect(), "failed close reports failure")
        host_zenoh_set_failures(0)
        check(!carrier.disconnect(), "second disconnect is rejected")
        check(!carrier.waitForReconnect(deadlineMS: 100), "waiting for a reconnect on a closed carrier is rejected")
        check(carrier.connect(deadlineMS: 5_000), "a closed carrier opens a new session")
        check(!carrier.waitForReconnect(deadlineMS: 100), "a connected carrier without subscriptions has nothing to wait for")
        check(carrier.disconnect(), "the new session closes")
    }

    // MARK: - Key-expression grammar

    /// Keys the router cannot parse are refused on the device. `zenohd` 1.10.0
    /// panics and exits on a declaration containing `#`, so this is the only
    /// place the mistake can be caught before it takes the router down.
    static func keyExpressionGrammar() {
        func subscription(_ key: String) -> Bool {
            Array(key.utf8).withUnsafeBytes { ZenohKeyExpression.isValidSubscription($0) }
        }
        func publication(_ key: String) -> Bool {
            Array(key.utf8).withUnsafeBytes { ZenohKeyExpression.isValidPublication($0) }
        }
        for key in [
            "axoloty/1/ns/ADV/source", "axoloty/1/axoloty-embedded/*/*", "a/**", "a/*/b",
            "a/b$*", "a/$*b", "a/b$*c", "**", "*",
        ] {
            check(subscription(key), "valid subscription \(key)")
        }
        for key in [
            "", "/", "a/", "/a", "a//b", "a/#", "#", "a/b#", "a/?", "a?b", "a*b", "a/**b",
            "a/b**", "a/$", "a/$x", "a/b$*$*", "a/***",
        ] {
            check(!subscription(key), "invalid subscription \(key)")
        }
        for key in ["axoloty/1/ns/ADV/source", "a/b", "a"] {
            check(publication(key), "valid publication \(key)")
        }
        for key in ["a/*", "a/**", "a/b$*", "a/#", "a//b", ""] {
            check(!publication(key), "invalid publication \(key)")
        }
    }

    // MARK: - Application partial profile-interest install

    static func partialProfileInterestCleanup() {
        var subscribeCalls = 0
        var unsubscribeCalls: [String] = []
        var disconnectCalls = 0
        var deadlineMS: UInt32 = 1_000
        var observedSubscribeDeadlines: [UInt32] = []
        var observedUnsubscribeDeadlines: [UInt32] = []
        let subscribe: (UnsafePointer<UInt8>, Int32, UInt32) -> Int32 = { key, length, remaining in
            subscribeCalls += 1
            observedSubscribeDeadlines.append(remaining)
            if subscribeCalls == 1 { deadlineMS = 250 }
            // Fail the second shape after the first declaration succeeded.
            return subscribeCalls == 2 ? 0 : (length > 0 && key.pointee != 0 ? 1 : 0)
        }
        let unsubscribe: (UnsafePointer<UInt8>, Int32, UInt32) -> Int32 = { key, length, remaining in
            observedUnsubscribeDeadlines.append(remaining)
            unsubscribeCalls.append(String(
                decoding: UnsafeBufferPointer(start: key, count: Int(length)), as: UTF8.self
            ))
            return 1
        }
        let disconnect: () -> Int32 = {
            disconnectCalls += 1
            return 1
        }
        let outcome = installDeviceAgentProfileInterest(
            subscribe: subscribe,
            unsubscribe: unsubscribe,
            disconnect: disconnect,
            remainingMS: { deadlineMS }
        )
        check(!outcome.installed, "partial profile-interest install reports failure")
        check(outcome.disconnected, "partial profile-interest install closes the carrier session")
        check(subscribeCalls == 2, "remaining shapes are not declared after failure")
        check(observedSubscribeDeadlines == [1_000, 250], "each sequential subscribe receives current remaining budget")
        check(unsubscribeCalls == ["coaty/3/axoloty-embedded/#"], "earlier successful shape is removed")
        check(observedUnsubscribeDeadlines == [250], "cleanup receives recomputed remaining budget")
        check(disconnectCalls == 1, "carrier disconnect runs once during partial cleanup")
    }

    static func willCapabilityScenarioGate() {
        check(agentMayConnectAfterWillSetup(
            isRoleA: true, scenarioNeedsWill: false, carrierSupportsWill: false,
            willConfigurationSucceeded: false
        ), "unsupported will does not block ordinary role-A exchange")
        check(agentMayConnectAfterWillSetup(
            isRoleA: true, scenarioNeedsWill: false, carrierSupportsWill: false,
            willConfigurationSucceeded: false
        ), "unsupported will does not block broker restart")
        check(!agentMayConnectAfterWillSetup(
            isRoleA: true, scenarioNeedsWill: true, carrierSupportsWill: false,
            willConfigurationSucceeded: false
        ), "will-dependent scenario is not run without will capability")
        check(!agentMayConnectAfterWillSetup(
            isRoleA: true, scenarioNeedsWill: false, carrierSupportsWill: true,
            willConfigurationSucceeded: false
        ), "a supported but failed will configuration still blocks connection")
        check(agentMayConnectAfterWillSetup(
            isRoleA: false, scenarioNeedsWill: true, carrierSupportsWill: false,
            willConfigurationSucceeded: false
        ), "observer role does not configure will")
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

        let oversizedKey = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxTopicLength + 1)
        let oversizedPayload = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxPayloadSize + 1)
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

    // MARK: - Composed bounds

    /// A key and payload exactly at the composed bounds cross the carrier in
    /// both directions, and a frame the facade holds but the caller's buffers
    /// cannot take never blocks the loop for good: the application ends its
    /// session, the carrier discards the retained frame on disconnect, and the
    /// next session receives.
    static func carrierComposedBounds() {
        host_zenoh_reset()
        ZenohCarrier.resetDiagnostics()
        var carrier = ZenohCarrier()
        check(carrier.connect(deadlineMS: 5_000), "open for the composed bounds")
        let boundKey = [UInt8](repeating: 0x6B, count: EmbeddedCarrierBounds.maxTopicLength)
        let boundPayload = [UInt8](repeating: 0x70, count: EmbeddedCarrierBounds.maxPayloadSize)
        var outKey = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxTopicLength)
        var outPayload = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxPayloadSize)
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

        func deliver(key: [UInt8], payload: [UInt8]) {
            key.withUnsafeBufferPointer { keyBuffer in
                payload.withUnsafeBufferPointer { payloadBuffer in
                    host_zenoh_set_sample(keyBuffer.baseAddress!, Int32(key.count),
                                          payloadBuffer.baseAddress!, Int32(payload.count))
                }
            }
        }

        // The carrier subscribes and publishes at the bounds.
        check(withSpan(boundKey, count: boundKey.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "subscribe at the key bound")
        check(withTwoSpans(boundKey, boundPayload) { carrier.publish(topic: $0, payload: $1) },
              "publish at the bounds")
        check(host_zenoh_publish_key_length() == UInt32(boundKey.count), "published key length at the bound")
        check(host_zenoh_publish_payload_length() == UInt32(boundPayload.count), "published payload length at the bound")

        // A frame at the bounds arrives whole through buffers of exactly the bounds.
        deliver(key: boundKey, payload: boundPayload)
        check(poll() == 1, "a frame at the bounds is received")
        check(outKeyLength == Int32(boundKey.count) && outPayloadLength == Int32(boundPayload.count),
              "frame lengths at the bounds")
        check(outKey == boundKey && outPayload == boundPayload, "frame bytes at the bounds")
        check(poll() == 0, "nothing is left queued behind it")

        // The facade may hold a frame the composed bounds do not admit (the
        // carrier's own queue never does; this fake stands for a facade that
        // does). The caller's buffers are the bounds, so it cannot be copied
        // out: it is retained, reported, and blocks until the session ends.
        if EmbeddedCarrierBounds.maxPayloadSize < Int(AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES) {
            let tooLarge = [UInt8](repeating: 0x71, count: EmbeddedCarrierBounds.maxPayloadSize + 1)
            deliver(key: boundKey, payload: tooLarge)
            check(poll() == -1, "a frame beyond the caller's buffers is reported")
            check(poll() == -1, "and stays pending: a retry cannot take it either")
            check(ZenohCarrier.diagnostics.frames_received == 1, "a pending frame is not counted as received")
            // The application ends its session on this error. Disconnect drops
            // the pending frame and the new session starts clean.
            check(carrier.disconnect(), "disconnect discards the pending frame")
            check(poll() == -2, "poll after disconnect reports closed")
            check(carrier.connect(deadlineMS: 5_000), "a new session opens")
            check(withSpan(boundKey, count: boundKey.count) {
                carrier.subscribe(topic: $0, deadlineMS: 1_000)
            }, "the new session subscribes")
            deliver(key: boundKey, payload: boundPayload)
            check(poll() == 1, "the new session receives a frame at the bounds")
            check(outPayload == boundPayload, "and its bytes are intact")
            check(ZenohCarrier.diagnostics.frames_received == 2, "only complete frames count as received")
        }
        check(carrier.disconnect(), "teardown after the composed bounds")
    }

    // MARK: - Poll mapping

    static func carrierPollMapping() {
        host_zenoh_reset()
        var carrier = ZenohCarrier()
        check(carrier.connect(deadlineMS: 5_000), "open for poll")
        let key = Array("sample/key".utf8)
        var outKey = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxTopicLength)
        var outPayload = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxPayloadSize)
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
                    payload: payloadBuffer.baseAddress!, payloadCapacity: Int32(EmbeddedCarrierBounds.maxPayloadSize + 1),
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

    // MARK: - Idle keep-alive

    /// A polled session that stays silent sends a keep-alive itself, because the
    /// router closes one that is quiet for a full lease (#56). Time moves only
    /// through vTaskDelay, so the interval is exact.
    static func idleKeepAlive() {
        host_zenoh_reset()
        var carrier = ZenohCarrier()
        check(carrier.connect(deadlineMS: 5_000), "open for keep-alive")
        let key = Array("sample/key".utf8)
        check(withSpan(key, count: key.count) {
            carrier.subscribe(topic: $0, deadlineMS: 1_000)
        }, "subscribe for keep-alive")
        var outKey = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxTopicLength)
        var outPayload = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxPayloadSize)
        var keyLength: Int32 = 0
        var payloadLength: Int32 = 0
        func poll() {
            _ = outKey.withUnsafeMutableBufferPointer { keyBuffer in
                outPayload.withUnsafeMutableBufferPointer { payloadBuffer in
                    carrier.pollOneEvent(
                        topic: keyBuffer.baseAddress!, topicCapacity: Int32(keyBuffer.count), topicLength: &keyLength,
                        payload: payloadBuffer.baseAddress!, payloadCapacity: Int32(payloadBuffer.count),
                        payloadLength: &payloadLength)
                }
            }
        }
        vTaskDelay(10_000)
        let before = host_zenoh_router_total_queries()
        poll()
        check(host_zenoh_router_total_queries() == before + 1, "a silent session is kept alive")
        poll()
        check(host_zenoh_router_total_queries() == before + 1, "a second poll does not repeat it")
        vTaskDelay(UInt32(ZenohCarrier.keepAliveIntervalMS) - 1)
        poll()
        check(host_zenoh_router_total_queries() == before + 1, "nothing is sent before the interval")
        vTaskDelay(1)
        poll()
        check(host_zenoh_router_total_queries() == before + 2, "the next keep-alive follows the interval")
        check(carrier.disconnect(), "keep-alive teardown")
    }

    // MARK: - Scheduler tick conversion

    static func schedulerTickConversion() {
        host_zenoh_set_scheduler_hz(100)
        check(zenohPollingWaitTicks(milliseconds: 0, schedulerHz: 100) == 0, "zero wait maps to zero ticks")
        check(zenohPollingWaitTicks(milliseconds: 1, schedulerHz: 100) == 1, "sub-tick wait rounds up")
        check(zenohPollingWaitTicks(milliseconds: 10, schedulerHz: 100) == 1, "one tick duration maps to one")
        check(zenohPollingWaitTicks(milliseconds: 11, schedulerHz: 100) == 2, "fractional tick rounds up")
        check(zenohPollingWaitTicks(milliseconds: .max, schedulerHz: .max) == .max,
              "conversion saturates without overflow at maximum inputs")

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

        // A router that becomes available only after the deadline must not
        // turn the following iteration into a false success. The wait checks
        // the deadline before issuing another router query.
        host_zenoh_reset()
        host_zenoh_set_scheduler_hz(100)
        var appearsLate = ZenohCarrier()
        check(appearsLate.connect(deadlineMS: 5_000), "open for late-available router")
        check(withSpan(key, count: key.count) {
            appearsLate.subscribe(topic: $0, deadlineMS: 1_000)
        }, "subscribe for late-available router")
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_ROUTER_APPEARS_AFTER_DEADLINE))
        check(!appearsLate.waitForReconnect(deadlineMS: 21), "router appearing after expiry is not accepted")
        check(host_zenoh_fake_time_us() == 30_000, "late availability is beyond rounded deadline")
        check(host_zenoh_router_query_count() == 3, "late router is not sampled after expiry")
        host_zenoh_set_failures(0)
        check(appearsLate.disconnect(), "late-available router teardown")
        host_zenoh_reset()
    }

    // MARK: - Carrier diagnostics

    /// Reads one counter out of the production set.
    private static func metric(_ value: UInt32) -> UInt32 {
        carrier_diagnostics_get_metric(CarrierMetric(rawValue: value))
    }

    private static let publishAttempts = UInt32(CARRIER_METRIC_PUBLISH_ATTEMPTS.rawValue)
    private static let publishFailures = UInt32(CARRIER_METRIC_PUBLISH_FAILURES.rawValue)
    private static let framesReceived = UInt32(CARRIER_METRIC_FRAMES_RECEIVED.rawValue)
    private static let framesDropped = UInt32(CARRIER_METRIC_FRAMES_DROPPED.rawValue)
    private static let framesOversized = UInt32(CARRIER_METRIC_FRAMES_OVERSIZED.rawValue)
    private static let pollErrors = UInt32(CARRIER_METRIC_POLL_ERRORS.rawValue)
    private static let sessionOpens = UInt32(CARRIER_METRIC_SESSION_OPENS.rawValue)
    private static let sessionCloses = UInt32(CARRIER_METRIC_SESSION_CLOSES.rawValue)
    private static let sessionFailures = UInt32(CARRIER_METRIC_SESSION_FAILURES.rawValue)
    private static let reconnectsObserved = UInt32(CARRIER_METRIC_RECONNECTS_OBSERVED.rawValue)

    static func carrierDiagnostics() {
        let key = Array("sample/key".utf8)
        let payload = Array("sample/payload".utf8)
        var outKey = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxTopicLength)
        var outPayload = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxPayloadSize)
        var outKeyLength: Int32 = 0
        var outPayloadLength: Int32 = 0

        func poll(_ carrier: inout ZenohCarrier, keyCapacity: Int32 = Int32(EmbeddedCarrierBounds.maxTopicLength)) -> Int32 {
            outKey.withUnsafeMutableBufferPointer { keyBuffer in
                outPayload.withUnsafeMutableBufferPointer { payloadBuffer in
                    carrier.pollOneEvent(
                        topic: keyBuffer.baseAddress!, topicCapacity: keyCapacity, topicLength: &outKeyLength,
                        payload: payloadBuffer.baseAddress!, payloadCapacity: Int32(payloadBuffer.count),
                        payloadLength: &outPayloadLength)
                }
            }
        }

        func queueSample() {
            key.withUnsafeBufferPointer { keyBuffer in
                payload.withUnsafeBufferPointer { payloadBuffer in
                    host_zenoh_set_sample(keyBuffer.baseAddress!, Int32(key.count),
                                          payloadBuffer.baseAddress!, Int32(payload.count))
                }
            }
        }

        // A reset phase starts from a known zero, so every number below is
        // attributable to the operation under test.
        host_zenoh_reset()
        ZenohCarrier.resetDiagnostics()
        check(ZenohCarrier.diagnostics.publish_attempts == 0, "reset clears every counter")

        // A refused open is a visible failure, not a silent retry.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_OPEN))
        var carrier = ZenohCarrier()
        check(!carrier.connect(deadlineMS: 5_000), "refused open reports failure")
        check(metric(sessionOpens) == 0, "a refused open is not an open")
        check(metric(sessionFailures) == 1, "a refused open is a session failure")
        host_zenoh_set_failures(0)

        check(carrier.connect(deadlineMS: 5_000), "open succeeds")
        check(metric(sessionOpens) == 1, "one successful open")
        check(!carrier.connect(deadlineMS: 5_000), "second open is rejected")
        check(metric(sessionOpens) == 1, "a rejected second open is not an open")
        check(metric(sessionFailures) == 1, "a rejected second open is not a session failure either")

        // The subscription gauge is a level, and its high-water mark only grows.
        check(withSpan(key, count: key.count) { carrier.subscribe(topic: $0, deadlineMS: 1_000) }, "subscribe")
        check(ZenohCarrier.activeSubscriptions == 1, "one active subscription")
        let second = Array("sample/other".utf8)
        check(withSpan(second, count: second.count) { carrier.subscribe(topic: $0, deadlineMS: 1_000) }, "second subscribe")
        check(ZenohCarrier.activeSubscriptions == 2, "two active subscriptions")
        check(withSpan(second, count: second.count) { carrier.unsubscribe(topic: $0, deadlineMS: 1_000) }, "unsubscribe")
        check(ZenohCarrier.activeSubscriptions == 1, "the gauge follows removal down")
        check(ZenohCarrier.activeSubscriptionsPeak == 2,
              "the high-water mark remembers the highest level")

        // Publish: a success and a transport refusal are told apart.
        check(withTwoSpans(key, payload) { carrier.publish(topic: $0, payload: $1) }, "publish succeeds")
        check(metric(publishAttempts) == 1, "one publish attempt")
        check(metric(publishFailures) == 0, "no publish failure")
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_PUBLISH))
        check(!(withTwoSpans(key, payload) { carrier.publish(topic: $0, payload: $1) }), "refused publish")
        host_zenoh_set_failures(0)
        check(metric(publishAttempts) == 2, "two publish attempts")
        check(metric(publishFailures) == 1, "one publish failure")
        check(metric(sessionFailures) == 2, "open and facade publish failures are session failures")
        let oversizedPayload = [UInt8](repeating: 0, count: EmbeddedCarrierBounds.maxPayloadSize + 1)
        check(!withTwoSpans(key, oversizedPayload) { carrier.publish(topic: $0, payload: $1) },
              "oversized local publication is refused")
        check(metric(publishAttempts) == 3 && metric(publishFailures) == 2,
              "local refusal counts as a failed publication attempt")
        check(metric(sessionFailures) == 2, "local publish refusal has no facade session result")

        // An idle poll is not an event. Counting it would make every steady
        // state look like a busy one and hide a real drop inside noise.
        check(poll(&carrier) == 0, "empty queue polls clean")
        for _ in 0..<8 { _ = poll(&carrier) }
        check(metric(framesReceived) == 0, "idle polls record no frame")
        check(metric(pollErrors) == 0, "idle polls record no error")
        check(metric(framesDropped) == 0, "idle polls record no drop")

        // A delivered frame counts as received.
        queueSample()
        check(poll(&carrier, keyCapacity: 1) == -1, "small output retains the pending frame")
        check(metric(framesReceived) == 0, "pending frame is not yet delivered")
        check(metric(framesOversized) == 0, "small caller storage is not an oversized frame")
        check(poll(&carrier) == 1, "queued frame reports one")
        check(metric(framesReceived) == 1, "one frame received")

        // A drop is counted because Core's own poll result said the queue was
        // full, and it is not double-counted as a receive error.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_REPORT_QUEUE_FULL))
        check(poll(&carrier) == -1, "a drop surfaces as an error to the caller")
        host_zenoh_set_failures(0)
        check(metric(framesDropped) == 1, "one drop")
        check(metric(pollErrors) == 0, "a drop is not a poll error")
        check(metric(framesReceived) == 1, "a drop is not a received frame")

        // An over-bound frame is counted separately from a drop: they are
        // different faults and a reader must be able to tell them apart.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_REPORT_FRAME_TOO_LARGE))
        check(poll(&carrier) == 0, "an oversize frame is counted and polling goes on (no error to the caller)")
        host_zenoh_set_failures(0)
        check(metric(framesOversized) == 1, "one oversized frame")
        check(metric(framesDropped) == 1, "an oversize frame is not a drop")
        check(metric(pollErrors) == 0, "an oversize frame is not a poll error")
        check(metric(framesReceived) == 1, "an oversize frame is not a received frame")
        // The session survives it: the notification is reported once and the next
        // legal frame is delivered by the next poll.
        check(poll(&carrier) == 0, "the oversize notification is not reported twice")
        check(metric(framesOversized) == 1, "the oversize notification is counted once")
        queueSample()
        check(poll(&carrier) == 1, "a legal frame after an oversize frame is delivered")
        check(metric(framesReceived) == 2, "the frame after an oversize frame is received")

        // A genuine transport failure during receive is its own counter.
        let errorsBefore = metric(pollErrors)
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_POLL))
        queueSample()
        check(poll(&carrier) == -1, "carrier poll failure")
        host_zenoh_set_failures(0)
        check(metric(pollErrors) == errorsBefore + 1, "one poll error")
        check(metric(framesReceived) == 2, "a failed poll is not a received frame")

        // Reconnect is counted only for a loss this carrier actually observed.
        // An already-usable session satisfies the connectivity wait and must not
        // manufacture a reconnect.
        check(metric(reconnectsObserved) == 0, "an already-usable router is no reconnect")
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_ROUTERS))
        check(!carrier.waitForReconnect(deadlineMS: 20), "an absent router times out")
        host_zenoh_set_failures(0)
        check(metric(reconnectsObserved) == 0, "an absent router is no reconnect")
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_ROUTER_DROP_THEN_RESTORE))
        check(carrier.waitForReconnect(deadlineMS: 500), "an observed loss and restoration succeeds")
        check(metric(reconnectsObserved) == 1, "restoration at entry counts the previously observed loss")
        // Restoration that finished before the wait began never showed this
        // carrier a loss, so it is connectivity, not a reconnect.
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_ROUTER_DROP_RESTORE_BEFORE_ENTRY))
        check(carrier.waitForReconnect(deadlineMS: 500), "a restored router before entry succeeds")
        check(metric(reconnectsObserved) == 1, "a restoration before entry is not a reconnect")
        host_zenoh_set_failures(0)

        // Teardown releases every declaration, so the gauge must return to zero.
        check(carrier.disconnect(), "teardown")
        check(metric(sessionCloses) == 1, "one successful close")
        check(ZenohCarrier.activeSubscriptions == 0, "no subscription survives teardown")
        check(ZenohCarrier.activeSubscriptionsPeak == 2,
              "the high-water mark survives teardown, which is what makes a leak visible")

        // A closed carrier reports the closed state without inventing a frame.
        check(poll(&carrier) == -2, "poll after close reports closed")

        // The device gate reads these numbers as JSON. The report must be one
        // bounded object that names every counter the C gate relies on.
        let capacity = Int(ZenohCarrier.diagnosticsJSONCapacity)
        check(capacity > 0, "the report capacity is finite")
        var json = [CChar](repeating: 0, count: capacity)
        let written = json.withUnsafeMutableBufferPointer { buffer -> Int in
            ZenohCarrier.writeDiagnosticsJSON(into: buffer.baseAddress!, capacity: capacity)
        }
        check(written > 0, "the counter report fits its stated capacity")
        let text = String(cString: json)
        for name in ["publishAttempts", "publishFailures", "framesReceived", "framesDropped",
                     "framesOversized", "pollErrors", "sessionOpens", "sessionCloses",
                     "sessionFailures", "reconnectsObserved", "activeSubscriptions",
                     "activeSubscriptionsPeak"] {
            check(text.contains("\"\(name)\":"), "the report names \(name)")
        }
        check(text.hasPrefix("{") && text.hasSuffix("}"), "the report is one JSON object")
        check(!text.contains("\n"), "the report carries no newline")
        check(text.contains("\"framesReceived\":2"), "the report carries the counted frames")
        check(text.contains("\"framesDropped\":1"), "the report carries the counted drops")
        check(text.contains("\"sessionOpens\":1"), "the report carries the counted opens")

        // A buffer too small must say so. A truncated metric read as a zero is
        // worse than no report at all, so the gate has to be able to detect it.
        var tiny = [CChar](repeating: 0, count: 8)
        check(tiny.withUnsafeMutableBufferPointer { buffer in
            ZenohCarrier.writeDiagnosticsJSON(into: buffer.baseAddress!, capacity: 8)
        } == 0, "an undersized report buffer reports that it did not fit")
        check(tiny.withUnsafeMutableBufferPointer { buffer in
            ZenohCarrier.writeDiagnosticsJSON(into: buffer.baseAddress!, capacity: 0)
        } == 0, "a zero-capacity report buffer reports that it did not fit")

        // Observe a complete loss/restoration inside one wait. The HAL's first
        // query is consumed by connect, its second reports loss, its third restores.
        host_zenoh_reset()
        ZenohCarrier.resetDiagnostics()
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_ROUTER_DROP_THEN_RESTORE))
        var restored = ZenohCarrier()
        check(restored.connect(deadlineMS: 5_000), "open before router loss")
        check(withSpan(key, count: key.count) { restored.subscribe(topic: $0, deadlineMS: 1_000) },
              "subscribe before router loss")
        check(restored.waitForReconnect(deadlineMS: 500), "restoration within the wait succeeds")
        check(metric(reconnectsObserved) == 1, "loss at the entry query is preserved")
        check(host_zenoh_router_query_count() == 3, "diagnostics add no router queries")
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_SUBSCRIBE))
        check(!withSpan(second, count: second.count) { restored.subscribe(topic: $0, deadlineMS: 1_000) },
              "failed subscribe does not change the gauge")
        check(ZenohCarrier.activeSubscriptions == 1 && metric(sessionFailures) == 1,
              "failed subscribe increments only the failure count")
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_UNSUBSCRIBE))
        check(!withSpan(key, count: key.count) { restored.unsubscribe(topic: $0, deadlineMS: 1_000) },
              "failed unsubscribe retains the slot")
        check(ZenohCarrier.activeSubscriptions == 1 && metric(sessionFailures) == 2,
              "failed unsubscribe is counted without losing its declaration")
        host_zenoh_set_failures(UInt32(HOST_ZENOH_FAIL_UNSUBSCRIBE | HOST_ZENOH_FAIL_CLOSE))
        check(!restored.disconnect(), "failed close still performs terminal cleanup")
        check(metric(sessionCloses) == 0 && metric(sessionFailures) == 4,
              "teardown unsubscribe and close failures are counted separately")
        check(ZenohCarrier.activeSubscriptions == 0 && ZenohCarrier.activeSubscriptionsPeak == 1,
              "failed teardown clears the live gauge but retains the peak")
        check(!restored.disconnect() && metric(sessionFailures) == 4,
              "terminal repeated teardown produces no facade result")

        ZenohCarrier.resetDiagnostics()
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
