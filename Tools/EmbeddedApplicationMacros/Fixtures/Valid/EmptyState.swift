// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@EmbeddedApplication
private enum StatelessApplication {
    typealias State = EmptyApplicationState

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        .completed
    }
}

@_cdecl("c1_empty_size") func c1EmptySize() -> UInt32 { UInt32(MemoryLayout<EmptyApplicationState>.size) }
@_cdecl("c1_empty_stride") func c1EmptyStride() -> UInt32 { UInt32(MemoryLayout<EmptyApplicationState>.stride) }
@_cdecl("c1_empty_alignment") func c1EmptyAlignment() -> UInt32 { UInt32(MemoryLayout<EmptyApplicationState>.alignment) }
