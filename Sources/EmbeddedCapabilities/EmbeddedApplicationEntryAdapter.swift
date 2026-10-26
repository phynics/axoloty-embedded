// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Maps bounded Swift app outcomes to the stable C entry status values.
public enum EmbeddedApplicationEntryAdapter {
    /// Constructs capabilities using the selected app's single generated requirement record.
    public static func capabilities(
        validatingPlatform platform: UnsafePointer<axoloty_platform_v1>?,
        carrier: UnsafePointer<axoloty_carrier_v1>?,
        requirements: EmbeddedRequirements
    ) -> EmbeddedCapabilities? {
        EmbeddedCapabilities(
            validatingPlatform: platform,
            carrier: carrier,
            requirements: requirements
        )
    }

    /// Returns the stable C status corresponding to an application outcome.
    ///
    /// - Parameter result: The result returned by the app's synchronous run.
    /// - Returns: A fixed-width C entry status.
    public static func status(for result: EmbeddedApplicationResult) -> Int32 {
        switch result {
        case .completed:
            return AXOLOTY_APPLICATION_STATUS_COMPLETED
        case .failed:
            return AXOLOTY_APPLICATION_STATUS_FAILED
        }
    }

    /// Returns the status used when the shared boundary rejects ABI tables.
    public static var invalidABIStatus: Int32 {
        AXOLOTY_APPLICATION_STATUS_INVALID_ABI
    }

    /// Returns the status used when the app state's target stride exceeds its manifest budget.
    public static var stateBudgetExceededStatus: Int32 {
        AXOLOTY_APPLICATION_STATUS_STATE_BUDGET_EXCEEDED
    }

    /// Returns the status used when another valid call already owns application entry.
    public static var alreadyEnteredStatus: Int32 {
        AXOLOTY_APPLICATION_STATUS_ALREADY_ENTERED
    }

    /// Atomically claims this process's single application entry.
    ///
    /// - Returns: `true` only for the first caller.
    public static func claimEntry() -> Bool {
        axoloty_application_entry_claim_v1() != 0
    }
}
