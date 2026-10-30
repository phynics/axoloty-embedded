// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The profile-interest installation outcome, including whether failure cleanup
/// closed the session.
struct ProfileInterestInstallationResult {
    let installed: Bool
    let disconnected: Bool
}

/// The number of interest levels this image's profile installs.
///
/// The `coaty/3` set keeps the legacy hash-shaped filter. It is a wildcard to
/// an MQTT broker. In Zenoh's key grammar `#` is a forbidden character, and a
/// router that is asked to declare it panics, so the `axoloty/1` set installs
/// only the two forms Core's host binding installs.
private func profileInterestLevels() -> Int {
    #if canImport(_JSONCore)
    return 3
    #else
    return 2
    #endif
}

/// The key expression for one interest level under the image's wire profile.
/// The route prefix is the profile's own: `coaty/3` for JSON and `axoloty/1`
/// for CBOR, so a CBOR participant subscribes to the routes it publishes.
private func profileInterestFilter(_ index: Int) -> StaticString {
    #if canImport(_JSONCore)
    switch index {
    case 0: return "coaty/3/axoloty-embedded/#"
    case 1: return "coaty/3/axoloty-embedded/*/*"
    default: return "coaty/3/axoloty-embedded/*/*/*"
    }
    #else
    switch index {
    case 0: return "axoloty/1/axoloty-embedded/*/*"
    default: return "axoloty/1/axoloty-embedded/*/*/*"
    }
    #endif
}

/// Installs the profile-interest key expressions required by the agent, and
/// removes every earlier successful declaration if a later install fails.
/// It then closes the carrier session so failed partial interest cannot leak.
/// This application-owned helper contains only the profile's route shapes;
/// the carrier operations interpret their wildcard grammar.
@inline(never)
func installDeviceAgentProfileInterest(
    subscribe: (UnsafePointer<UInt8>, Int32, UInt32) -> Int32,
    unsubscribe: (UnsafePointer<UInt8>, Int32, UInt32) -> Int32,
    disconnect: () -> Int32,
    remainingMS: () -> UInt32
) -> ProfileInterestInstallationResult {
    var installed = 0
    for index in 0..<profileInterestLevels() {
        let filter = profileInterestFilter(index)
        let remaining = remainingMS()
        guard remaining > 0,
              subscribe(filter.utf8Start, Int32(filter.utf8CodeUnitCount), remaining) != 0 else {
            for prior in 0..<installed {
                let priorFilter = profileInterestFilter(prior)
                _ = unsubscribe(priorFilter.utf8Start, Int32(priorFilter.utf8CodeUnitCount), remainingMS())
            }
            return ProfileInterestInstallationResult(installed: false, disconnected: disconnect() != 0)
        }
        installed += 1
    }
    return ProfileInterestInstallationResult(installed: true, disconnected: false)
}

/// Decides whether role A can connect after will configuration. A carrier
/// without broker-will capability may run scenarios that do not depend on
/// that guarantee, but it must not run the will-dependent scenario by
/// pretending that a configured will exists.
func agentMayConnectAfterWillSetup(
    isRoleA: Bool,
    scenarioNeedsWill: Bool,
    carrierSupportsWill: Bool,
    willConfigurationSucceeded: Bool
) -> Bool {
    guard isRoleA else { return true }
    if !carrierSupportsWill { return !scenarioNeedsWill }
    return willConfigurationSucceeded
}
