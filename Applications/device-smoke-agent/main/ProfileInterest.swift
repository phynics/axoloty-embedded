// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The profile-interest installation outcome, including whether failure cleanup
/// closed the session.
struct ProfileInterestInstallationResult {
    let installed: Bool
    let disconnected: Bool
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
    for index in 0..<3 {
        let filter: StaticString
        switch index {
        case 0: filter = "coaty/3/axoloty-embedded/#"
        case 1: filter = "coaty/3/axoloty-embedded/*/*"
        default: filter = "coaty/3/axoloty-embedded/*/*/*"
        }
        let remaining = remainingMS()
        guard remaining > 0,
              subscribe(filter.utf8Start, Int32(filter.utf8CodeUnitCount), remaining) != 0 else {
            for prior in 0..<installed {
                let priorFilter: StaticString
                switch prior {
                case 0: priorFilter = "coaty/3/axoloty-embedded/#"
                case 1: priorFilter = "coaty/3/axoloty-embedded/*/*"
                default: priorFilter = "coaty/3/axoloty-embedded/*/*/*"
                }
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
