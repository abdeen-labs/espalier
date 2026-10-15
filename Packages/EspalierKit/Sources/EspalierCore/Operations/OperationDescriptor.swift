// Ported from desktop/app/src/lib/git-error-context.ts

import GitKit

/// A custom shape of data for actions to provide to help with error
/// handling.
public enum GitErrorContext: Sendable, Equatable {
    /// A merge: the branch associated with the current tip of the
    /// repository ("ours"), and the branch being merged into it ("theirs").
    case merge(currentBranch: String, theirBranch: String)
    /// A pull, with the same branches as a merge.
    case pull(currentBranch: String, theirBranch: String)
    /// Checking out a branch.
    case checkout(Branch)
    /// Creating a repository.
    case createRepository
    /// Committing.
    case commit
}

/// How `RepositoryModel.perform` runs an operation.
public struct OperationDescriptor: Sendable {
    public var kind: OperationKind
    /// The lanes it holds while it runs.
    public var lanes: OperationLanes
    /// Whether the user or background work started it.
    public var policy: BusyPolicy
    /// What it does, for error titles and classification.
    public var gitContext: GitErrorContext?
    /// How to run it again, for recoveries.
    public var retry: (any RetryableOperation)?
    /// What to refresh when it ends, successfully or not.
    public var refreshAfter: RefreshScope
    /// How that refresh treats what it loads (a commit drops partial line
    /// selections).
    public var refreshOptions: RefreshOptions
    /// Whether its network activity, which the sync button shows as
    /// progress, lasts until that refresh has loaded: the button then goes
    /// from the progress straight to the state the operation left, never
    /// back to the one from before it. The lanes are released first.
    public var showsProgressUntilRefreshed: Bool
    /// Whether its outcome updates the repository's `lastBackgroundFailure`:
    /// a background failure sets it, and a success clears one of the same
    /// kind. Off for work that succeeds when its git work failed (the
    /// indicator fetch).
    public var updatesBackgroundFailure: Bool

    public init(
        kind: OperationKind,
        lanes: OperationLanes = [.local],
        policy: BusyPolicy = .user,
        gitContext: GitErrorContext? = nil,
        retry: (any RetryableOperation)? = nil,
        refreshAfter: RefreshScope = .full,
        refreshOptions: RefreshOptions = [],
        showsProgressUntilRefreshed: Bool = false,
        updatesBackgroundFailure: Bool = true
    ) {
        self.kind = kind
        self.lanes = lanes
        self.policy = policy
        self.gitContext = gitContext
        self.retry = retry
        self.refreshAfter = refreshAfter
        self.refreshOptions = refreshOptions
        self.showsProgressUntilRefreshed = showsProgressUntilRefreshed
        self.updatesBackgroundFailure = updatesBackgroundFailure
    }

    /// Whether background work runs it: its errors are never presented as
    /// errors (the last is kept as `lastBackgroundFailure`) and it never
    /// prompts.
    public var isBackgroundTask: Bool {
        policy == .background
    }
}
