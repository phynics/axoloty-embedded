// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

private var traceBeginStatus = AXOLOTY_ABI_STATUS_OK
private var traceEndStatus = AXOLOTY_ABI_STATUS_OK
private var traceCount: UInt32 = 0

private func traceBegin(_ context: UnsafeMutableRawPointer?) -> Int32 {
        _ = context
    return traceBeginStatus
}

private func traceEnd(
    _ context: UnsafeMutableRawPointer?, _ output: UnsafeMutablePointer<UInt32>?
) -> Int32 {
    _ = context
    guard let output else { return AXOLOTY_ABI_STATUS_INVALID_ARGUMENT }
    if traceEndStatus == AXOLOTY_ABI_STATUS_OK { output.pointee = traceCount }
    return traceEndStatus
}

@main
private enum HeapTraceStatusSwiftTest {
    static func main() {
        var platform = axoloty_platform_v1()
        platform.abi_version = AXOLOTY_PLATFORM_ABI_V1
        platform.struct_size = UInt32(MemoryLayout<axoloty_platform_v1>.size)
        platform.capabilities = UInt64(0x10)
        platform.heap_trace_begin = traceBegin
        platform.heap_trace_end = traceEnd
        var carrier = axoloty_carrier_v1()
        carrier.abi_version = AXOLOTY_CARRIER_ABI_V1
        carrier.struct_size = UInt32(MemoryLayout<axoloty_carrier_v1>.size)
        let requirements = EmbeddedRequirements(
            platformCapabilities: UInt64(0x10),
            carrierCapabilities: 0,
            platformFunctions: (UInt64(1) << 4) | (UInt64(1) << 5),
            carrierFunctions: 0,
            maxTopicLength: 0,
            maxPayloadSize: 0,
            applicationStateBytes: 0
        )

        withUnsafePointer(to: &platform) { platformPointer in
            withUnsafePointer(to: &carrier) { carrierPointer in
                guard let capabilities = EmbeddedCapabilities(
                    validatingPlatform: platformPointer,
                    carrier: carrierPointer,
                    requirements: requirements
                ) else { fail("valid capability tables were rejected") }
                checkStart(capabilities.platform, status: AXOLOTY_ABI_STATUS_OK, succeeds: true)
                traceBeginStatus = AXOLOTY_ABI_STATUS_FAILED
                checkStart(capabilities.platform, status: AXOLOTY_ABI_STATUS_FAILED, succeeds: false)
                traceBeginStatus = AXOLOTY_ABI_STATUS_OK

                traceCount = 0
                checkEnd(capabilities.platform, expected: 0)
                traceCount = 23
                checkEnd(capabilities.platform, expected: 23)
                traceEndStatus = AXOLOTY_ABI_STATUS_FAILED
                checkEndFailure(capabilities.platform, expected: .stopFailed)
                traceEndStatus = AXOLOTY_ABI_STATUS_TRACE_OVERFLOW
                checkEndFailure(capabilities.platform, expected: .overflow)
            }
        }
        print("heap-trace-status-swift-test: PASS")
    }

    private static func checkStart(
        _ platform: EmbeddedPlatformCapabilities, status: Int32, succeeds: Bool
    ) {
        traceBeginStatus = status
        do {
            try platform.beginHeapTrace()
            if !succeeds { fail("failed start status was accepted") }
        } catch EmbeddedHeapTraceError.startFailed {
            if succeeds { fail("successful start status failed") }
        } catch {
            fail("start status mapped to the wrong typed error")
        }
    }

    private static func checkEnd(_ platform: EmbeddedPlatformCapabilities, expected: UInt32) {
        do {
            let actual = try platform.endHeapTrace()
            if actual != expected { fail("successful allocation count changed") }
        } catch {
            fail("successful end status threw")
        }
    }

    private static func checkEndFailure(
        _ platform: EmbeddedPlatformCapabilities, expected: EmbeddedHeapTraceError
    ) {
        do {
            _ = try platform.endHeapTrace()
            fail("failed end status returned a count")
        } catch EmbeddedHeapTraceError.overflow {
            if expected != .overflow { fail("stop failure mapped to overflow") }
        } catch EmbeddedHeapTraceError.stopFailed {
            if expected != .stopFailed { fail("overflow mapped to stop failure") }
        } catch {
            fail("end status mapped to the wrong typed error")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("heap-trace-status-swift-test: \(message)\n", stderr)
        exit(1)
    }
}
