// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

enum DeviceAgentRole: UInt32 {
    case roleA = 1
    case roleB = 2

    var staticAgentRole: StaticAgentRole {
        switch self {
        case .roleA: return .roleA
        case .roleB: return .roleB
        }
    }
}

enum DeviceAgentScenario: UInt32 {
    case exchange = 0
    case lastWill = 1
    case brokerRestart = 2
    case hostManagedLastWill = 3
}

struct AgentExchangeResult: OptionSet {
    let rawValue: UInt32

    static let wifi = Self(rawValue: 1 << 0)
    static let ip = Self(rawValue: 1 << 1)
    static let connected = Self(rawValue: 1 << 2)
    static let subscribed = Self(rawValue: 1 << 3)
    static let advertised = Self(rawValue: 1 << 4)
    static let discovered = Self(rawValue: 1 << 5)
    static let resolved = Self(rawValue: 1 << 6)
    static let deadvertised = Self(rawValue: 1 << 7)
    static let disconnected = Self(rawValue: 1 << 8)
    static let reconnected = Self(rawValue: 1 << 9)
    static let brokerReconnected = Self(rawValue: 1 << 10)
}

private struct AgentExchangeDeadline {
    let endMS: UInt64

    func remaining(using seam: DeviceSmokeSeam) -> UInt32 {
        let microseconds = seam.nowMicroseconds()
        let currentMS = UInt64(max(0, microseconds / 1_000))
        guard currentMS < endMS else { return 0 }
        return UInt32(min(endMS - currentMS, UInt64(UInt32.max)))
    }
}

private func prepareAgentMessage(
    role: DeviceAgentRole,
    kind: StaticAgentMessageKind,
    seam: DeviceSmokeSeam,
    topic: UnsafeMutablePointer<UInt8>,
    payload: UnsafeMutablePointer<UInt8>,
    topicLength: inout Int32,
    payloadLength: inout Int32
) -> Bool {
    topicLength = 0
    payloadLength = 0
    guard prepareStaticAgentMessage(
        role: role.staticAgentRole,
        kind: kind,
        topicBuffer: topic,
        topicCapacity: Int32(WireBufferConfig.maxTopicLength),
        payloadBuffer: payload,
        payloadCapacity: Int32(WireBufferConfig.maxPayloadSize),
        topicLength: &topicLength,
        payloadLength: &payloadLength
    ) else { return false }
    return topicLength > 0 && payloadLength >= 0
}

private func publishAgentMessage(
    seam: DeviceSmokeSeam,
    topic: UnsafePointer<UInt8>,
    topicLength: Int32,
    payload: UnsafePointer<UInt8>,
    payloadLength: Int32
) -> Bool {
    guard topicLength > 0, payloadLength >= 0 else { return false }
    return seam.carrier.publish(
        topic, topicLength, payload, payloadLength
    ) != 0
}

private func prepareAndPublishAgentMessage(
    role: DeviceAgentRole,
    kind: StaticAgentMessageKind,
    seam: DeviceSmokeSeam,
    topic: UnsafeMutablePointer<UInt8>,
    payload: UnsafeMutablePointer<UInt8>
) -> Bool {
    var topicLength: Int32 = 0
    var payloadLength: Int32 = 0
    guard prepareAgentMessage(
        role: role, kind: kind, seam: seam,
        topic: topic, payload: payload,
        topicLength: &topicLength, payloadLength: &payloadLength
    ) else { return false }
    return publishAgentMessage(
        seam: seam,
        topic: topic, topicLength: topicLength,
        payload: payload, payloadLength: payloadLength
    )
}

private func publishControlMessage(
    topic: StaticString,
    payload: StaticString,
    seam: DeviceSmokeSeam
) -> Bool {
    seam.carrier.publish(
        topic.utf8Start, Int32(topic.utf8CodeUnitCount),
        payload.utf8Start, Int32(payload.utf8CodeUnitCount)
    ) != 0
}

/// Owns role/scenario decisions, deadlines, message sequencing, and result bits.
/// Carrier callbacks only move bounded bytes; all message meaning stays here.
@inline(never)
func runDeviceAgentExchange(
    role roleValue: UInt32,
    scenario scenarioValue: UInt32,
    seam: DeviceSmokeSeam
) -> AgentExchangeResult {
    guard let role = DeviceAgentRole(rawValue: roleValue),
          let scenario = DeviceAgentScenario(rawValue: scenarioValue) else { return [] }

    resetStaticDeviceAgents()
    let startMS = UInt64(max(0, seam.nowMicroseconds() / 1_000))
    let deadline = AgentExchangeDeadline(endMS: startMS + 90_000)
    var result: AgentExchangeResult = []
    let networkBits = seam.networkPrepare(90_000)
    if (networkBits & 1) != 0 { result.insert(.wifi) }
    if (networkBits & 2) != 0 { result.insert(.ip) }

    var connected = false
    if (networkBits & 3) == 3 {
        let configuredWill: Bool
        if role == .roleA {
            configuredWill = withUnsafeTemporaryAllocation(
                of: UInt8.self, capacity: WireBufferConfig.maxTopicLength
            ) { willTopic in
                withUnsafeTemporaryAllocation(
                    of: UInt8.self, capacity: WireBufferConfig.maxPayloadSize
                ) { willPayload in
                    var willTopicLength: Int32 = 0
                    var willPayloadLength: Int32 = 0
                    guard prepareStaticAgentMessage(
                        role: role.staticAgentRole,
                        kind: .deadvertise,
                        topicBuffer: willTopic.baseAddress!,
                        topicCapacity: Int32(willTopic.count),
                        payloadBuffer: willPayload.baseAddress!,
                        payloadCapacity: Int32(willPayload.count),
                        topicLength: &willTopicLength,
                        payloadLength: &willPayloadLength
                    ) else { return false }
                    return seam.carrier.configureLastWill(
                        willTopic.baseAddress!, willTopicLength,
                        willPayload.baseAddress!, willPayloadLength
                    ) != 0
                }
            }
        } else {
            configuredWill = true
        }

        if configuredWill && deadline.remaining(using: seam) > 0 &&
            seam.carrier.connect(deadline.remaining(using: seam)) != 0 {
            connected = true
            result.insert(.connected)
            seam.exchangeMilestone(DeviceSmokeExchangeMilestone.connected.rawValue)

            let filter: StaticString = "coaty/3/axoloty-embedded/#"
            let subscribed = seam.carrier.subscribe(
                filter.utf8Start, Int32(filter.utf8CodeUnitCount), deadline.remaining(using: seam)
            ) != 0
            if subscribed {
                result.insert(.subscribed)
                seam.exchangeMilestone(DeviceSmokeExchangeMilestone.subscribed.rawValue)

                let networkReturned = seam.networkReconnect(deadline.remaining(using: seam))
                if (networkReturned & 3) == 3 &&
                    seam.carrier.waitForReconnect(deadline.remaining(using: seam)) != 0 {
                    result.insert(.reconnected)
                    seam.exchangeMilestone(DeviceSmokeExchangeMilestone.reconnected.rawValue)

                    var scenarioReady = true
                    if scenario == .lastWill && role == .roleB {
                        scenarioReady = publishControlMessage(
                            topic: "axoloty/test/agent-ready/B", payload: "ready", seam: seam
                        )
                    }
                    if scenario == .brokerRestart {
                        let readyPublished = publishControlMessage(
                            topic: "axoloty/test/agent-ready/B", payload: "ready", seam: seam
                        )
                        if readyPublished && deadline.remaining(using: seam) > 0 &&
                            seam.carrier.waitForReconnect(deadline.remaining(using: seam)) != 0 {
                            result.insert(.brokerReconnected)
                        } else {
                            scenarioReady = false
                        }
                    }

                    if scenarioReady && result.contains(.reconnected) &&
                        (scenario != .brokerRestart || result.contains(.brokerReconnected)) {
                        runAgentMessageSequence(
                            role: role, scenario: scenario, seam: seam,
                            deadline: deadline, result: &result
                        )
                    }
                }
            }
        }
    }

    let carrierDisconnected = connected && seam.carrier.disconnect() != 0
    let networkCleaned = seam.networkCleanup() != 0
    if carrierDisconnected && networkCleaned { result.insert(.disconnected) }
    return result
}

private func handleAgentMessage(
    _ action: StaticAgentAction,
    role: DeviceAgentRole,
    scenario: DeviceAgentScenario,
    seam: DeviceSmokeSeam,
    deadline: AgentExchangeDeadline,
    outputTopic: UnsafeMutablePointer<UInt8>,
    outputTopicLength: Int32,
    outputPayload: UnsafeMutablePointer<UInt8>,
    outputPayloadLength: Int32,
    actorRoute: UnsafeMutablePointer<UInt8>,
    actorRouteLength: inout Int32,
    result: inout AgentExchangeResult
) -> Bool {
    switch action {
    case .response:
        if role == .roleB {
            result.insert(.advertised)
            if scenario == .lastWill {
                _ = publishControlMessage(
                    topic: "axoloty/test/agent-observed/B", payload: "advertise", seam: seam
                )
                return false
            }
            guard outputTopicLength > 0, outputPayloadLength >= 0,
                  seam.carrier.publish(
                    outputTopic, outputTopicLength, outputPayload, outputPayloadLength
                  ) != 0 else { return false }
            result.insert(.discovered)
        } else {
            result.insert(.discovered)
            guard outputTopicLength > 0, outputPayloadLength >= 0,
                  seam.carrier.publish(
                    outputTopic, outputTopicLength, outputPayload, outputPayloadLength
                  ) != 0 else { return false }
            result.insert(.resolved)
            seam.exchangeMilestone(DeviceSmokeExchangeMilestone.resolved.rawValue)
        }
        return false
    case .resolved:
        result.insert(.resolved)
        return false
    case .deadvertised:
        result.insert(.deadvertised)
        return role == .roleB
    case .actorAssociated:
        guard let length = copyStaticAgentActorRoute(
            role: role.staticAgentRole,
            to: actorRoute,
            capacity: WireBufferConfig.maxTopicLength
        ), length > 0, length <= WireBufferConfig.maxTopicLength else { return false }
        actorRouteLength = Int32(length)
        _ = seam.carrier.subscribe(
            actorRoute, actorRouteLength, deadline.remaining(using: seam)
        )
        return false
    case .actorDisassociated:
        guard actorRouteLength > 0 else { return false }
        _ = seam.carrier.unsubscribe(actorRoute, actorRouteLength, deadline.remaining(using: seam))
        actorRouteLength = 0
        return false
    case .ioValueDelivered, .ignored, .rejected:
        return false
    }
}

@inline(never)
private func runAgentMessageSequence(
    role: DeviceAgentRole,
    scenario: DeviceAgentScenario,
    seam: DeviceSmokeSeam,
    deadline: AgentExchangeDeadline,
    result: inout AgentExchangeResult
) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxTopicLength) { inboundTopic in
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxPayloadSize) { inboundPayload in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxTopicLength) { responseTopic in
                withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxPayloadSize) { responsePayload in
                    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxTopicLength) { actorRoute in
                        var actorRouteLength: Int32 = 0
                        var advertisedTopicLength: Int32 = 0
                        var advertisedPayloadLength: Int32 = 0
                        var advertisementPrepared = role != .roleA
                        if role == .roleA {
                            // The processor records the outbound transition during encoding.
                            // Keep one encoded Advertise and retry those bytes until a peer responds.
                            advertisementPrepared = prepareAgentMessage(
                                role: role, kind: .advertise, seam: seam,
                                topic: responseTopic.baseAddress!, payload: responsePayload.baseAddress!,
                                topicLength: &advertisedTopicLength,
                                payloadLength: &advertisedPayloadLength
                            )
                        }
                        var nextAdvertiseMS: UInt64 = 0
                        var exchangeComplete = false
                        var deadvertiseDelayStarted = false
                        var deadvertiseReadyAtMS: UInt64 = 0
                        var deadvertisePublishedAtMS: UInt64?

                        while !exchangeComplete && deadline.remaining(using: seam) > 0 {
                            let nowMS = UInt64(max(0, seam.nowMicroseconds() / 1_000))
                            _ = expireStaticAgentRequest(role: role.staticAgentRole)
                            let shouldRepeatAdvertise = scenario == .lastWill
                            if role == .roleA &&
                                (shouldRepeatAdvertise || !result.contains(.discovered)) &&
                                nowMS >= nextAdvertiseMS {
                                if advertisementPrepared && publishAgentMessage(
                                    seam: seam,
                                    topic: responseTopic.baseAddress!, topicLength: advertisedTopicLength,
                                    payload: responsePayload.baseAddress!, payloadLength: advertisedPayloadLength
                                ) {
                                    let firstAdvertise = !result.contains(.advertised)
                                    result.insert(.advertised)
                                    if firstAdvertise {
                                        seam.exchangeMilestone(DeviceSmokeExchangeMilestone.advertised.rawValue)
                                    }
                                }
                                nextAdvertiseMS = nowMS + (shouldRepeatAdvertise ? 1_000 : 2_000)
                            }

                            var inboundTopicLength: Int32 = 0
                            var inboundPayloadLength: Int32 = 0
                            let polled = seam.carrier.pollOneEvent(
                                inboundTopic.baseAddress!, Int32(inboundTopic.count), &inboundTopicLength,
                                inboundPayload.baseAddress!, Int32(inboundPayload.count), &inboundPayloadLength
                            )
                            if polled == 1 {
                                exchangeComplete = withUnsafeTemporaryAllocation(
                                    of: Int32.self, capacity: 2
                                ) { outputLengths in
                                    outputLengths[0] = 0
                                    outputLengths[1] = 0
                                    let action = receiveStaticAgentMessage(
                                        role: role.staticAgentRole,
                                        inboundTopic.baseAddress!, inboundTopicLength,
                                        inboundPayload.baseAddress!, inboundPayloadLength,
                                        responseTopic.baseAddress!, Int32(responseTopic.count),
                                        responsePayload.baseAddress!, Int32(responsePayload.count),
                                        &outputLengths[0], &outputLengths[1]
                                    )
                                    return handleAgentMessage(
                                        action, role: role, scenario: scenario, seam: seam,
                                        deadline: deadline,
                                        outputTopic: responseTopic.baseAddress!,
                                        outputTopicLength: outputLengths[0],
                                        outputPayload: responsePayload.baseAddress!,
                                        outputPayloadLength: outputLengths[1],
                                        actorRoute: actorRoute.baseAddress!,
                                        actorRouteLength: &actorRouteLength,
                                        result: &result
                                    )
                                }
                            } else if polled == -2 && scenario == .hostManagedLastWill &&
                                      role == .roleA && result.contains(.resolved) {
                                result.insert(.deadvertised)
                                exchangeComplete = true
                            } else if polled < 0 {
                                exchangeComplete = true
                            }

                            if role == .roleA && result.contains(.resolved) &&
                                scenario != .lastWill && scenario != .hostManagedLastWill &&
                                !result.contains(.deadvertised) {
                                if !deadvertiseDelayStarted {
                                    deadvertiseDelayStarted = true
                                    deadvertiseReadyAtMS = nowMS + 500
                                } else if nowMS >= deadvertiseReadyAtMS {
                                    if prepareAndPublishAgentMessage(
                                        role: role, kind: .deadvertise, seam: seam,
                                        topic: responseTopic.baseAddress!, payload: responsePayload.baseAddress!
                                    ) {
                                        result.insert(.deadvertised)
                                        deadvertisePublishedAtMS = nowMS
                                    }
                                }
                            }
                            if role == .roleA, let publishedAt = deadvertisePublishedAtMS,
                               nowMS >= publishedAt + 500 {
                                exchangeComplete = true
                            }
                            if role == .roleB && result.contains(.deadvertised) {
                                exchangeComplete = true
                            }
                            if !exchangeComplete { seam.delay(20) }
                        }
                    }
                }
            }
        }
    }
}

func emitDeviceAgentExchange(
    _ result: AgentExchangeResult,
    scenario scenarioValue: UInt32,
    record: (StaticString, Bool) -> Void
) {
    let scenario = DeviceAgentScenario(rawValue: scenarioValue) ?? .exchange
    record("exchange:wifi", result.contains(.wifi))
    record("exchange:ip", result.contains(.ip))
    record("exchange:mqttConnect", result.contains(.connected))
    record("exchange:subscribe", result.contains(.subscribed))
    record("exchange:reconnect", result.contains(.reconnected))
    if scenario == .brokerRestart {
        record("exchange:brokerReconnect", result.contains(.brokerReconnected))
    }
    record("exchange:advertise", result.contains(.advertised))
    if scenario != .lastWill {
        record("exchange:discover", result.contains(.discovered))
        record("exchange:resolve", result.contains(.resolved))
    }
    record("exchange:deadvertise", result.contains(.deadvertised))
    record("exchange:disconnect", result.contains(.disconnected))
}
