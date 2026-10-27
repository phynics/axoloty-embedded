// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication(traceFirstInitialization: true)
enum ThrowingHook {
    enum HookFailure: Error { case failed }
    struct State {}
    static func initializeStaticState() throws(HookFailure) {}
    static func run(_ capabilities: EmbeddedCapabilities, state: inout State) -> EmbeddedApplicationResult { .completed }
}
