// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Carrier mechanics for the ESP32-C6 device smoke image.
//
// This file owns the bounded, synchronous sequence of carrier operations the
// network smoke scenarios drive: last-will configuration, connect, subscribe,
// reconnect, oversize rejection, publish, loopback receive, and disconnect.
// It reports each step through the caller's recorder in the exact order the
// frozen `embedded-swift-smoke-v2` corpus expects. Topic and payload bytes are
// borrowed from caller storage, consumed synchronously, and never retained.

/// Runs the credential-backed carrier probe and reports every bounded step.
///
/// The application calls this only after the profile reports that the network
/// is configured and that the device role selects the probe path. The platform
/// network façade is supplied as function pointers so this transport does not
/// depend on the application seam type.
func runCarrierNetworkProbe(
    networkPrepare: @convention(c) (UInt32) -> UInt32,
    networkCopyTopic: @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32,
    networkCopyPayload: @convention(c) (UnsafeMutablePointer<UInt8>, Int32) -> Int32,
    networkCleanup: @convention(c) () -> UInt32,
    record: (StaticString, Bool) -> Void
) {
    let networkBits = networkPrepare(90_000)
    record("network:wifi", (networkBits & 1) != 0)
    record("network:ip", (networkBits & 2) != 0)
    if (networkBits & 3) == 3 {
        var probe = EmbeddedMQTTClient()
        record("network:rejectOutOfOrder", !probe.disconnect())
        var client = EmbeddedMQTTClient()
        let willTopic: StaticString = "axoloty/network/will"
        let willPayload: StaticString = "axoloty-network-offline"
        let lastWillConfigured = client.configureLastWill(
            topic: willTopic.utf8Start, topicLength: Int32(willTopic.utf8CodeUnitCount),
            payload: willPayload.utf8Start, payloadLength: Int32(willPayload.utf8CodeUnitCount)
        )
        record("network:lastWillConfigured", lastWillConfigured)
        let connected = lastWillConfigured && client.connect(deadlineMS: 15_000)
        record("network:mqttConnect", connected)
        var subscribed = false
        var reconnected = false
        var rejectedOversize = false
        var published = false
        var received = false
        if connected {
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 257) { topic in
                withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 2_049) { payload in
                    let topicLength = networkCopyTopic(topic.baseAddress!, Int32(topic.count))
                    let payloadLength = networkCopyPayload(payload.baseAddress!, Int32(payload.count))
                    if topicLength > 0 && payloadLength >= 0 {
                        subscribed = client.subscribe(
                            topic: topic.baseAddress!, topicLength: Int32(topicLength),
                            deadlineMS: 10_000
                        )
                        reconnected = subscribed && client.waitForReconnect(deadlineMS: 20_000)
                        rejectedOversize = reconnected && !client.publish(
                            topic: topic.baseAddress!, topicLength: 257,
                            payload: payload.baseAddress!, payloadLength: 0
                        )
                        published = reconnected && client.publish(
                            topic: topic.baseAddress!, topicLength: Int32(topicLength),
                            payload: payload.baseAddress!, payloadLength: Int32(payloadLength)
                        )
                        received = published && client.waitForLoopback(deadlineMS: 10_000)
                    }
                }
            }
        }
        record("network:subscribe", subscribed)
        record("network:reconnect", reconnected)
        record("network:rejectOversize", rejectedOversize)
        record("network:publish", published)
        record("network:receive", received)
        let disconnected = client.disconnect()
        let cleanedUp = networkCleanup() != 0
        record("network:disconnect", disconnected && cleanedUp)
    } else {
        record("network:mqttConnect", false)
        record("network:lastWillConfigured", false)
        record("network:subscribe", false)
        record("network:reconnect", false)
        record("network:rejectOutOfOrder", false)
        record("network:rejectOversize", false)
        record("network:publish", false)
        record("network:receive", false)
        record("network:disconnect", networkCleanup() != 0)
    }
}

/// Reports the agent-exchange result bits as the frozen `exchange:*` corpus.
///
/// The platform owns the exchange itself; this transport owns the carrier-step
/// identifiers and the scenario bit layout it reports.
func emitAgentExchange(
    _ exchangeBits: UInt32,
    _ scenario: UInt32,
    record: (StaticString, Bool) -> Void
) {
    let exchangeChecks: [(StaticString, UInt32)] = scenario == 1 ? [
        ("exchange:wifi", 1), ("exchange:ip", 2),
        ("exchange:mqttConnect", 4), ("exchange:subscribe", 8),
        ("exchange:reconnect", 512), ("exchange:advertise", 16),
        ("exchange:deadvertise", 128), ("exchange:disconnect", 256),
    ] : scenario == 2 ? [
        ("exchange:wifi", 1), ("exchange:ip", 2),
        ("exchange:mqttConnect", 4), ("exchange:subscribe", 8),
        ("exchange:reconnect", 512), ("exchange:brokerReconnect", 1024),
        ("exchange:advertise", 16), ("exchange:discover", 32),
        ("exchange:resolve", 64), ("exchange:deadvertise", 128),
        ("exchange:disconnect", 256),
    ] : [
        ("exchange:wifi", 1), ("exchange:ip", 2),
        ("exchange:mqttConnect", 4), ("exchange:subscribe", 8),
        ("exchange:reconnect", 512),
        ("exchange:advertise", 16), ("exchange:discover", 32),
        ("exchange:resolve", 64), ("exchange:deadvertise", 128),
        ("exchange:disconnect", 256),
    ]
    for (name, bit) in exchangeChecks { record(name, (exchangeBits & bit) != 0) }
}
