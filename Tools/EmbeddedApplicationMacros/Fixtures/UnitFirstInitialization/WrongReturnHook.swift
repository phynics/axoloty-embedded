// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication(traceFirstInitialization: true)
enum WrongReturnHook {
    struct State {}
    static func initializeStaticState() -> Int { 1 }
    static func run(_ capabilities: EmbeddedCapabilities, state: inout State) -> EmbeddedApplicationResult { .completed }
}
