// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

nonisolated(unsafe) var c2StateInitializations: UInt32 = 0
nonisolated(unsafe) var c2RunCalls: UInt32 = 0
nonisolated(unsafe) var c2RunMode: Int32 = 0
nonisolated(unsafe) var c2RecursiveResult: Int32 = 0

@EmbeddedApplication
enum EntryExclusionApplication {
    struct State {
        var marker: UInt32

        init() {
            c2StateInitializations &+= 1
            marker = 0x62c2
        }
    }

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        c2RunCalls &+= 1
        if c2RunMode == 1 {
            c2RecursiveResult = axoloty_application_main(
                unit_b_platform_table(), unit_b_minimal_carrier_table()
            )
        }
        state.marker &+= 1
        return c2RunMode == 2 ? .failed(.failed) : .completed
    }
}
