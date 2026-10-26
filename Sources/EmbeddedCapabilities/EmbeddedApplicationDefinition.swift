// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Defines the synchronous app entry expected by ``EmbeddedApplication``.
public protocol EmbeddedApplicationDefinition {
    /// The app-owned state passed to every entry invocation.
    associatedtype State: ~Copyable

    /// Runs the application with bounded capabilities and caller-owned state.
    ///
    /// - Parameters:
    ///   - capabilities: The validated operations supplied by the platform.
    ///   - state: The app's state value.
    /// - Returns: The bounded application outcome.
    static func run(
        _ capabilities: EmbeddedCapabilities,
        state: inout State
    ) -> EmbeddedApplicationResult
}

/// A bounded application-level failure. ABI and bootstrap errors are separate.
public enum EmbeddedApplicationFailure {
    /// The application could not complete its requested work.
    case failed
}

/// The only outcomes that an application can return from its entry.
public enum EmbeddedApplicationResult {
    /// The application completed its synchronous work.
    case completed
    /// The application work failed.
    case failed(EmbeddedApplicationFailure)
}

/// A zero-field state value for applications that do not keep app state.
public struct EmptyApplicationState {
    /// Creates the empty state value.
    public init() {}
}
