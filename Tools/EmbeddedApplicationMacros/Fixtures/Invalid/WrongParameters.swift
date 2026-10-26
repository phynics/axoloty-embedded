// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication
private enum WrongParametersApplication {
    struct State {}
    static func run(_ capabilities: EmbeddedCapabilities) -> EmbeddedApplicationResult { .completed }
}
