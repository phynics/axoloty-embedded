// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyProtocol

struct ProcessorState: ~Copyable {
    var marker: UInt32
    var processor: ProtocolProcessor<16>

    init() {
        marker = 0xbb67_ae85
        processor = ProtocolProcessor<16>(
            capabilities: .coatyCore3,
            maximumPayloadBytes: 256
        )
    }

    mutating func touch() {
        marker &+= 1
        _ = processor.expire(nowMS: marker)
    }
}

@EmbeddedApplication
enum ProcessorApp {
    typealias State = ProcessorState

    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult {
        state.touch()
        return .completed
    }
}

@_cdecl("c1_processor_size") func c1ProcessorSize() -> UInt32 { UInt32(MemoryLayout<ProcessorState>.size) }
@_cdecl("c1_processor_stride") func c1ProcessorStride() -> UInt32 { UInt32(MemoryLayout<ProcessorState>.stride) }
@_cdecl("c1_processor_alignment") func c1ProcessorAlignment() -> UInt32 { UInt32(MemoryLayout<ProcessorState>.alignment) }
