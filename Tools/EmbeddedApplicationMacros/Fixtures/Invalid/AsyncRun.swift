// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication
private enum AsyncRunApplication {
    struct State {}
    static func run(_ capabilities: EmbeddedCapabilities, state: inout State) async -> EmbeddedApplicationResult {
        .completed
    }
}
