// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@main
enum OutcomeStatusCheck {
    static func main() {
        precondition(EmbeddedApplicationEntryAdapter.status(for: .completed) == AXOLOTY_APPLICATION_STATUS_COMPLETED)
        precondition(EmbeddedApplicationEntryAdapter.status(for: .failed(.failed)) == AXOLOTY_APPLICATION_STATUS_FAILED)
        precondition(EmbeddedApplicationEntryAdapter.invalidABIStatus == AXOLOTY_APPLICATION_STATUS_INVALID_ABI)
        precondition(AXOLOTY_APPLICATION_STATUS_STATE_BUDGET_EXCEEDED == -102)
        precondition(EmbeddedApplicationEntryAdapter.stateBudgetExceededStatus == AXOLOTY_APPLICATION_STATUS_STATE_BUDGET_EXCEEDED)
        precondition(AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED == -103)
        precondition(EmbeddedApplicationEntryAdapter.alreadyEnteredStatus == AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED)
        precondition(AXOLOTY_APPLICATION_STATUS_STATE_BUDGET_EXCEEDED != AXOLOTY_APPLICATION_STATUS_FAILED)
        precondition(AXOLOTY_APPLICATION_STATUS_STATE_BUDGET_EXCEEDED != AXOLOTY_APPLICATION_STATUS_INVALID_ABI)
        precondition(AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED != AXOLOTY_APPLICATION_STATUS_FAILED)
        precondition(AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED != AXOLOTY_APPLICATION_STATUS_INVALID_ABI)
    }
}
