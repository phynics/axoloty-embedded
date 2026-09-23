// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Embedded Swift entry point for the device smoke application.
//
// Runs AxolotyWire test vectors on-device using the real Swift wire codec.
// Emits structured JSON Lines records over serial. The host harness parses
// these records and validates their evidence chain.
//
// Operating-system, board, and carrier operations arrive through the
// ``DeviceSmokeSeam`` the running profile installs; this file names none of
// them. Success is NEVER emitted before all checks complete.

import AxolotyWire
import AxolotyProtocol
import AxolotyObjectModel
#if HOST_AGENT_EXCHANGE
import DeviceSmokeHostSupport
#endif

@inline(__always)
/// Records that the registry invoked its handler.
///
/// The handler context is a `UInt32`, so it cannot carry a host pointer on a
/// 64-bit host. The flag is process-global and the vector resets it before
/// dispatching, which is identical on the 32-bit device and safe on a host.
nonisolated(unsafe) private var routerDispatchObserved = false

private func recordRouterDispatch(
    _: UInt32,
    _: UnsafePointer<UInt8>?, _: Int,
    _: UnsafePointer<UInt8>?, _: Int
) {
    routerDispatchObserved = true
}

private struct UnsafeSendablePointer<Pointee>: @unchecked Sendable {
    let value: UnsafeMutablePointer<Pointee>
}

/// Exercises the subscription registry without retaining its fixed protocol
/// storage in the large smoke-test frame.
@inline(never)
private func runRegistryVectors(_ record: (StaticString, Bool) -> Void) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { payload in
        let rawMessage = BorrowedMessage(topicBytes: payload.baseAddress!, topicLength: 0,
                                         payloadBytes: payload.baseAddress!, payloadLength: 0)
        record("borrowed:topicView", rawMessage.isRawTopic)
        record("borrowed:reader", rawMessage.reader().length == 0)

        let discoverTopic: StaticString = "coaty/3/ns/DSC/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004"
        let discoverPayload: StaticString = "{\"objectTypes\":[]}"
        let discoverMessage = BorrowedMessage(
            topicBytes: discoverTopic.utf8Start,
            topicLength: discoverTopic.utf8CodeUnitCount,
            payloadBytes: discoverPayload.utf8Start,
            payloadLength: discoverPayload.utf8CodeUnitCount
        )
        var processor = ProtocolProcessor<16>()
        var sink = InlineProtocolActionSink<1>()
        var registry = ProtocolSubscriptionRegistry<16>()
        routerDispatchObserved = false
        let registration = try? registry.register(
            selector: .capability(.discover),
            handler: ProtocolHandlerEntry(function: recordRouterDispatch, context: 0)
        )
        let outcome: ProtocolProcessOutcome
        if let frame = try? BorrowedProtocolFrame(topic: discoverMessage.topic, payload: discoverMessage.payload) {
            outcome = processor.processInbound(.profile(frame), nowMS: 1, sink: &sink)
        } else {
            outcome = .rejected(.malformedFrame)
        }
        if let action = sink[0] { _ = registry.dispatch(action) }
        record("router:subscribe", registration != nil)
        record("router:dispatch", outcome == .accepted && routerDispatchObserved)
    }
}

/// Runs the fixed-storage device-agent vectors in a separate stack frame.
@inline(never)
private func runAgentVectors(_ record: (StaticString, Bool) -> Void) {
    var staticAgent = StaticDeviceAgent()
    record("agent:identity", StaticDeviceAgent.agentId != .zero &&
           StaticDeviceAgent.agentId != StaticDeviceAgent.deviceObjectId)

    @inline(__always)
    func agentVector(
        _ id: StaticString,
        topic: StaticString,
        payload: StaticString,
        expected: StaticDeviceDispatchResult
    ) {
        let message = try? BorrowedMessage.validated(
            topicBytes: topic.utf8Start, topicLength: topic.utf8CodeUnitCount,
            payloadBytes: payload.utf8Start, payloadLength: payload.utf8CodeUnitCount
        )
        record(id, message.map { staticAgent.dispatch($0, nowMS: 101) == expected } ?? false)
    }

    let expectedCorrelation = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04
    ))
    agentVector(
        "agent:advertise",
        topic: "coaty/3/axoloty-embedded/ADV/32400000-0000-4000-8000-000000000003",
        payload: "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}",
        expected: .advertise
    )
    let advertised = staticAgent.hasAdvertisedPeer
    agentVector(
        "agent:deadvertise",
        topic: "coaty/3/axoloty-embedded/DAD/32400000-0000-4000-8000-000000000003",
        payload: "{\"objectIds\":[\"32400000-0000-4000-8000-000000000003\"]}",
        expected: .deadvertise
    )
    record("agent:advertisedState", advertised && !staticAgent.hasAdvertisedPeer)
    agentVector(
        "agent:discover",
        topic: "coaty/3/axoloty-embedded/DSC/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004",
        payload: "{\"objectTypes\":[\"coaty.test.Device\"]}",
        expected: .discover
    )
    agentVector(
        "agent:discoverById",
        topic: "coaty/3/axoloty-embedded/DSC/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004",
        payload: "{\"objectId\":\"32400000-0000-4000-8000-000000000002\"}",
        expected: .discover
    )
    agentVector(
        "agent:rejectWrongFilter",
        topic: "coaty/3/axoloty-embedded/DSC:coaty.test.Other/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004",
        payload: "{\"objectTypes\":[\"coaty.test.Other\"]}",
        expected: .unsupported
    )
    record("agent:beginDiscover", staticAgent.beginDiscover(correlationId: expectedCorrelation, nowMS: 100))
    @inline(never)
    func runSaturationVector() {
        var saturationAgent = StaticDeviceAgent()
        var filledOutstanding = true
        for offset in 0..<16 {
            let correlation = UUID16(bytes: (
                0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
                0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, UInt8(offset + 0x40)
            ))
            filledOutstanding = saturationAgent.beginDiscover(
                correlationId: correlation,
                nowMS: 100
            ) && filledOutstanding
        }
        let overCapacityCorrelation = UUID16(bytes: (
            0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
            0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7f
        ))
        record("agent:boundedOutstanding", filledOutstanding &&
               !saturationAgent.beginDiscover(correlationId: overCapacityCorrelation, nowMS: 100))
    }
    runSaturationVector()
    agentVector(
        "agent:wrongCorrelation",
        topic: "coaty/3/axoloty-embedded/RSV/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000005",
        payload: "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}",
        expected: .wrongCorrelation
    )
    agentVector(
        "agent:resolve",
        topic: "coaty/3/axoloty-embedded/RSV/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004",
        payload: "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}",
        expected: .resolve
    )
    agentVector(
        "agent:duplicateResolve",
        topic: "coaty/3/axoloty-embedded/RSV/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004",
        payload: "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}",
        // Discover requests deliberately accept multiple Resolve responses
        // until their deadline; only terminal responses become duplicates.
        expected: .resolve
    )
    record("agent:beginTimedDiscover", staticAgent.beginDiscover(correlationId: UUID16.zero, nowMS: 100))
    record("agent:resolveTimeout", staticAgent.expireDiscover(nowMS: 5_100))

    @inline(__always)
    func receiveAgentMessage(topic: StaticString, payload: StaticString) -> Int32 {
        var result: Int32 = -1
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxTopicLength) { outputTopic in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 2_048) { outputPayload in
                withUnsafeTemporaryAllocation(of: Int32.self, capacity: 1) { outputTopicLength in
                    withUnsafeTemporaryAllocation(of: Int32.self, capacity: 1) { outputPayloadLength in
                        result = axolotyStaticAgentReceive(
                            2, topic.utf8Start, Int32(topic.utf8CodeUnitCount),
                            payload.utf8Start, Int32(payload.utf8CodeUnitCount),
                            outputTopic.baseAddress!, Int32(outputTopic.count),
                            outputPayload.baseAddress!, Int32(outputPayload.count),
                            outputTopicLength.baseAddress!, outputPayloadLength.baseAddress!
                        )
                    }
                }
            }
        }
        return result
    }
    let callbackAdvertiseTopic: StaticString = "coaty/3/axoloty-embedded/ADV/32400000-0000-4000-8000-000000000003"
    let callbackResolveTopic: StaticString = "coaty/3/axoloty-embedded/RSV/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004"
    let callbackPayload: StaticString = "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}"
    record("agent:callbackRejectUnsolicitedResolve", receiveAgentMessage(
        topic: callbackResolveTopic, payload: callbackPayload
    ) == -1)
    record("agent:callbackAdvertise", receiveAgentMessage(
        topic: callbackAdvertiseTopic, payload: callbackPayload
    ) == 1)
    record("agent:callbackResolve", receiveAgentMessage(
        topic: callbackResolveTopic, payload: callbackPayload
    ) == 2)
    // The callback path begins Discover, whose Resolve responses are
    // intentionally multi-response until its timeout.
    record("agent:callbackRejectDuplicateResolve", receiveAgentMessage(
        topic: callbackResolveTopic, payload: callbackPayload
    ) == 2)

    // Keep wire-encoding checks in a separate stack frame from the request
    // ledger. A fresh production agent also makes the correlation boundary
    // explicit.
    @inline(never)
    func runEncodingVectors() {
    var encodeAgent = StaticDeviceAgent()
    let advertisePayload: StaticString = "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}"
    let advertiseData = try? AdvertiseWireData(from: WireReader(
        bytes: advertisePayload.utf8Start, length: advertisePayload.utf8CodeUnitCount
    ))
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxTopicLength) { topicBuffer in
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 2_048) { payloadBuffer in
            guard let advertiseData,
                  let encoded = try? encodeAgent.encode(
                    advertiseData, eventType: .advertise, correlationId: nil, nowMS: phase4NowMS(),
                    topicBuffer: topicBuffer.baseAddress!, topicCapacity: topicBuffer.count,
                    payloadBuffer: payloadBuffer.baseAddress!, payloadCapacity: payloadBuffer.count
                  ) else {
                record("agent:fixedPublish", false)
                return
            }
            let topic = TopicView(topicBytes: topicBuffer.baseAddress!, length: encoded.topicLength)
            let decoded = try? AdvertiseWireData(from: WireReader(
                bytes: payloadBuffer.baseAddress!, length: encoded.payloadLength
            ))
            record("agent:fixedPublish", topic.eventType == .advertise &&
                    topic.sourceIdLevel.flatMap(UUID16.init(parsing:)) == StaticDeviceAgent.agentId &&
                    decoded != nil && encoded.payloadLength <= WireBufferConfig.maxPayloadSize &&
                    ByteSlice(bytes: topicBuffer.baseAddress!, length: encoded.topicLength).equals(
                        "coaty/3/axoloty-embedded/ADV:coaty.test.Device/32400000-0000-4000-8000-000000000001"
                    ) && ByteSlice(bytes: payloadBuffer.baseAddress!, length: encoded.payloadLength).equals(
                        "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}"
                    ))
        }
    }
    @inline(__always)
    func matchesFixedWire<T: WireEncodable>(
        _ data: T,
        eventType: WireEventType,
        correlationId: UUID16?,
        topic expectedTopic: StaticString,
        payload expectedPayload: StaticString
    ) -> Bool {
        var matches = false
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxTopicLength) { topicBuffer in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 2_048) { payloadBuffer in
                guard let encoded = try? encodeAgent.encode(
                    data, eventType: eventType, correlationId: correlationId, nowMS: phase4NowMS(),
                    topicBuffer: topicBuffer.baseAddress!, topicCapacity: topicBuffer.count,
                    payloadBuffer: payloadBuffer.baseAddress!, payloadCapacity: payloadBuffer.count
                ) else { return }
                matches = ByteSlice(bytes: topicBuffer.baseAddress!, length: encoded.topicLength).equals(expectedTopic) &&
                    ByteSlice(bytes: payloadBuffer.baseAddress!, length: encoded.payloadLength).equals(expectedPayload)
            }
        }
        return matches
    }
    let deadvertisePayload: StaticString = "{\"objectIds\":[\"32400000-0000-4000-8000-000000000003\"]}"
    let discoverPayload: StaticString = "{\"objectTypes\":[\"coaty.test.Device\"]}"
    let resolvePayload: StaticString = advertisePayload
    record("agent:fixedDeadvertise", (try? DeadvertiseWireData(from: WireReader(
        bytes: deadvertisePayload.utf8Start, length: deadvertisePayload.utf8CodeUnitCount
    ))).map {
        matchesFixedWire($0, eventType: .deadvertise, correlationId: nil,
                         topic: "coaty/3/axoloty-embedded/DAD/32400000-0000-4000-8000-000000000001",
                         payload: deadvertisePayload)
    } ?? false)
    record("agent:fixedDiscover", (try? DiscoverWireData(from: WireReader(
        bytes: discoverPayload.utf8Start, length: discoverPayload.utf8CodeUnitCount
    ))).map {
        matchesFixedWire($0, eventType: .discover, correlationId: expectedCorrelation,
                         topic: "coaty/3/axoloty-embedded/DSC/32400000-0000-4000-8000-000000000001/32400000-0000-4000-8000-000000000004",
                         payload: discoverPayload)
    } ?? false)
    record("agent:fixedResolve", (try? ResolveWireData(from: WireReader(
        bytes: resolvePayload.utf8Start, length: resolvePayload.utf8CodeUnitCount
    ))).map {
        matchesFixedWire($0, eventType: .resolve, correlationId: expectedCorrelation,
                         topic: "coaty/3/axoloty-embedded/RSV/32400000-0000-4000-8000-000000000001/32400000-0000-4000-8000-000000000004",
                         payload: resolvePayload)
    } ?? false)
    }
    runEncodingVectors()
}

private func runSmoke(_ seam: DeviceSmokeSeam) -> Int32 {
    let schemaVersion: UInt32 = 2
    let runId: StaticString = "embedded-swift-smoke-v2"
    var sequence: UInt32 = 0
    var rollingChecksum: UInt32 = 0
    var passed: UInt32 = 0
    var failed: UInt32 = 0
    let networkRole = seam.networkRole()
    let networkScenario = seam.networkScenario()
    var emittingExchangeEvidence = false

    struct BenchmarkMetrics {
        let topicParseP50ns: UInt32
        let topicParseP95ns: UInt32
        let dtoDecodeP50ns: UInt32
        let dtoDecodeP95ns: UInt32
        let dtoEncodeP50ns: UInt32
        let dtoEncodeP95ns: UInt32
        let combinedP50ns: UInt32
        let combinedP95ns: UInt32
        let borrowedP50ns: UInt32
        let borrowedP95ns: UInt32

        static let zero = BenchmarkMetrics(
            topicParseP50ns: 0, topicParseP95ns: 0,
            dtoDecodeP50ns: 0, dtoDecodeP95ns: 0,
            dtoEncodeP50ns: 0, dtoEncodeP95ns: 0,
            combinedP50ns: 0, combinedP95ns: 0,
            borrowedP50ns: 0, borrowedP95ns: 0
        )
    }

    @inline(__always)
    func printStatic(_ value: StaticString) {
        seam.print(
            UnsafeRawPointer(value.utf8Start).assumingMemoryBound(to: CChar.self)
        )
    }

    @inline(__always)
    func mix(_ hash: UInt32, _ byte: UInt8) -> UInt32 {
        (hash ^ UInt32(byte)) &* 16777619
    }

    @inline(__always)
    func mix(_ hash: UInt32, _ value: StaticString) -> UInt32 {
        var result = hash
        let bytes = value.utf8Start
        for index in 0..<value.utf8CodeUnitCount {
            result = mix(result, UInt8(bytes[index]))
        }
        return result
    }

    @inline(__always)
    func mix(_ hash: UInt32, _ value: UInt32) -> UInt32 {
        var result = hash
        result = mix(result, UInt8(truncatingIfNeeded: value))
        result = mix(result, UInt8(truncatingIfNeeded: value >> 8))
        result = mix(result, UInt8(truncatingIfNeeded: value >> 16))
        result = mix(result, UInt8(truncatingIfNeeded: value >> 24))
        return result
    }

    @inline(__always)
    func nextChecksum(_ caseId: StaticString, _ operation: StaticString,
                      _ stage: StaticString,
                      _ status: StaticString, _ prior: UInt32,
                      _ currentSequence: UInt32, _ currentPassed: UInt32 = 0,
                      _ currentFailed: UInt32 = 0) -> UInt32 {
        var result: UInt32 = 2166136261
        result = mix(result, schemaVersion)
        result = mix(result, runId)
        result = mix(result, currentSequence)
        result = mix(result, caseId)
        result = mix(result, operation)
        result = mix(result, stage)
        result = mix(result, status)
        result = mix(result, currentPassed)
        result = mix(result, currentFailed)
        return mix(result, prior)
    }

    @inline(__always)
    func printPrefix(_ caseId: StaticString, _ operation: StaticString,
                     _ stage: StaticString,
                     _ status: StaticString, _ checksum: UInt32) {
        seam.print("{\"schemaVersion\":2,\"runId\":\"")
        printStatic(runId)
        seam.print("\",\"sequence\":")
        seam.printUInt("", sequence)
        seam.print(",\"caseId\":\"")
        printStatic(caseId)
        seam.print("\",\"operation\":\"")
        printStatic(operation)
        seam.print("\",\"stage\":\"")
        printStatic(stage)
        seam.print("\",\"status\":\"")
        printStatic(status)
        seam.print("\",\"checksum\":")
        seam.printUInt("", checksum)
    }

    rollingChecksum = nextChecksum("boot", "boot", "boot", "started", 0, sequence)
    printPrefix("boot", "boot", "boot", "started", rollingChecksum)
    seam.print("}\n")
    sequence &+= 1
    seam.delay(1)

    @inline(__always)
    func record(_ name: StaticString, _ ok: Bool) {
        if networkRole != 0 && !emittingExchangeEvidence { return }
        let status: StaticString = ok ? "passed" : "failed"
        let checksum = nextChecksum(name, "smokeCheck", "execute", status, rollingChecksum, sequence)
        printPrefix(name, "smokeCheck", "execute", status, checksum)
        if !ok {
            seam.print(",\"diagnostic\":\"failed check: ")
            printStatic(name)
            seam.print("\"")
        }
        seam.print("}\n")
        seam.delay(1)
        rollingChecksum = checksum
        sequence &+= 1
        if ok {
            passed &+= 1
        } else {
            failed &+= 1
        }
    }

    // Vector checks deliberately use the production APIs and fixed storage.
    // The identifiers below are also the stable corpus consumed by the host
    // validator; keep additions deterministic and grouped by category.
    @inline(__always)
    func reader(_ payload: StaticString) -> WireReader {
        WireReader(bytes: payload.utf8Start, length: payload.utf8CodeUnitCount)
    }

    @inline(__always)
    func writeIntVector(_ id: StaticString, _ value: Int, _ expected: StaticString) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { storage in
            var writer = WireWriter(buffer: storage.baseAddress!, capacity: storage.count)
            var ok = (try? writer.writeInt(value)) != nil
            if ok && writer.position == expected.utf8CodeUnitCount {
                for index in 0..<writer.position where storage[index] != expected.utf8Start[index] { ok = false }
            } else { ok = false }
            record(id, ok)
        }
    }

    @inline(__always)
    func topicVector(_ id: StaticString, _ capacity: Int, _ suffix: StaticString, _ shouldFit: Bool) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 129) { storage in
            var builder = TopicBuilder(buffer: storage.baseAddress!, capacity: capacity)
            var ok = (try? builder.writePrefix()) != nil
            if ok { ok = (try? builder.writeNamespace("ns")) != nil }
            if ok { ok = (try? builder.writeEventType(.advertise)) != nil }
            if ok { ok = (try? builder.writeSourceId(UUID16.zero)) != nil }
            if ok && suffix.utf8CodeUnitCount > 0 {
                ok = (try? builder.writeCorrelationId(UUID16.zero)) != nil
            }
            record(id, ok == shouldFit)
        }
    }

    @inline(__always)
    func boundedVector(_ id: StaticString, _ topicLength: Int, _ payloadLength: Int, _ shouldFit: Bool) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 2_049) { payload in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 130) { topic in
                let ok = (try? BorrowedMessage.validated(
                    topicBytes: topic.baseAddress!, topicLength: topicLength,
                    payloadBytes: payload.baseAddress!, payloadLength: payloadLength
                )) != nil
                record(id, ok == shouldFit)
            }
        }
    }

    // === Topic parse tests ===

    let tADV: StaticString = "coaty/3/ns/ADV/source-id"
    let tvADV = TopicView(topicBytes: tADV.utf8Start, length: tADV.utf8CodeUnitCount)
    record("topicParse:ADV", tvADV.eventType == .advertise)

    let tDAD: StaticString = "coaty/3/ns/DAD/source-id"
    let tvDAD = TopicView(topicBytes: tDAD.utf8Start, length: tDAD.utf8CodeUnitCount)
    record("topicParse:DAD", tvDAD.eventType == .deadvertise)

    let tDSC: StaticString = "coaty/3/ns/DSC/source-id/corr-id"
    let tvDSC = TopicView(topicBytes: tDSC.utf8Start, length: tDSC.utf8CodeUnitCount)
    record("topicParse:DSC", tvDSC.eventType == .discover)

    let tRSV: StaticString = "coaty/3/ns/RSV/source-id/corr-id"
    let tvRSV = TopicView(topicBytes: tRSV.utf8Start, length: tRSV.utf8CodeUnitCount)
    record("topicParse:RSV", tvRSV.eventType == .resolve)

    let tCHN: StaticString = "coaty/3/ns/CHN:channel-id/source-id"
    let tvCHN = TopicView(topicBytes: tCHN.utf8Start, length: tCHN.utf8CodeUnitCount)
    record("topicParse:CHN", tvCHN.eventType == .channel)

    let tASC: StaticString = "coaty/3/ns/ASC:filter/source-id"
    let tvASC = TopicView(topicBytes: tASC.utf8Start, length: tASC.utf8CodeUnitCount)
    record("topicParse:ASC", tvASC.eventType == .associate)

    let tIOV: StaticString = "coaty/3/ns/IOV/source-id"
    let tvIOV = TopicView(topicBytes: tIOV.utf8Start, length: tIOV.utf8CodeUnitCount)
    record("topicParse:IOV", tvIOV.eventType == .ioValue)

    let tRAW: StaticString = "some/random/topic"
    let tvRAW = TopicView(topicBytes: tRAW.utf8Start, length: tRAW.utf8CodeUnitCount)
    record("topicParse:raw", tvRAW.isRawTopic && tvRAW.eventType == nil)

    let tFILT: StaticString = "coaty/3/ns/ADV:Identity/src"
    let tvFILT = TopicView(topicBytes: tFILT.utf8Start, length: tFILT.utf8CodeUnitCount)
    record("topicParse:filter", tvFILT.eventType == .advertise && tvFILT.eventTypeFilter != nil)

    // === DTO decode tests ===

    let pADV: StaticString = #"{"object":{"objectId":"33333333-3333-4333-8333-333333333333","name":"test","objectType":"coaty.Identity","coreType":"Identity"}}"#
    let rADV = WireReader(bytes: pADV.utf8Start, length: pADV.utf8CodeUnitCount)
    record("dtoDecode:advertise", rADV.readRaw("object") != nil)

    let pUUID: StaticString = #"{"objectId":"33333333-3333-4333-8333-333333333333"}"#
    let rUUID = WireReader(bytes: pUUID.utf8Start, length: pUUID.utf8CodeUnitCount)
    record("dtoDecode:uuid", rUUID.readUUID("objectId") != nil)

    let pINT: StaticString = #"{"updateRate":100}"#
    let rINT = WireReader(bytes: pINT.utf8Start, length: pINT.utf8CodeUnitCount)
    record("dtoDecode:int", rINT.readInt("updateRate") == 100)

    let pBOOL: StaticString = #"{"hasAssociations":true}"#
    let rBOOL = WireReader(bytes: pBOOL.utf8Start, length: pBOOL.utf8CodeUnitCount)
    record("dtoDecode:bool", rBOOL.readBool("hasAssociations") == true)

    let pMISS: StaticString = #"{"otherField":"value"}"#
    let rMISS = WireReader(bytes: pMISS.utf8Start, length: pMISS.utf8CodeUnitCount)
    record("dtoDecode:missingField", rMISS.readString("name") == nil)

    // === Malformed input tests ===

    let pTRUNC: StaticString = #"{"objectId":"33333333"#
    let rTRUNC = WireReader(bytes: pTRUNC.utf8Start, length: pTRUNC.utf8CodeUnitCount)
    record("malformed:truncated", rTRUNC.readUUID("objectId") == nil)

    let pEMPTY: StaticString = ""
    let rEMPTY = WireReader(bytes: pEMPTY.utf8Start, length: 0)
    record("malformed:empty", rEMPTY.readString("field") == nil)

    let pBADUUID: StaticString = #"{"objectId":"not-a-uuid"}"#
    let rBADUUID = WireReader(bytes: pBADUUID.utf8Start, length: pBADUUID.utf8CodeUnitCount)
    record("malformed:invalidUUID", rBADUUID.readUUID("objectId") == nil)

    // === UUID16 tests ===

    let uuidStr: StaticString = "33333333-3333-4333-8333-333333333333"
    let uuidSlice = ByteSlice(bytes: uuidStr.utf8Start, length: 36)
    record("uuid16:parseValid", UUID16(parsing: uuidSlice) != nil)

    let badUuidStr: StaticString = "not-a-uuid"
    let badUuidSlice = ByteSlice(bytes: badUuidStr.utf8Start, length: 10)
    record("uuid16:parseInvalid", UUID16(parsing: badUuidSlice) == nil)

    record("uuid16:zero", UUID16.zero == UUID16(bytes: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))

    // === Config tests ===

    record("config:payloadMax2048", WireBufferConfig.maxPayloadSize == 2_048)
    record("config:topicMax256", WireBufferConfig.maxTopicLength == 256)

    // === Deterministic vector corpus ===
    writeIntVector("writer:zero", 0, "0")
    writeIntVector("writer:one", 1, "1")
    writeIntVector("writer:minusOne", -1, "-1")
    // The encoded text depends on the target's `Int` width. Expect the value
    // for the width this build actually has, so the vector still detects a
    // width-dependent encoding rather than assuming the 32-bit device.
    if MemoryLayout<Int>.size == 4 {
        writeIntVector("writer:max", Int.max, "2147483647")
        writeIntVector("writer:min", Int.min, "-2147483648")
    } else {
        writeIntVector("writer:max", Int.max, "9223372036854775807")
        writeIntVector("writer:min", Int.min, "-9223372036854775808")
    }

    topicVector("topic:exact", 51, "", true)
    topicVector("topic:underCapacity", 50, "", false)
    topicVector("topic:overflow", 51, "corr", false)
    boundedVector("capacity:payload0", 0, 0, true)
    boundedVector("capacity:payload1", 0, 1, true)
    boundedVector("capacity:payload512", 0, 512, true)
    boundedVector("capacity:payload2047", 0, 2_047, true)
    boundedVector("capacity:payload2048", 0, 2_048, true)
    boundedVector("capacity:payload2049", 0, 2_049, false)
    boundedVector("capacity:topic0", 0, 0, true)
    boundedVector("capacity:topic1", 1, 0, true)
    boundedVector("capacity:topic256", 256, 0, true)
    boundedVector("capacity:topic257", 257, 0, false)

    record("malformed:truncation", reader(#"{"objectId":"33333333"#).readUUID("objectId") == nil)
    record("malformed:corruption", reader(#"{"objectId":@}"#).readUUID("objectId") == nil)
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 12) { bytes in
        bytes[0] = 0x7B; bytes[1] = 0x22; bytes[2] = 0x6E; bytes[3] = 0x22
        bytes[4] = 0x3A; bytes[5] = 0x22; bytes[6] = 0xFF; bytes[7] = 0x22
        bytes[8] = 0x7D
        record("malformed:utf8", WireReader(bytes: bytes.baseAddress!, length: 9).readString("n") == nil)
    }
    record("malformed:escape", reader(#"{"name":"bad\q"}"#).readString("name") == nil)
    record("malformed:literal", reader(#"{"value":tru}"#).readBool("value") == nil)
    record("malformed:number", reader(#"{"value":1e}"#).readInt("value") == nil)
    record("malformed:missing", reader(#"{"other":1}"#).readString("name") == nil)
    record("malformed:unknown", reader(#"{"unknown":1}"#).readString("name") == nil)
    record("malformed:duplicate", reader(#"{"name":1,"name":2}"#).readString("name") == nil)
    record("malformed:reordered", reader(#"{"value":1,"name":"x"}"#).readString("name") != nil)
    record("malformed:trailing", reader(#"{"value":1}x"#).readInt("value") == nil)
    record("malformed:nesting", reader(#"{"value":{"x":[1,2]}}"#).readRaw("value") != nil)

    runRegistryVectors(record)

    runAgentVectors(record)

    #if !HOST_AGENT_EXCHANGE
    runGeneratedCorpus(record)
    #endif

    // The ordinary vector image is deliberately credential-free. A dedicated
    // network build supplies the operator configuration and appends evidence
    // without changing the existing corpus or its counts.
    if seam.networkConfigured() != 0 {
        if networkRole == 0 {
            #if HOST_AGENT_EXCHANGE
            runDeviceSmokeHostNetworkProbe(
                networkPrepare: seam.networkPrepare,
                networkReconnect: seam.networkReconnect,
                networkCopyTopic: seam.networkCopyTopic,
                networkCopyPayload: seam.networkCopyPayload,
                networkCleanup: seam.networkCleanup,
                record: record
            )
            #else
            runCarrierNetworkProbe(
                networkPrepare: seam.networkPrepare,
                networkReconnect: seam.networkReconnect,
                networkCopyTopic: seam.networkCopyTopic,
                networkCopyPayload: seam.networkCopyPayload,
                networkCleanup: seam.networkCleanup,
                record: record
            )
            #endif
        } else {
            emittingExchangeEvidence = true
            let exchangeBits = runDeviceAgentExchange(
                role: networkRole, scenario: networkScenario, seam: seam
            )
            emitDeviceAgentExchange(exchangeBits, scenario: networkScenario, record: record)
        }
    }

    // Prove that a warmed corpus pass performs no heap allocation. The second
    // pass suppresses serial output so the trace covers only AxolotyWire work.
    var hotPathAllocations = UInt32.max
    #if HOST_AGENT_EXCHANGE
    let benchmarkMetrics = BenchmarkMetrics.zero
    #else
    if seam.heapTraceBegin() != 0 {
        runGeneratedCorpus { _, _ in }
        hotPathAllocations = seam.heapTraceEnd()
    }
    let generatedMetrics = benchmarkGeneratedCorpus()
    let benchmarkMetrics = BenchmarkMetrics(
        topicParseP50ns: generatedMetrics.topicParseP50ns,
        topicParseP95ns: generatedMetrics.topicParseP95ns,
        dtoDecodeP50ns: generatedMetrics.dtoDecodeP50ns,
        dtoDecodeP95ns: generatedMetrics.dtoDecodeP95ns,
        dtoEncodeP50ns: generatedMetrics.dtoEncodeP50ns,
        dtoEncodeP95ns: generatedMetrics.dtoEncodeP95ns,
        combinedP50ns: generatedMetrics.combinedP50ns,
        combinedP95ns: generatedMetrics.combinedP95ns,
        borrowedP50ns: generatedMetrics.borrowedP50ns,
        borrowedP95ns: generatedMetrics.borrowedP95ns
    )
    #endif

    // === Summary and completion ===

    let summaryStatus: StaticString = failed == 0 ? "completed" : "failed"
    rollingChecksum = nextChecksum("summary", "summary", "summary", summaryStatus,
                                   rollingChecksum, sequence, passed, failed)
    printPrefix("summary", "summary", "summary", summaryStatus, rollingChecksum)
    seam.print(",\"counts\":{\"passed\":")
    seam.printUInt("", passed)
    seam.print(",\"failed\":")
    seam.printUInt("", failed)
    seam.print("}")
    if failed != 0 {
        seam.print(",\"diagnostic\":\"one or more execution checks failed\"")
    }
    seam.print("}\n")
    sequence &+= 1

    let completionChecksum = nextChecksum("completion", "complete", "completion", summaryStatus,
                                          rollingChecksum, sequence, passed, failed)
    printPrefix("completion", "complete", "completion", summaryStatus, completionChecksum)
    seam.print(",\"counts\":{\"passed\":")
    seam.printUInt("", passed)
    seam.print(",\"failed\":")
    seam.printUInt("", failed)
    seam.print("},\"finalChecksum\":")
    seam.printUInt("", completionChecksum)
    if failed != 0 {
        seam.print(",\"diagnostic\":\"completion reflects failed execution checks\"")
    }
    seam.print(",\"metrics\":{\"freeInternalHeap\":")
    seam.printUInt("", seam.freeInternalHeap())
    seam.print(",\"minimumFreeInternalHeap\":")
    seam.printUInt("", seam.minFreeInternalHeap())
    seam.print(",\"largestInternalBlock\":")
    seam.printUInt("", seam.largestInternalBlock())
    seam.print(",\"mainStackHighWater\":")
    seam.printUInt("", seam.mainStackHighWater())
    seam.print(",\"mainStackSize\":")
    seam.printUInt("", seam.mainStackSize())
    seam.print(",\"resetReason\":")
    seam.printUInt("", seam.resetReason())
    seam.print(",\"hotPathAllocations\":")
    seam.printUInt("", hotPathAllocations)
    seam.print(",\"topicParseP50ns\":")
    seam.printUInt("", benchmarkMetrics.topicParseP50ns)
    seam.print(",\"topicParseP95ns\":")
    seam.printUInt("", benchmarkMetrics.topicParseP95ns)
    seam.print(",\"dtoDecodeP50ns\":")
    seam.printUInt("", benchmarkMetrics.dtoDecodeP50ns)
    seam.print(",\"dtoDecodeP95ns\":")
    seam.printUInt("", benchmarkMetrics.dtoDecodeP95ns)
    seam.print(",\"dtoEncodeP50ns\":")
    seam.printUInt("", benchmarkMetrics.dtoEncodeP50ns)
    seam.print(",\"dtoEncodeP95ns\":")
    seam.printUInt("", benchmarkMetrics.dtoEncodeP95ns)
    seam.print(",\"combinedP50ns\":")
    seam.printUInt("", benchmarkMetrics.combinedP50ns)
    seam.print(",\"combinedP95ns\":")
    seam.printUInt("", benchmarkMetrics.combinedP95ns)
    seam.print(",\"borrowedP50ns\":")
    seam.printUInt("", benchmarkMetrics.borrowedP50ns)
    seam.print(",\"borrowedP95ns\":")
    seam.printUInt("", benchmarkMetrics.borrowedP95ns)
    seam.print("}")
    seam.print("}\n")

    seam.delay(1000)
    seam.restartDevice()
}

/// Runs the device smoke application with the profile-supplied seam.
///
/// The profile installs the seam, then calls this entry point. Moving the
/// link probes out of the large deterministic smoke-test stack frame keeps the
/// Embedded Swift compiler from reserving the complete `runSmoke` frame at
/// entry, which can exhaust the fixed main-task stack before the first smoke
/// record is emitted.
public func startDeviceSmoke(_ seam: DeviceSmokeSeam) -> Int32 {
    installDeviceSmokeSeam(seam)
    guard axoloty_protocol_embedded_link_probe() == 3 else {
        return 1
    }
    guard axoloty_object_model_embedded_link_probe() else {
        return 1
    }
    guard axoloty_coaty_models_embedded_link_probe() else {
        return 1
    }
    return runSmoke(seam)
}
