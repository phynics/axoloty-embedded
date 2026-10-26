// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@main
enum EntryCheckMain {
    static func main() {
        let result = axoloty_application_main(unit_b_platform_table(), unit_b_minimal_carrier_table())
        guard result == AXOLOTY_APPLICATION_STATUS_COMPLETED else {
            fatalError("console-only application entry did not start")
        }
    }
}
