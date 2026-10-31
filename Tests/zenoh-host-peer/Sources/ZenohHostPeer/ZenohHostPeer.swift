// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyWire
import AxolotyZenoh
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The host peer for the embedded↔host check on the Zenoh profile.
///
/// This is the `axoloty/1` counterpart of `EmbeddedHostPeer`. It runs the Core host
/// runtime over `ZenohBinding` and reads the device's CBOR frames through the same
/// `AxolotyWire` codec the firmware writes them with.
///
/// Environment:
/// - `WIRE_EMBEDDED_HOST_DIRECTION`: `host-requester` or `host-responder`.
/// - `WIRE_ZENOH_ENDPOINT`: the router, for example `tcp/192.0.2.1:7447`.
/// - `WIRE_NAMESPACE`: optional; default `axoloty-embedded`.
/// - `WIRE_READY_FILE`: written once the runtime has started and subscribed.
/// - `WIRE_PEER_TIMEOUT_SECONDS`: optional; whole-run limit, default 180.
@main
struct ZenohHostPeer {
    static let hostID = UUID16(parsing: "32400000-0000-4000-8000-000000000003")!
    static let embeddedAgentID = UUID16(parsing: "32400000-0000-4000-8000-000000000001")!
    static let embeddedRequesterID = UUID16(parsing: "32400000-0000-4000-8000-00000000000b")!
    static let embeddedObjectID = UUID16(parsing: "32400000-0000-4000-8000-000000000002")!
    static let correlationID = UUID16(parsing: "32400000-0000-4000-8000-000000000004")!
    static let objectType = "coaty.test.Device"

    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let limit = UInt64(environment["WIRE_PEER_TIMEOUT_SECONDS"] ?? "") ?? 180
        // One whole-run limit keeps each step a plain stream read.
        Task.detached {
            try? await Task.sleep(for: .seconds(limit))
            fail("timed out after \(limit) seconds")
        }
        do throws(PeerFailure) {
            switch environment["WIRE_EMBEDDED_HOST_DIRECTION"] {
            case "host-requester":
                try await hostDiscoversEmbeddedAgent(environment)
            case "host-responder":
                try await embeddedAgentDiscoversHost(environment)
            default:
                fail("WIRE_EMBEDDED_HOST_DIRECTION must be host-requester or host-responder")
            }
        } catch {
            fail(error.description)
        }
    }

    static func hostDiscoversEmbeddedAgent(_ environment: [String: String]) async throws(PeerFailure) {
        let (runtime, streams) = try makeRuntime(environment, selectors: [
            // The runtime advertises its own identity on start, so select the
            // device object type rather than the whole Advertise family.
            .advertise(objectType: objectType),
            .correlatedResponse(capability: .resolve, correlationID: correlationID),
            .family(.deadvertise),
        ])
        try await start(runtime)
        try signalReadiness(environment)
        trace("host-requester ready")

        let advertise = try await next(streams[0], label: "embedded Advertise")
        try expect(advertise.context.sourceID == embeddedAgentID, "embedded Advertise sourceID")
        try expectDevice(advertise.value)
        trace("embedded Advertise received")

        let receipt = await runtime.request(.discover(
            correlationID: correlationID, payload: try discoverPayload(), timeoutMS: 60_000
        ))
        try expect(receipt == .accepted, "embedded Discover receipt \(receipt)")

        let resolve = try await next(streams[1], label: "embedded Resolve")
        try expect(resolve.context.sourceID == embeddedAgentID, "embedded Resolve sourceID")
        try expect(resolve.context.correlationID == correlationID, "embedded Resolve correlationID")
        try expectDevice(resolve.value)
        trace("embedded Resolve received")

        let deadvertise = try await next(streams[2], label: "embedded Deadvertise")
        try expect(deadvertise.context.sourceID == embeddedAgentID, "embedded Deadvertise sourceID")
        try expect(deadvertise.value == (try deadvertisePayload()), "embedded Deadvertise bytes")
        trace("embedded Deadvertise received")

        emitPassed("host-requester")
        await runtime.stop()
    }

    static func embeddedAgentDiscoversHost(_ environment: [String: String]) async throws(PeerFailure) {
        let (runtime, streams) = try makeRuntime(environment, selectors: [
            .family(.discover), .family(.deadvertise),
        ])
        try await start(runtime)
        try signalReadiness(environment)
        trace("host-responder ready")

        let device = try devicePayload()
        let advertiser = Task { [runtime] in
            while !Task.isCancelled {
                guard await runtime.publish(.advertise(device)) == .accepted else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }

        let discover = try await next(streams[0], label: "embedded Discover")
        advertiser.cancel()
        await advertiser.value
        try expect(discover.context.sourceID == embeddedRequesterID, "embedded Discover sourceID")
        try expect(discover.context.correlationID == correlationID, "embedded Discover correlationID")
        trace("embedded Discover received")

        let receipt = await runtime.respond(.resolve(correlationID: correlationID, payload: device))
        try expect(receipt == .accepted, "embedded Discover response receipt \(receipt)")
        let deadvertiseReceipt = await runtime.publish(.deadvertise(try deadvertisePayload()))
        try expect(deadvertiseReceipt == .accepted, "host Deadvertise receipt")

        // Acceptance queues the operation, and stop() discards pending outbound
        // effects, so wait for the session's own copy of the final frame.
        let echo = try await next(streams[1], label: "host Deadvertise echo")
        try expect(echo.context.sourceID == hostID, "host Deadvertise echo sourceID")
        trace("host Deadvertise echo received")

        emitPassed("host-responder")
        await runtime.stop()
    }

    static func makeRuntime(
        _ environment: [String: String],
        selectors: [RuntimeEventSelector]
    ) throws(PeerFailure) -> (AxolotyRuntime, [RuntimeEventStream]) {
        guard let endpoint = environment["WIRE_ZENOH_ENDPOINT"] else {
            throw PeerFailure(detail: "WIRE_ZENOH_ENDPOINT is required; the router is never guessed")
        }
        // Core's host composition API throws untyped errors; this is the typed boundary.
        do {
            let identity = try RuntimeIdentity(id: hostID, name: "axoloty-embedded-host")
            var builder = try RuntimeBuilder(
                identity: identity,
                namespace: environment["WIRE_NAMESPACE"] ?? "axoloty-embedded"
            )
            var streams = [RuntimeEventStream]()
            for selector in selectors {
                streams.append(try builder.events(matching: selector, buffering: .failAfterDrop(capacity: 8)))
            }
            let binding = ZenohBinding(configuration: try ZenohBindingConfiguration(connectEndpoint: endpoint))
            return (AxolotyRuntime(definition: try builder.finish(), transport: binding), streams)
        } catch {
            throw PeerFailure(detail: "runtime composition failed: \(error)")
        }
    }

    static func start(_ runtime: AxolotyRuntime) async throws(PeerFailure) {
        do {
            try await runtime.start()
        } catch {
            throw PeerFailure(detail: "runtime start failed: \(error)")
        }
    }

    // MARK: - Wire shapes (the device firmware writes the same CBOR)

    static func devicePayload() throws(PeerFailure) -> [UInt8] {
        let object = try cbor { writer throws(WireEncodeError) in
            try writer.beginObject()
            try writer.writeStringField("coreType", slice("CoatyObject"))
            try writer.writeUUIDField("objectId", embeddedObjectID)
            try writer.writeStringField("objectType", slice("coaty.test.Device"))
            try writer.writeStringField("name", slice("axoloty-embedded-host"))
            try writer.endObject()
        }
        return try envelope("object", object)
    }

    static func discoverPayload() throws(PeerFailure) -> [UInt8] {
        // array(1), text(17)
        try envelope("objectTypes", [0x81, 0x71] + Array(objectType.utf8))
    }

    static func deadvertisePayload() throws(PeerFailure) -> [UInt8] {
        let objectIDs = try cbor { writer throws(WireEncodeError) in
            try writer.beginArray()
            try writer.writeUUIDValue(embeddedObjectID)
            try writer.endArray()
        }
        return try envelope("objectIds", objectIDs)
    }

    static func envelope(_ key: StaticString, _ field: [UInt8]) throws(PeerFailure) -> [UInt8] {
        try cbor { writer throws(WireEncodeError) in
            try writer.beginObject()
            try field.withUnsafeBufferPointer { bytes throws(WireEncodeError) in
                try writer.writeRawField(key, ByteSlice(bytes: bytes.baseAddress!, length: bytes.count))
            }
            try writer.endObject()
        }
    }

    static func cbor(
        _ body: (inout WireWriter) throws(WireEncodeError) -> Void
    ) throws(PeerFailure) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 256)
        do throws(WireEncodeError) {
            let count = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) in
                var writer = WireCodec(profile: .axoloty1CBOR)
                    .writer(buffer: buffer.baseAddress!, capacity: buffer.count)
                try body(&writer)
                return writer.position
            }
            return Array(output.prefix(count))
        } catch {
            throw PeerFailure(detail: "CBOR encoding failed: \(error)")
        }
    }

    static func slice(_ text: StaticString) -> ByteSlice {
        ByteSlice(bytes: text.utf8Start, length: text.utf8CodeUnitCount)
    }

    /// Checks the Advertise or Resolve object through the production CBOR reader.
    static func expectDevice(_ payload: [UInt8]) throws(PeerFailure) {
        let codec = WireCodec(profile: .axoloty1CBOR)
        let matched = payload.withUnsafeBufferPointer { bytes -> Bool in
            let envelope = codec.reader(bytes: bytes.baseAddress!, length: bytes.count)
            guard (try? envelope.validate()) != nil, let object = envelope.readField("object") else { return false }
            return object.withBytes { pointer, length in
                let reader = codec.reader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: length)
                return reader.readUUID("objectId") == embeddedObjectID
                    && reader.readString("objectType")?.equals("coaty.test.Device") == true
            }
        }
        try expect(matched, "Advertise/Resolve object")
    }

    static func next(_ stream: RuntimeEventStream, label: String) async throws(PeerFailure) -> RuntimeEventValue {
        var iterator = stream.makeAsyncIterator()
        guard let value = await iterator.next() else {
            throw PeerFailure(detail: "the \(label) stream ended")
        }
        return value
    }

    static func signalReadiness(_ environment: [String: String]) throws(PeerFailure) {
        guard let path = environment["WIRE_READY_FILE"] else { return }
        do {
            try Data("ready\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw PeerFailure(detail: "cannot write WIRE_READY_FILE: \(error)")
        }
    }

    static func expect(_ condition: Bool, _ label: String) throws(PeerFailure) {
        if !condition { throw PeerFailure(detail: "unexpected \(label)") }
    }

    static func trace(_ message: String) {
        FileHandle.standardError.write(Data("step: \(message)\n".utf8))
    }

    static func emitPassed(_ direction: String) {
        trace("{\"state\":\"passed\",\"direction\":\"\(direction)\"}")
    }

    static func fail(_ detail: String) -> Never {
        FileHandle.standardError.write(Data("error: \(detail)\n".utf8))
        exit(1)
    }
}

struct PeerFailure: Error, CustomStringConvertible {
    let detail: String
    var description: String { detail }
}
