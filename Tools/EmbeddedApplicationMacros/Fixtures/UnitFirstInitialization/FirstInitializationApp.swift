// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_silgen_name("first_init_record") func first_init_record(_ event: Int32)

struct FirstInitializationState: ~Copyable {
    var marker: UInt32

    init() {
        first_init_record(83)
        marker = 7
    }
}

@EmbeddedApplication(traceFirstInitialization: true)
enum FirstInitializationApp {
    typealias State = FirstInitializationState

    static func initializeStaticState() {
        first_init_record(72)
    }

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        first_init_record(82)
        state.marker += 1
        return .completed
    }
}
