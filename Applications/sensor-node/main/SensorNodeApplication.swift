// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The production reference application: one sensor object on one carrier.
//
// It advertises one object, publishes a reading on a fixed period, answers
// Discover with Resolve, and leaves a Deadvertise as the carrier's last will
// where the carrier has one. It exists so the footprint of a production-shaped
// image can be measured apart from the smoke harness. The reading is a
// synthetic counter: no platform in this repository declares a sensor.

import AxolotyObjectModel
import AxolotyStaticRuntime
import AxolotyWire

/// The one capacity set of this image: two actions in flight (an Advertise
/// publishes on two routes) and the profile's 512-byte payload cap.
typealias SensorNodeRuntime = StaticRuntime<2, 512>

/// The wire profile the selected transport carries. Each image links exactly
/// one: `coaty/3` JSON when the JSON parser is linked, `axoloty/1` CBOR when it
/// is not.
func sensorNodeWireProfile() -> WireProfile {
    #if canImport(_JSONCore)
    return .coaty3JSON
    #else
    return .axoloty1CBOR
    #endif
}

/// The sensor node on the stable application entry.
@EmbeddedApplication
enum SensorNode {
    struct State: ~Copyable {
        var runtime = try! SensorNodeRuntime(
            registryID: ObjectID(uuid: SensorNodeIdentity.agent),
            wireCodec: WireCodec(profile: sensorNodeWireProfile())
        )
    }

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        guard (try? capabilities.platform.isNetworkConfigured()) == true else {
            sensorNodeLog(capabilities.platform, "{\"event\":\"sensor-node-unconfigured\"}\n")
            return .failed(.failed)
        }
        var counters = SensorNodeCounters()
        var failedSessions: UInt32 = 0
        // The node runs until power-off. A session that never reached the
        // network counts against the restart limit; one that did resets it.
        while true {
            let reachedNetwork = runSensorNodeSession(capabilities, runtime: &state.runtime, counters: &counters)
            counters.sessions &+= 1
            failedSessions = reachedNetwork ? 0 : failedSessions + 1
            guard failedSessions < SensorNodeTiming.maximumFailedSessions else {
                sensorNodeLog(capabilities.platform, "{\"event\":\"sensor-node-restart\"}\n")
                _ = try? capabilities.platform.restart()
                return .failed(.failed)
            }
            let backoff = min(SensorNodeTiming.retryBaseTicks << min(failedSessions, 5), SensorNodeTiming.retryCeilingTicks)
            _ = try? capabilities.platform.delay(ticks: backoff)
        }
    }
}
