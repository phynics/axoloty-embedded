// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@_silgen_name("first_init_reset") func firstInitReset(_ beginStatus: Int32, _ endStatus: Int32, _ count: UInt32)
@_silgen_name("first_init_log") func firstInitLog() -> UnsafePointer<CChar>
@_silgen_name("first_init_platform") func firstInitPlatform() -> UnsafePointer<axoloty_platform_v1>
@_silgen_name("first_init_carrier") func firstInitCarrier() -> UnsafePointer<axoloty_carrier_v1>

@main
enum DisabledHeapDiagnosticsMain {
    static func main() {
        firstInitReset(AXOLOTY_ABI_STATUS_OK, AXOLOTY_ABI_STATUS_OK, 0)
        let status = axoloty_application_main(firstInitPlatform(), firstInitCarrier())
        precondition(status == AXOLOTY_APPLICATION_STATUS_COMPLETED)
        precondition(String(cString: firstInitLog()) == "SR")
        print("PASS disabled heap diagnostics: \(String(cString: firstInitLog())) => \(status)")
    }
}
