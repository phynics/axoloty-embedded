// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

struct MinimalNoncopyableState: ~Copyable {
    var marker: UInt32

    init() {
        marker = 0x6a09_e667
    }
}

@EmbeddedApplication
enum MinimalNoncopyableApp {
    typealias State = MinimalNoncopyableState

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        state.marker &+= 1
        return .completed
    }
}

@_cdecl("c1_minimal_size") func c1MinimalSize() -> UInt32 { UInt32(MemoryLayout<MinimalNoncopyableState>.size) }
@_cdecl("c1_minimal_stride") func c1MinimalStride() -> UInt32 { UInt32(MemoryLayout<MinimalNoncopyableState>.stride) }
@_cdecl("c1_minimal_alignment") func c1MinimalAlignment() -> UInt32 { UInt32(MemoryLayout<MinimalNoncopyableState>.alignment) }
