// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@main
enum EntryExclusionHostMain {
    static func main() {
        let scenario = CommandLine.arguments[1]
        switch scenario {
        case "repeat":
            let first = callValidEntry()
            let second = callValidEntry()
            precondition(first == AXOLOTY_APPLICATION_STATUS_COMPLETED)
            precondition(second == AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED)
            precondition(c2StateInitializations == 1 && c2RunCalls == 1)
            print("PASS repeat: one initialization/run; second call returns -103")
        case "invalid-abi":
            let invalid = axoloty_application_main(nil, nil)
            precondition(invalid == AXOLOTY_APPLICATION_STATUS_INVALID_ABI)
            precondition(c2StateInitializations == 0 && c2RunCalls == 0)
            let valid = callValidEntry()
            precondition(valid == AXOLOTY_APPLICATION_STATUS_COMPLETED)
            precondition(c2StateInitializations == 1 && c2RunCalls == 1)
            print("PASS invalid ABI does not consume entry; next valid call initializes/runs once")
        case "recursive":
            c2RunMode = 1
            let outer = callValidEntry()
            precondition(outer == AXOLOTY_APPLICATION_STATUS_COMPLETED)
            precondition(c2RecursiveResult == AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED)
            precondition(c2StateInitializations == 1 && c2RunCalls == 1)
            print("PASS recursive call returns -103 while outer run completes")
        case "failed":
            c2RunMode = 2
            let first = callValidEntry()
            let second = callValidEntry()
            precondition(first == AXOLOTY_APPLICATION_STATUS_FAILED)
            precondition(second == AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED)
            precondition(c2StateInitializations == 1 && c2RunCalls == 1)
            print("PASS failed app consumes entry; later call returns -103")
        case "race":
            var results = [Int32](repeating: 0, count: 16)
            let raceStatus = results.withUnsafeMutableBufferPointer { buffer in
                unit_c2_race_entry(buffer.baseAddress, UInt32(buffer.count))
            }
            precondition(raceStatus == 0)
            let winners = results.filter { $0 == AXOLOTY_APPLICATION_STATUS_COMPLETED }.count
            let rejected = results.filter { $0 == AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED }.count
            precondition(winners == 1 && rejected == 15)
            precondition(c2StateInitializations == 1 && c2RunCalls == 1)
            print("PASS 16 barrier-released pthread callers: one winner, 15 rejected, one initialization/run")
        default:
            fatalError("unknown Unit C2 scenario: \(scenario)")
        }
    }

    private static func callValidEntry() -> Int32 {
        axoloty_application_main(unit_b_platform_table(), unit_b_minimal_carrier_table())
    }
}
