import Foundation
import GitKit

/// An operation running in a repository.
public struct ActiveOperation: Sendable, Identifiable {
    public let id: UUID
    public let kind: OperationKind
    public let startedAt: Date
    /// Whether background work started it (a background fetch, a prune).
    public let isBackgroundTask: Bool
    /// The latest progress the operation reported.
    public var progress: AnyProgress?
    /// The hook running or last run by the operation, for operations that
    /// intercept hooks (commit, merge, pull, push).
    public var hook: HookActivity?
    /// Subscribes to the live terminal output of the operation's current git
    /// process, once git has started.
    public var terminalOutput: TerminalOutputListener?
    /// Whether the operation hangs: a network operation that has had nothing
    /// from git (progress or output) or its hooks for 10 seconds.
    public var isHanging = false

    public init(
        id: UUID = UUID(),
        kind: OperationKind,
        startedAt: Date = Date(),
        isBackgroundTask: Bool = false,
        progress: AnyProgress? = nil,
        hook: HookActivity? = nil,
        terminalOutput: TerminalOutputListener? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.isBackgroundTask = isBackgroundTask
        self.progress = progress
        self.hook = hook
        self.terminalOutput = terminalOutput
    }
}

/// A hook an operation runs.
public struct HookActivity: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case running, finished, failed
    }

    /// The hook's name, such as `pre-commit`.
    public let name: String
    public var status: Status

    public init(name: String, status: Status) {
        self.name = name
        self.status = status
    }
}

/// The last failure of background work in a repository. Never presented as
/// an error; the UI may show it quietly.
public struct BackgroundFailure: Sendable {
    public let error: OperationError
    public let date: Date

    public init(error: OperationError, date: Date) {
        self.error = error
        self.date = date
    }
}

/// An operation running somewhere in the app, for "quit anyway?".
public struct RunningOperation: Sendable, Identifiable {
    public let repositoryID: RepositoryID
    public let operation: ActiveOperation

    public var id: UUID {
        operation.id
    }

    public init(repositoryID: RepositoryID, operation: ActiveOperation) {
        self.repositoryID = repositoryID
        self.operation = operation
    }
}
