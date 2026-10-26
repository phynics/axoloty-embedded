// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication
private enum WrongReturnApplication {
    struct State {}
    static func run(_ capabilities: EmbeddedCapabilities, state: inout State) -> Int32 { 0 }
}
