// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication
enum DeviceSmoke {
    struct State {
        var entryCount: UInt32 = 0
    }

    static func run(_ capabilities: EmbeddedCapabilities, state: inout State) -> Int32 {
        guard state.entryCount == 0 else { return -2 }
        state.entryCount = 1
        return startDeviceSmoke(capabilities)
    }
}
