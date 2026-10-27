// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_silgen_name("first_init_record") func first_init_record(_ event: Int32)

@EmbeddedApplication(traceFirstInitialization: false)
enum DisabledHeapDiagnosticsApp {
    struct State { init() { first_init_record(83) } }
    static func initializeStaticState() { first_init_record(72) }
    static func run(_ capabilities: EmbeddedCapabilities, state: inout State) -> EmbeddedApplicationResult {
        first_init_record(82)
        return .completed
    }
}
