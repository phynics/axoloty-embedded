// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Installs the profile-interest key expressions required by the agent, and
/// removes every earlier successful declaration if a later install fails.
/// This application-owned helper contains only the profile's route shapes;
/// the carrier operations interpret their wildcard grammar.
@inline(never)
func installDeviceAgentProfileInterest(
    subscribe: (UnsafePointer<UInt8>, Int32, UInt32) -> Int32,
    unsubscribe: (UnsafePointer<UInt8>, Int32, UInt32) -> Int32,
    deadlineMS: UInt32
) -> Bool {
    var installed = 0
    for index in 0..<3 {
        let filter: StaticString
        switch index {
        case 0: filter = "coaty/3/axoloty-embedded/#"
        case 1: filter = "coaty/3/axoloty-embedded/*/*"
        default: filter = "coaty/3/axoloty-embedded/*/*/*"
        }
        guard subscribe(filter.utf8Start, Int32(filter.utf8CodeUnitCount), deadlineMS) != 0 else {
            for prior in 0..<installed {
                let priorFilter: StaticString
                switch prior {
                case 0: priorFilter = "coaty/3/axoloty-embedded/#"
                case 1: priorFilter = "coaty/3/axoloty-embedded/*/*"
                default: priorFilter = "coaty/3/axoloty-embedded/*/*/*"
                }
                _ = unsubscribe(priorFilter.utf8Start, Int32(priorFilter.utf8CodeUnitCount), deadlineMS)
            }
            return false
        }
        installed += 1
    }
    return true
}
