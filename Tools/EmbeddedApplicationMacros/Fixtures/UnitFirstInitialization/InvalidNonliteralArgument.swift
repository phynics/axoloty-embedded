// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

let firstInitializationFlag = true
@EmbeddedApplication(traceFirstInitialization: firstInitializationFlag)
enum InvalidNonliteralArgument {
    struct State {}
    static func initializeStaticState() {}
    static func run(_ capabilities: EmbeddedCapabilities, state: inout State) -> EmbeddedApplicationResult { .completed }
}
