// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication(traceFirstInitialization: true)
enum MissingHook {
    struct State {}
    static func run(_ capabilities: EmbeddedCapabilities, state: inout State) -> EmbeddedApplicationResult { .completed }
}
