// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyMQTT
import AxolotyProtocol
import AxolotyWire
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The host peer for the embedded↔host interoperability check.
///
/// This is the migrated host half of the pre-split live test, run as its own
/// executable so the check builds from a pinned Axoloty dependency instead of
/// invoking `swift test` inside a Core checkout. Behavior and wire shapes are
/// unchanged from the original test.
///
/// Environment:
/// - `WIRE_EMBEDDED_HOST_DIRECTION`: `host-requester` or `host-responder`.
/// - `WIRE_BROKER_HOST`, `WIRE_BROKER_PORT`: broker reachability.
/// - `WIRE_NAMESPACE`: optional; default `axoloty-embedded`.
/// - `WIRE_READY_FILE`: written once the runtime has started and subscribed.
@main
@MainActor
struct EmbeddedHostPeer {
    static let hostID = UUID16(parsing: "32400000-0000-4000-8000-000000000003")!
    static let embeddedAgentID = UUID16(parsing: "32400000-0000-4000-8000-000000000001")!
    static let embeddedRequesterID = UUID16(parsing: "32400000-0000-4000-8000-00000000000b")!
    static let embeddedObjectID = "32400000-0000-4000-8000-000000000002"
    static let correlationID = UUID16(parsing: "32400000-0000-4000-8000-000000000004")!
    static let objectType = "coaty.test.Device"

    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        do {
            switch environment["WIRE_EMBEDDED_HOST_DIRECTION"] {
            case "host-requester":
                try await hostDiscoversEmbeddedAgent(environment)
            case "host-responder":
                try await embeddedAgentDiscoversHost(environment)
            default:
                throw HostPeerError.usage(
                    "WIRE_EMBEDDED_HOST_DIRECTION must be host-requester or host-responder"
                )
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(String(reflecting: error))\n".utf8))
            exit(1)
        }
    }

    static func trace(_ message: String) {
        FileHandle.standardError.write(Data("step: \(message)\n".utf8))
    }

    static func hostDiscoversEmbeddedAgent(_ environment: [String: String]) async throws {
        let (runtime, advertiseStream, resolveStream, deadvertiseStream) = try makeRuntime(
            environment: environment,
            selectors: [
                // The runtime publishes a lifecycle Advertise for its own
                // identity (`coaty.Identity`) on start. `.family(.advertise)`
                // matches that too, so select the device object type instead;
                // the bare family selector would consume the host's own
                // Advertise before the embedded one arrives.
                .advertise(objectType: objectType),
                .correlatedResponse(capability: .resolve, correlationID: correlationID),
                .family(.deadvertise),
            ]
        )
        do {
            try await runtime.start()
            try signalReadiness(environment)
            trace("host-requester ready")

            guard let advertiseStream else { throw HostPeerError.missingStream("Advertise") }
            let advertise = try await nextHostValue(
                advertiseStream.makeAsyncIterator(), label: "embedded Advertise", runtime: runtime
            )
            trace("embedded Advertise received")
            try expectDevice(advertise.value)
            guard advertise.context.sourceID == embeddedAgentID else {
                throw HostPeerError.mismatch("embedded Advertise sourceID")
            }

            let receipt = await runtime.request(.discover(
                correlationID: correlationID,
                payload: discoverPayload,
                timeoutMS: 60_000
            ))
            guard receipt == .accepted else {
                throw HostPeerError.mismatch("embedded Discover receipt \(receipt)")
            }

            guard let resolveStream else { throw HostPeerError.missingStream("Resolve") }
            let resolveIterator = resolveStream.makeAsyncIterator()
            let resolve = try await nextHostValue(
                resolveIterator, label: "embedded Resolve", runtime: runtime
            )
            guard resolve.context.sourceID == embeddedAgentID else {
                throw HostPeerError.mismatch("embedded Resolve sourceID")
            }
            guard resolve.context.correlationID == correlationID else {
                throw HostPeerError.mismatch("embedded Resolve correlationID")
            }
            try expectDevice(resolve.value)
            trace("embedded Resolve received")

            guard let deadvertiseStream else { throw HostPeerError.missingStream("Deadvertise") }
            let deadvertiseIterator = deadvertiseStream.makeAsyncIterator()
            let deadvertise = try await nextHostValue(
                deadvertiseIterator, label: "embedded Deadvertise", runtime: runtime
            )
            guard deadvertise.context.sourceID == embeddedAgentID else {
                throw HostPeerError.mismatch("embedded Deadvertise sourceID")
            }
            try expectObjectIDs(deadvertise.value)
            trace("embedded Deadvertise received")

            emitState("host-requester", sourceID: embeddedAgentID)
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }

    static func embeddedAgentDiscoversHost(_ environment: [String: String]) async throws {
        let (runtime, discoverStream, _, _) = try makeRuntime(
            environment: environment,
            selectors: [.family(.discover)]
        )
        var advertiser: Task<Void, Never>?
        do {
            try await runtime.start()
            try signalReadiness(environment)
            trace("host-responder ready")

            // Advertise after the runtime is running: a publish issued before
            // start is not accepted, and the advertiser loop would exit
            // without ever advertising the object the device must discover.
            advertiser = Task { [runtime] in
                while !Task.isCancelled {
                    guard await runtime.publish(.advertise(devicePayload)) == .accepted else { return }
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                }
            }

            guard let discoverStream else { throw HostPeerError.missingStream("Discover") }
            let discoverIterator = discoverStream.makeAsyncIterator()
            let discover = try await nextHostValue(
                discoverIterator, label: "embedded Discover", runtime: runtime
            )
            guard discover.context.sourceID == embeddedRequesterID else {
                throw HostPeerError.mismatch("embedded Discover sourceID")
            }
            guard discover.context.correlationID == correlationID else {
                throw HostPeerError.mismatch("embedded Discover correlationID")
            }
            trace("embedded Discover received")
            let receipt = await runtime.respond(.resolve(
                correlationID: correlationID,
                payload: devicePayload
            ))
            guard receipt == .accepted else {
                throw HostPeerError.mismatch("embedded Discover response receipt \(receipt)")
            }
            guard await runtime.publish(.deadvertise(deadvertisePayload)) == .accepted else {
                throw HostPeerError.mismatch("host Deadvertise publish receipt")
            }
            emitState("host-responder", sourceID: embeddedRequesterID)

            advertiser?.cancel()
            await advertiser?.value
            await runtime.stop()
        } catch {
            advertiser?.cancel()
            await advertiser?.value
            await runtime.stop()
            throw error
        }
    }

    static func makeRuntime(
        environment: [String: String],
        selectors: [RuntimeEventSelector]
    ) throws -> (AxolotyRuntime, RuntimeEventStream?, RuntimeEventStream?, RuntimeEventStream?) {
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "axoloty-embedded"
        let identity = try RuntimeIdentity(id: hostID, name: "axoloty-embedded-host")
        var builder = try RuntimeBuilder(identity: identity, namespace: namespace)
        var streams = [RuntimeEventStream]()
        for selector in selectors {
            streams.append(try builder.events(
                matching: selector,
                buffering: RuntimeBufferingPolicy.failAfterDrop(capacity: 8)
            ))
        }
        let definition = try builder.finish()
        let binding = try MQTTBinding(
            configuration: try MQTTBindingConfiguration(host: host, port: port)
        )
        return (
            AxolotyRuntime(definition: definition, transport: binding),
            streams.indices.contains(0) ? streams[0] : nil,
            streams.indices.contains(1) ? streams[1] : nil,
            streams.indices.contains(2) ? streams[2] : nil
        )
    }

    // MARK: - Wire shapes (frozen; the device firmware matches these)

    static var devicePayload: [UInt8] {
        Array("{\"object\":{\"coreType\":\"CoatyObject\",\"objectType\":\"\(objectType)\",\"objectId\":\"\(embeddedObjectID)\",\"name\":\"ESP32-C6 A\"}}".utf8)
    }

    static var discoverPayload: [UInt8] {
        Array("{\"objectTypes\":[\"\(objectType)\"]}".utf8)
    }

    static var deadvertisePayload: [UInt8] {
        Array("{\"objectIds\":[\"\(embeddedObjectID)\"]}".utf8)
    }

    static func expectDevice(_ payload: [UInt8]) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any],
              let object = root["object"] as? [String: Any] else {
            throw HostPeerError.mismatch("Advertise/Resolve payload object")
        }
        guard object["objectId"] as? String == embeddedObjectID else {
            throw HostPeerError.mismatch("objectId \(object["objectId"] ?? "nil")")
        }
        guard object["objectType"] as? String == objectType else {
            throw HostPeerError.mismatch("objectType \(object["objectType"] ?? "nil")")
        }
    }

    static func expectObjectIDs(_ payload: [UInt8]) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any],
              let objectIDs = root["objectIds"] as? [String] else {
            throw HostPeerError.mismatch("Deadvertise payload objectIds")
        }
        guard objectIDs.contains(embeddedObjectID) else {
            throw HostPeerError.mismatch("Deadvertise objectIds missing \(embeddedObjectID)")
        }
    }

    static func nextHostValue(
        _ iterator: AsyncStream<RuntimeEventValue>.Iterator,
        label: String,
        runtime: AxolotyRuntime
    ) async throws -> RuntimeEventValue {
        do {
            return try await nextValue(iterator, timeout: .seconds(60))
        } catch {
            let state = await runtime.state()
            let diagnostics = await runtime.diagnosticsSnapshot()
            throw AxolotyError.runtime(
                code: .timedOut,
                reason: "Timed out waiting for \(label); state=\(state); diagnostics=\(diagnostics); cause=\(error)"
            )
        }
    }

    static func signalReadiness(_ environment: [String: String]) throws {
        guard let path = environment["WIRE_READY_FILE"] else { return }
        try Data("ready\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func emitState(_ direction: String, sourceID: UUID16) {
        let line = "{\"state\":\"passed\",\"direction\":\"\(direction)\",\"sourceId\":\"\(sourceID)\"}"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

enum HostPeerError: Error, CustomStringConvertible {
    case usage(String)
    case missingStream(String)
    case mismatch(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .missingStream(let name): return "the \(name) stream was not configured"
        case .mismatch(let detail): return "unexpected \(detail)"
        }
    }
}

// MARK: - Timeout-raced stream read
//
// Ported from the pre-split `nextValue(_:timeout:)` test helper so the peer
// carries no dependency on Core's test support. The box keeps the
// non-`Sendable` iterator out of the racing task, and the result box resolves
// the first outcome atomically.

private enum NextValueResolution<Value: Sendable>: Sendable {
    case operation(Result<Value, Error>)
    case timeout
    case cancelled
}

private final class NextValueResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NextValueResolution<Value>, Never>?
    private var resolution: NextValueResolution<Value>?

    func resolve(_ resolution: NextValueResolution<Value>) {
        lock.lock()
        if let continuation, self.resolution == nil {
            self.resolution = resolution
            lock.unlock()
            continuation.resume(returning: resolution)
            return
        }
        if self.resolution == nil { self.resolution = resolution }
        lock.unlock()
    }

    func wait() async -> NextValueResolution<Value> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let resolution {
                lock.unlock()
                continuation.resume(returning: resolution)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

private final class NextValueStreamBox<Element: Sendable>: @unchecked Sendable {
    var iterator: AsyncStream<Element>.Iterator
    init(_ iterator: AsyncStream<Element>.Iterator) { self.iterator = iterator }
}

@MainActor
private func nextValue<E: Sendable>(
    _ iterator: AsyncStream<E>.Iterator,
    timeout: Duration
) async throws -> E {
    try Task.checkCancellation()
    let box = NextValueStreamBox(iterator)
    let resultBox = NextValueResultBox<E>()
    let operationTask = Task {
        guard let value = await box.iterator.next() else {
            resultBox.resolve(.operation(.failure(CancellationError())))
            return
        }
        resultBox.resolve(.operation(.success(value)))
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    let timeoutTask = Task {
        do {
            try await clock.sleep(until: deadline)
            resultBox.resolve(.timeout)
        } catch {
            // The operation won the race, or the parent task was cancelled.
        }
    }

    let resolution = await withTaskCancellationHandler(operation: {
        await resultBox.wait()
    }, onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
        resultBox.resolve(.cancelled)
    })

    timeoutTask.cancel()
    switch resolution {
    case let .operation(result):
        operationTask.cancel()
        await operationTask.value
        return try result.get()
    case .timeout:
        operationTask.cancel()
        throw HostPeerError.mismatch("timed out after \(timeout)")
    case .cancelled:
        operationTask.cancel()
        throw CancellationError()
    }
}
