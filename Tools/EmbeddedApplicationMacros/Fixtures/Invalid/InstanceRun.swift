// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication
private struct InstanceRunApplication {
    struct State {}
    func run(_ capabilities: EmbeddedCapabilities, state: inout State) -> EmbeddedApplicationResult {
        .completed
    }
}
