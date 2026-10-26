// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@main
enum StateBudgetHostMain {
    static func main() {
        let budget = EmbeddedApplicationRequirements.current.applicationStateBytes
        let result = axoloty_application_main(
            unit_b_platform_table(),
            unit_b_minimal_carrier_table()
        )

        if budget == 7 {
            precondition(result == EmbeddedApplicationEntryAdapter.stateBudgetExceededStatus)
            precondition(c1StateInitializations == 0)
            precondition(c1RunCalls == 0)
            print("PASS stride 8 exceeds budget 7 before state initialization and run")
            return
        }

        precondition(budget == 8)
        precondition(result == AXOLOTY_APPLICATION_STATUS_COMPLETED)
        precondition(c1StateInitializations == 1)
        precondition(c1RunCalls == 1)
        precondition(c1LastMarker == 0x6a09_e668)
        let secondResult = axoloty_application_main(
            unit_b_platform_table(),
            unit_b_minimal_carrier_table()
        )
        precondition(secondResult == AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED)
        precondition(c1StateInitializations == 1)
        precondition(c1RunCalls == 1)
        precondition(c1LastMarker == 0x6a09_e668)
        print("PASS exact-fit stride 8; second entry rejects and state remains untouched")
    }
}
