// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Host entry point for the device-smoke application. The application ends by
// requesting a restart, which the host seam records and terminates cleanly, so
// this return path is only reached when the link probes fail before `runSmoke`.
//
// `@main` keeps the entry point out of a file named `main.swift`, which the
// repository's copied-source rule treats as a portable-Core filename.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@main
struct HostSmokeMain {
    static func main() {
        checkExchangeFailureCleanup()
        exit(startDeviceSmoke(hostSmokeSeam()))
    }
}

// Exercise the actual exchange entry point, including its final cleanup, rather
// than only the profile-interest helper. None of these stubs reaches a broker.
private enum FailedInterestRun {
    static var subscribes = 0
    static var unsubscribes = 0
    static var disconnects = 0
    static var reconnects = 0
    static var publishes = 0
    static var failAt = 2
}

private func checkExchangeFailureCleanup() {
    for failAt in [2, 3] {
        FailedInterestRun.subscribes = 0
        FailedInterestRun.unsubscribes = 0
        FailedInterestRun.disconnects = 0
        FailedInterestRun.reconnects = 0
        FailedInterestRun.publishes = 0
        FailedInterestRun.failAt = failAt
        var seam = hostSmokeSeam()
        seam.networkPrepare = { _ in 3 }
        seam.networkReconnect = { _ in FailedInterestRun.reconnects += 1; return 3 }
        seam.carrier.connect = { _ in 1 }
        seam.carrier.subscribe = { _, _, _ in
            FailedInterestRun.subscribes += 1
            return FailedInterestRun.subscribes == FailedInterestRun.failAt ? 0 : 1
        }
        // Even failed removal must be followed by exactly one close.
        seam.carrier.unsubscribe = { _, _, _ in FailedInterestRun.unsubscribes += 1; return 0 }
        seam.carrier.disconnect = { FailedInterestRun.disconnects += 1; return 1 }
        seam.carrier.publish = { _, _, _, _ in FailedInterestRun.publishes += 1; return 1 }
        let result = runDeviceAgentExchange(
            role: DeviceAgentRole.roleA.rawValue,
            scenario: DeviceAgentScenario.exchange.rawValue, seam: seam)
        guard result.contains(.connected), result.contains(.disconnected),
              !result.contains(.subscribed), !result.contains(.advertised),
              FailedInterestRun.subscribes == failAt,
              FailedInterestRun.unsubscribes == failAt - 1,
              FailedInterestRun.disconnects == 1,
              FailedInterestRun.reconnects == 0, FailedInterestRun.publishes == 0 else {
            fatalError("AgentExchange failed-interest cleanup did not match its contract")
        }
    }
    print("AgentExchange failure cleanup passed: second and third subscription refusal")
}
