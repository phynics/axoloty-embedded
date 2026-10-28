// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The device smoke image as a pure-Swift application on the stable entry ABI.
@EmbeddedApplication(traceFirstInitialization: true)
enum DeviceSmoke {
    struct State {
        var entryCount: UInt32 = 0
    }

    static func initializeStaticState() {
        touchStaticDeviceAgents()
        touchRouterDispatchObservation()
        touchInstalledCapabilities()
        touchInstalledDeviceSmokeSeam()
        initializeEmbeddedGeneratedCorpusStaticState()
        initializeEmbeddedConstructedSchemaStaticState()
    }

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        guard state.entryCount == 0 else { return .failed(.failed) }
        state.entryCount = 1
        return startDeviceSmoke(capabilities)
    }
}
