// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication
private enum MissingStateApplication {
    static func run(_ capabilities: EmbeddedCapabilities, state: inout EmptyApplicationState) -> EmbeddedApplicationResult {
        .completed
    }
}
