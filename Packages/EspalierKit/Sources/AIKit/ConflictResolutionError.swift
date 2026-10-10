// Ported from desktop/app/src/lib/copilot-conflict-resolution-error.ts

import Foundation

/// The step of a conflict resolution that failed.
public enum AIConflictResolutionFailureStage: String, Sendable, Hashable, CaseIterable {
    case gatherContext = "gather-context"
    case resolveModel = "resolve-model"
    case createClient = "create-client"
    case createSession = "create-session"
    case streamResponse = "stream-response"
    case parseResponse = "parse-response"
    case validateResponse = "validate-response"
    case reassembleResponse = "reassemble-response"
    case processResult = "process-result"
    case unknown
}

/// Whether a failed chunk was retried after an unusable response.
public enum AIConflictResolutionRetryState: String, Sendable, Hashable, CaseIterable {
    case notRetried = "not-retried"
    case failedAfterValidationRetry = "failed-after-validation-retry"
}

/// A conflict resolution failure carrying only stable, privacy-safe metadata.
///
/// The underlying error remains available for local logging and user-facing
/// error handling (see `getAIErrorDisplayInfo(for:)`), while the error
/// message contains only reportable metadata.
public struct AIConflictResolutionError: Error, LocalizedError, Sendable {
    public let stage: AIConflictResolutionFailureStage
    public let retryState: AIConflictResolutionRetryState
    public let underlyingError: any Error

    public init(
        _ error: any Error,
        stage: AIConflictResolutionFailureStage,
        retryState: AIConflictResolutionRetryState = .notRetried
    ) {
        self.stage = stage
        self.retryState = retryState
        self.underlyingError = error
    }

    /// Only the stage and retry state, never the underlying error's text,
    /// which can contain paths or provider details.
    public var message: String {
        "AI Conflict Resolution Error: stage=\(stage.rawValue), retryState=\(retryState.rawValue)"
    }

    public var errorDescription: String? { message }
}

extension AIConflictResolutionError {
    /// Wraps `error` for `stage`, keeping an existing
    /// `AIConflictResolutionError` as it is.
    public static func wrapping(_ error: any Error, stage: AIConflictResolutionFailureStage) -> AIConflictResolutionError {
        if let existing = error as? AIConflictResolutionError {
            return existing
        }
        return AIConflictResolutionError(error, stage: stage)
    }
}
