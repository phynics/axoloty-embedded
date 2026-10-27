// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication(traceFirstInitialization: true)
enum InvalidHookShape {
    enum HookFailure: Error { case failed }
    struct State {}
    func initializeStaticState() async throws(HookFailure) -> Int { 0 }
    static func run(_ capabilities: EmbeddedCapabilities, state: inout State) -> EmbeddedApplicationResult { .completed }
}
