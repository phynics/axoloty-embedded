// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Carrier mechanics for the ESP32-C6 device smoke image, over the session
// transport.
//
// This file owns the bounded, synchronous sequence of carrier operations the
// network smoke scenarios drive: capability reporting, connect, subscribe,
// reconnect observation, oversize rejection, publish, and disconnect. It
// reports each step through the caller's recorder in the same order the
// sibling transport's probe uses. Key and payload bytes are borrowed from
// caller storage, consumed synchronously, and never retained.
//
// Two operations the sibling probe performs have no equivalent in this
// profile, and both are reported as explicit unsupported capabilities rather
// than silent omissions or counted passes:
//
// - Broker last-will: the v1 client profile this transport implements keeps
//   no broker will, so configuration is always refused and the probe records
//   that refusal.
// - Self-loopback receive: the pinned profile disables local delivery of a
//   session's own publications, so a single-client probe cannot observe its
//   own publish. Bidirectional delivery is proven on the two-participant
//   exchange path instead, and the probe records that boundary.

/// Runs the credential-backed carrier probe and reports every bounded step.
///
/// The application calls this only after the profile reports that the network
/// is configured and that the device role selects the probe path. The platform
/// network facade is supplied as function pointers so this transport does not
/// depend on the application seam type.
public func runCarrierNetworkProbe(
    networkPrepare: @convention(c) (UInt32) -> UInt32,
    networkReconnect: @convention(c) (UInt32) -> UInt32,
    networkCopyTopic: @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32,
    networkCopyPayload: @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32,
    networkCleanup: @convention(c) () -> UInt32,
    record: (StaticString, Bool) -> Void,
    recordUnsupported: (StaticString) -> Void
) {
    let networkBits = networkPrepare(90_000)
    record("network:wifi", (networkBits & 1) != 0)
    record("network:ip", (networkBits & 2) != 0)
    if (networkBits & 3) == 3 {
        var idleCheck = ZenohCarrier()
        record("network:rejectOutOfOrder", !idleCheck.disconnect())
        var carrier = ZenohCarrier()
        let willTopic: StaticString = "axoloty/network/will"
        let willPayload: StaticString = "axoloty-network-offline"
        // The call below always refuses; the record proves the refusal was
        // observed rather than assumed.
        let willRefused = !carrier.configureLastWill(
            topic: Span(_unsafeStart: willTopic.utf8Start, count: willTopic.utf8CodeUnitCount),
            payload: Span(_unsafeStart: willPayload.utf8Start, count: willPayload.utf8CodeUnitCount)
        )
        if willRefused {
            recordUnsupported("network:lastWillUnsupported")
        } else {
            record("network:lastWillUnsupported", false)
        }
        let connected = willRefused && carrier.connect(deadlineMS: 15_000)
        record("network:zenohConnect", connected)
        var subscribed = false
        var reconnected = false
        var rejectedOversize = false
        var published = false
        if connected {
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 257) { topic in
                withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 2_049) { payload in
                    let topicLength = networkCopyTopic(topic.baseAddress!, Int32(topic.count))
                    let payloadLength = networkCopyPayload(payload.baseAddress!, Int32(payload.count))
                    if topicLength > 0, topicLength <= Int32(topic.count),
                       payloadLength >= 0, payloadLength <= Int32(payload.count) {
                        let topicSpan = Span(_unsafeStart: topic.baseAddress!, count: Int(topicLength))
                        let payloadSpan = Span(_unsafeStart: payload.baseAddress!, count: Int(payloadLength))
                        subscribed = carrier.subscribe(
                            topic: topicSpan,
                            deadlineMS: 10_000
                        )
                        let networkReturned = subscribed && networkReconnect(20_000) != 0
                        // This is a connectivity wait, not evidence of a new
                        // loss/recovery interval. An already usable session
                        // satisfies the operation; hardware recovery evidence
                        // is recorded by the dedicated qualification test.
                        reconnected = networkReturned && carrier.waitForReconnect(deadlineMS: 20_000)
                        let overlongTopic = Span(_unsafeStart: topic.baseAddress!, count: topic.count)
                        let emptyPayload = Span(_unsafeStart: payload.baseAddress!, count: 0)
                        rejectedOversize = reconnected && !carrier.publish(
                            topic: overlongTopic, payload: emptyPayload
                        )
                        published = reconnected && carrier.publish(
                            topic: topicSpan, payload: payloadSpan
                        )
                    }
                }
            }
        }
        record("network:subscribe", subscribed)
        record("network:reconnect", reconnected)
        record("network:rejectOversize", rejectedOversize)
        record("network:publish", published)
        // No loopback is attempted: this profile does not deliver a session's
        // own publications back to itself, so a received frame here would
        // need a second participant. The record below documents that
        // boundary instead of inventing a pass.
        recordUnsupported("network:receiveUnsupported")
        let disconnected = carrier.disconnect()
        let cleanedUp = networkCleanup() != 0
        record("network:disconnect", disconnected && cleanedUp)
    } else {
        record("network:zenohConnect", false)
        recordUnsupported("network:lastWillUnsupported")
        record("network:subscribe", false)
        record("network:reconnect", false)
        record("network:rejectOutOfOrder", false)
        record("network:rejectOversize", false)
        record("network:publish", false)
        recordUnsupported("network:receiveUnsupported")
        record("network:disconnect", networkCleanup() != 0)
    }
}
