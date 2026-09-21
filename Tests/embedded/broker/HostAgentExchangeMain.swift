// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyTestBroker
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Owns the broker lifecycle for the hardware-free agent exchange.
///
/// The parent process controls this executable through files in one private
/// directory. The broker binds an ephemeral port, and `inject-disconnect`
/// closes the named client without MQTT DISCONNECT so its last will is emitted.
@main
struct HostAgentExchangeMain {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        let readyFile = URL(fileURLWithPath: required(environment, "HOST_AGENT_BROKER_READY_FILE"))
        let controlDirectory = URL(fileURLWithPath: required(environment, "HOST_AGENT_BROKER_CONTROL_DIR"))
        let host = environment["HOST_AGENT_BROKER_HOST"] ?? "127.0.0.1"
        let requestedPort = Int(environment["HOST_AGENT_BROKER_PORT"] ?? "0") ?? 0
        let clientID = environment["HOST_AGENT_CLIENT_ID"] ?? "axoloty-host-smoke-agent"

        do {
            try FileManager.default.createDirectory(
                at: controlDirectory, withIntermediateDirectories: true
            )
            let broker = TestMQTTBroker(configuration: .init(host: host, port: requestedPort))
            let port = try broker.start()
            try Data("\(port)\n".utf8).write(to: readyFile, options: .atomic)
            runControlLoop(
                broker: broker,
                controlDirectory: controlDirectory,
                clientID: clientID
            )
            broker.stop()
        } catch {
            FileHandle.standardError.write(Data("broker harness failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func runControlLoop(
        broker: TestMQTTBroker,
        controlDirectory: URL,
        clientID: String
    ) {
        let commandFile = controlDirectory.appendingPathComponent("command")
        let injectedFile = controlDirectory.appendingPathComponent("injected")
        let willObservedFile = controlDirectory.appendingPathComponent("will-observed")
        var publishedFrameCountBeforeInjection: Int?
        while true {
            if let command = try? String(contentsOf: commandFile, encoding: .utf8) {
                if command.trimmingCharacters(in: .whitespacesAndNewlines) == "stop" {
                    return
                }
                if command.trimmingCharacters(in: .whitespacesAndNewlines) == "inject-disconnect",
                   !FileManager.default.fileExists(atPath: injectedFile.path),
                   let connection = broker.connections().first(where: {
                       $0.active && $0.clientID == clientID
                   }) {
                    do {
                        publishedFrameCountBeforeInjection = broker.publishedFrames().count
                        try broker.injectDisconnect(connectionID: connection.id)
                        try Data("injected\n".utf8).write(to: injectedFile, options: .atomic)
                    } catch {
                        FileHandle.standardError.write(Data("disconnect injection failed: \(error)\n".utf8))
                        return
                    }
                }
            }

            if FileManager.default.fileExists(atPath: injectedFile.path),
                !FileManager.default.fileExists(atPath: willObservedFile.path),
                let publishedFrameCountBeforeInjection,
                broker.publishedFrames().count > publishedFrameCountBeforeInjection {
                try? Data("observed\n".utf8).write(to: willObservedFile, options: .atomic)
            }
            usleep(20_000)
        }
    }

    private static func required(_ environment: [String: String], _ key: String) -> String {
        guard let value = environment[key], !value.isEmpty else {
            FileHandle.standardError.write(Data("missing \(key)\n".utf8))
            exit(64)
        }
        return value
    }
}
