// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

nonisolated(unsafe) var c1StateInitializations: UInt32 = 0
nonisolated(unsafe) var c1RunCalls: UInt32 = 0
nonisolated(unsafe) var c1LastMarker: UInt32 = 0

@EmbeddedApplication
enum StateBudgetApp {
    struct State {
        var marker: UInt32
        var reserved: UInt32

        init() {
            c1StateInitializations &+= 1
            marker = 0x6a09_e667
            reserved = 0
        }
    }

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        c1RunCalls &+= 1
        state.marker &+= 1
        c1LastMarker = state.marker
        return .completed
    }
}
