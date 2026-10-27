// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@_silgen_name("first_init_reset") func firstInitReset(_ beginStatus: Int32, _ endStatus: Int32, _ count: UInt32)
@_silgen_name("first_init_log") func firstInitLog() -> UnsafePointer<CChar>
@_silgen_name("first_init_platform") func firstInitPlatform() -> UnsafePointer<axoloty_platform_v1>
@_silgen_name("first_init_carrier") func firstInitCarrier() -> UnsafePointer<axoloty_carrier_v1>

@main
enum EntryOrderingHostMain {
    static func main() {
        let scenario = CommandLine.arguments.last ?? "success"
        let beginStatus: Int32 = scenario == "begin" || scenario == "repeat-failure" ? -9 : AXOLOTY_ABI_STATUS_OK
        let endStatus: Int32 = scenario == "stop" ? -9 : scenario == "overflow" ? AXOLOTY_ABI_STATUS_TRACE_OVERFLOW : AXOLOTY_ABI_STATUS_OK
        let count: UInt32 = scenario == "nonzero" ? 1 : 0
        firstInitReset(beginStatus, endStatus, count)
        let status = axoloty_application_main(firstInitPlatform(), firstInitCarrier())
        let log = String(cString: firstInitLog())
        let expected: (Int32, String)
        switch scenario {
        case "begin": expected = (AXOLOTY_APPLICATION_STATUS_TRACE_START_FAILED, "B")
        case "stop": expected = (AXOLOTY_APPLICATION_STATUS_TRACE_STOP_FAILED, "BHSE")
        case "overflow": expected = (AXOLOTY_APPLICATION_STATUS_TRACE_OVERFLOW, "BHSE")
        case "nonzero": expected = (AXOLOTY_APPLICATION_STATUS_TRACE_ALLOCATIONS_OBSERVED, "BHSE")
        case "repeat":
            let second = axoloty_application_main(firstInitPlatform(), firstInitCarrier())
            precondition(second == AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED)
            expected = (AXOLOTY_APPLICATION_STATUS_COMPLETED, "BHSER")
        case "repeat-failure":
            let second = axoloty_application_main(firstInitPlatform(), firstInitCarrier())
            precondition(second == AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED)
            expected = (AXOLOTY_APPLICATION_STATUS_TRACE_START_FAILED, "B")
        case "requirements": expected = (AXOLOTY_APPLICATION_STATUS_TRACE_REQUIREMENTS_MISMATCH, "")
        case "overbudget": expected = (AXOLOTY_APPLICATION_STATUS_STATE_BUDGET_EXCEEDED, "")
        default: expected = (AXOLOTY_APPLICATION_STATUS_COMPLETED, "BHSER")
        }
        precondition(status == expected.0, "status \(status), expected \(expected.0)")
        precondition(log == expected.1, "events \(log), expected \(expected.1)")
        precondition(!EmbeddedApplicationEntryAdapter.hasHeapTraceRequirements(
            EmbeddedRequirements(platformCapabilities: 0, carrierCapabilities: 0,
                                 platformFunctions: 0, carrierFunctions: 0,
                                 maxTopicLength: 1, maxPayloadSize: 1, applicationStateBytes: 8)
        ))
        precondition(!EmbeddedApplicationEntryAdapter.hasHeapTraceRequirements(
            EmbeddedRequirements(platformCapabilities: 0, carrierCapabilities: 0,
                                 platformFunctions: 1 << 4, carrierFunctions: 0,
                                 maxTopicLength: 1, maxPayloadSize: 1, applicationStateBytes: 8)
        ))
        precondition(!EmbeddedApplicationEntryAdapter.hasHeapTraceRequirements(
            EmbeddedRequirements(platformCapabilities: 0, carrierCapabilities: 0,
                                 platformFunctions: 1 << 5, carrierFunctions: 0,
                                 maxTopicLength: 1, maxPayloadSize: 1, applicationStateBytes: 8)
        ))
        print("PASS \(scenario): \(log) => \(status)")
    }
}
