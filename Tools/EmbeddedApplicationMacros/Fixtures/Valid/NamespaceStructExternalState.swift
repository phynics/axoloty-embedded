// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

private struct ExternalState { var starts: UInt32 = 0 }

@EmbeddedApplication
private struct NamespaceStructApplication {
    typealias State = ExternalState

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        state.starts &+= 1
        return .completed
    }
}
