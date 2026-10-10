// Ported from desktop/app/src/models/rebase.ts

/// Rebase internal state used to track how and where the rebase is applied to
/// the repository.
public struct RebaseInternalState: Hashable, Sendable {
    /// The branch containing commits that should be rebased
    public let targetBranch: String
    /// The commit ID of the base branch, to be used as a starting point for
    /// the rebase.
    public let baseBranchTip: String
    /// The commit ID of the target branch at the start of the rebase, which points
    /// to the original commit history.
    public let originalBranchTip: String

    public init(targetBranch: String, baseBranchTip: String, originalBranchTip: String) {
        self.targetBranch = targetBranch
        self.baseBranchTip = baseBranchTip
        self.originalBranchTip = originalBranchTip
    }
}

/// Options to pass in to rebase progress reporting
public struct RebaseProgressOptions: Sendable {
    public let commits: [CommitOneLine]
    /// The callback to fire when rebase progress is reported
    public let progressCallback: @Sendable (MultiCommitOperationProgress) -> Void

    public init(
        commits: [CommitOneLine],
        progressCallback: @escaping @Sendable (MultiCommitOperationProgress) -> Void
    ) {
        self.commits = commits
        self.progressCallback = progressCallback
    }
}

/// Whether a rebase would be clean. The cases are its `kind`.
public enum RebasePreview: Hashable, Sendable {
    /// The rebase would be clean.
    ///
    /// - Parameters:
    ///   - commitsAhead: The commits present in the base branch but not in the target branch
    ///   - commitsBehind: The commits present in the target branch but not in the base branch
    case clean(commitsAhead: [CommitOneLine], commitsBehind: [CommitOneLine])
    /// The rebase would conflict.
    case conflicts
    /// The rebase can't be done.
    case invalid
    /// Still being computed.
    case loading

    public var kind: ComputedAction {
        switch self {
        case .clean: .clean
        case .conflicts: .conflicts
        case .invalid: .invalid
        case .loading: .loading
        }
    }
}

/// Represents a snapshot of the rebase state from the Git repository
public struct GitRebaseSnapshot: Hashable, Sendable {
    /// The sequence of commits that are used in the rebase
    public let commits: [CommitOneLine]
    /// The progress of the operation
    public let progress: MultiCommitOperationProgress

    public init(commits: [CommitOneLine], progress: MultiCommitOperationProgress) {
        self.commits = commits
        self.progress = progress
    }
}
