// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

private enum HostExchangeFixtureState {
    nonisolated(unsafe) static var topic = [UInt8](repeating: 0, count: WireBufferConfig.maxTopicLength)
    nonisolated(unsafe) static var payload = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
    nonisolated(unsafe) static var topicLength: Int32 = 0
    nonisolated(unsafe) static var payloadLength: Int32 = 0
    nonisolated(unsafe) static var pendingPeerFrame = false
    nonisolated(unsafe) static var subscribeCount = 0
    nonisolated(unsafe) static var failSubscribeAt = 0
}

/// Installs a deterministic role-B Discover frame for the ABI-backed fixture.
func prepareHostExchangePeerFrame() {
    var seam = hostSmokeSeam()
    seam.nowMicroseconds = { Int64(host_smoke_virtual_now()) }
    seam.delay = host_smoke_virtual_delay
    installDeviceSmokeSeam(seam)
    resetStaticDeviceAgents()
    var topic = [UInt8](repeating: 0, count: WireBufferConfig.maxTopicLength)
    var payload = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
    var topicLength: Int32 = 0
    var payloadLength: Int32 = 0
    let prepared = topic.withUnsafeMutableBufferPointer { topicBuffer in
        payload.withUnsafeMutableBufferPointer { payloadBuffer in
            prepareStaticAgentMessage(
                role: DeviceAgentRole.roleB.staticAgentRole,
                kind: .discover,
                topicBuffer: topicBuffer.baseAddress!, topicCapacity: Int32(topicBuffer.count),
                payloadBuffer: payloadBuffer.baseAddress!, payloadCapacity: Int32(payloadBuffer.count),
                topicLength: &topicLength, payloadLength: &payloadLength
            )
        }
    }
    precondition(prepared && topicLength > 0 && payloadLength > 0)
    HostExchangeFixtureState.topic = topic
    HostExchangeFixtureState.payload = payload
    HostExchangeFixtureState.topicLength = topicLength
    HostExchangeFixtureState.payloadLength = payloadLength
    HostExchangeFixtureState.pendingPeerFrame = true
    topic.withUnsafeBufferPointer { topicBuffer in
        payload.withUnsafeBufferPointer { payloadBuffer in
            host_mqtt_set_event(topicBuffer.baseAddress, topicLength,
                                payloadBuffer.baseAddress, payloadLength)
        }
    }
}

/// Runs the real exchange logic against a deterministic seam and records the
/// same named operations as the ABI-backed C forwarding table.
func runHostExchangeSeamBaseline(role: UInt32, scenario: UInt32, failSubscribeAt: Int) {
    var seam = hostSmokeSeam()
    seam.nowMicroseconds = { Int64(host_smoke_virtual_now()) }
    seam.delay = host_smoke_virtual_delay
    installDeviceSmokeSeam(seam)
    resetStaticDeviceAgents()
    var topic = [UInt8](repeating: 0, count: WireBufferConfig.maxTopicLength)
    var payload = [UInt8](repeating: 0, count: WireBufferConfig.maxPayloadSize)
    var topicLength: Int32 = 0
    var payloadLength: Int32 = 0
    let prepared = topic.withUnsafeMutableBufferPointer { topicBuffer in
        payload.withUnsafeMutableBufferPointer { payloadBuffer in
            prepareStaticAgentMessage(
                role: DeviceAgentRole.roleB.staticAgentRole,
                kind: .discover,
                topicBuffer: topicBuffer.baseAddress!, topicCapacity: Int32(topicBuffer.count),
                payloadBuffer: payloadBuffer.baseAddress!, payloadCapacity: Int32(payloadBuffer.count),
                topicLength: &topicLength, payloadLength: &payloadLength
            )
        }
    }
    precondition(prepared && topicLength > 0 && payloadLength > 0)
    HostExchangeFixtureState.topic = topic
    HostExchangeFixtureState.payload = payload
    HostExchangeFixtureState.topicLength = topicLength
    HostExchangeFixtureState.payloadLength = payloadLength
    HostExchangeFixtureState.pendingPeerFrame = true
    HostExchangeFixtureState.subscribeCount = 0
    HostExchangeFixtureState.failSubscribeAt = failSubscribeAt
    seam.networkPrepare = { deadline in
        _ = deadline
        host_exchange_trace("networkPrepare")
        return 3
    }
    seam.networkReconnect = { deadline in
        _ = deadline
        host_exchange_trace("networkReconnect")
        return 3
    }
    seam.networkCleanup = {
        host_exchange_trace("networkCleanup")
        return 1
    }
    seam.carrier.supportsLastWill = {
        host_exchange_trace("supportsLastWill")
        return 1
    }
    seam.carrier.configureLastWill = { _, _, _, _ in
        host_exchange_trace("configureLastWill")
        return 1
    }
    seam.carrier.connect = { _ in host_exchange_trace("connect"); return 1 }
    seam.carrier.subscribe = { _, _, _ in
        HostExchangeFixtureState.subscribeCount += 1
        host_exchange_trace("subscribe")
        return HostExchangeFixtureState.subscribeCount == HostExchangeFixtureState.failSubscribeAt ? 0 : 1
    }
    seam.carrier.unsubscribe = { _, _, _ in host_exchange_trace("unsubscribe"); return 1 }
    seam.carrier.publish = { _, _, _, _ in host_exchange_trace("publish"); return 1 }
    seam.carrier.pollOneEvent = { outTopic, outTopicCapacity, outTopicLength,
                                  outPayload, outPayloadCapacity, outPayloadLength in
        host_exchange_trace("pollOneEvent")
        guard HostExchangeFixtureState.pendingPeerFrame,
              HostExchangeFixtureState.topicLength <= outTopicCapacity,
              HostExchangeFixtureState.payloadLength <= outPayloadCapacity else { return 0 }
        for index in 0..<Int(HostExchangeFixtureState.topicLength) {
            outTopic[index] = HostExchangeFixtureState.topic[index]
        }
        for index in 0..<Int(HostExchangeFixtureState.payloadLength) {
            outPayload[index] = HostExchangeFixtureState.payload[index]
        }
        outTopicLength.pointee = HostExchangeFixtureState.topicLength
        outPayloadLength.pointee = HostExchangeFixtureState.payloadLength
        HostExchangeFixtureState.pendingPeerFrame = false
        return 1
    }
    seam.carrier.waitForReconnect = { _ in host_exchange_trace("waitForReconnect"); return 1 }
    seam.carrier.disconnect = { host_exchange_trace("disconnect"); return 1 }
    seam.exchangeMilestone = { value in
        switch DeviceSmokeExchangeMilestone(rawValue: value) {
        case .connected: host_exchange_trace("milestone:connected")
        case .subscribed: host_exchange_trace("milestone:subscribed")
        case .reconnected: host_exchange_trace("milestone:reconnected")
        case .advertised: host_exchange_trace("milestone:advertised")
        case .resolved: host_exchange_trace("milestone:resolved")
        case .none: break
        }
    }
    installDeviceSmokeSeam(seam)
    let result = runDeviceAgentExchange(role: role, scenario: scenario, seam: seam)
    precondition(result.contains(.disconnected), "seam baseline must complete network and carrier cleanup")
}
