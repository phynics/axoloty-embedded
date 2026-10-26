// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication
private enum ProductionHeaderApplication {
    struct State { var starts: UInt32 = 0 }

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        state.starts &+= 1
        return .completed
    }
}
