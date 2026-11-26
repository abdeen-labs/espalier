import EspalierSupport
import GitKit

/// What the repository list shows for a repository: where its HEAD is, how
/// far its branch is ahead of and behind its upstream, how many files
/// changed, and the operation git stopped in, with its conflicted files.
///
/// Every status a refresh pass loads makes one (`RepositoryRefresher`), for
/// the selected repository and the others alike.
public struct RepositoryIndicator: Sendable, Equatable {
    /// Where a repository's HEAD is.
    public enum Head: Sendable, Equatable {
        /// On a branch, by its name.
        case branch(name: String)
        /// Detached, at a commit.
        case detached(sha: String)
        /// On a branch with no commit yet, by its name.
        case unborn(branch: String)

        /// Names compare exactly, as git's do: two that differ only in
        /// Unicode normalization are two branches.
        public static func == (lhs: Head, rhs: Head) -> Bool {
            switch (lhs, rhs) {
            case (.branch(let x), .branch(let y)), (.detached(let x), .detached(let y)), (.unborn(let x), .unborn(let y)):
                JSCompat.strictEquals(x, y)
            default:
                false
            }
        }
    }

    /// An operation git stopped in and left for the user to finish.
    public enum StoppedOperation: Sendable, Equatable {
        case rebase
        /// A merge, or a squash merge with conflicts.
        case merge
        case cherryPick
        case revert
    }

    /// Nil when the status told neither a branch nor a commit.
    public var head: Head?
    /// Nil when the branch has no upstream (or the tip isn't a branch).
    public var aheadBehind: AheadBehind?
    public var changedFilesCount: Int
    /// The rebase, merge, cherry-pick, or revert stopped in the repository,
    /// if any.
    public var stoppedOperation: StoppedOperation?
    /// How many of the changed files have conflicts left to resolve: the
    /// files unmerged in the index that still have conflict markers, or
    /// that need a choice between versions (`getConflictedFiles`).
    public var conflictedFilesCount: Int

    public init(
        head: Head? = nil,
        aheadBehind: AheadBehind?,
        changedFilesCount: Int,
        stoppedOperation: StoppedOperation? = nil,
        conflictedFilesCount: Int = 0
    ) {
        self.head = head
        self.aheadBehind = aheadBehind
        self.changedFilesCount = changedFilesCount
        self.stoppedOperation = stoppedOperation
        self.conflictedFilesCount = conflictedFilesCount
    }

    /// The indicator for a status, with the tip and the operation in
    /// progress the refresher derived from it (`RepositoryGitState.tip` and
    /// `inProgress`), so the list says what the repository's own state does.
    public init(_ status: StatusResult, tip: Tip, inProgress: GitOperationInProgress?) {
        self.init(
            head: Head(tip),
            aheadBehind: status.branchAheadBehind,
            changedFilesCount: status.workingDirectory.files.count,
            stoppedOperation: inProgress.flatMap(StoppedOperation.init),
            conflictedFilesCount: getConflictedFiles(status.workingDirectory, [:]).count
        )
    }
}

extension RepositoryIndicator.Head {
    /// The head for a tip; nil for an unknown one.
    public init?(_ tip: Tip) {
        switch tip {
        case .valid(let branch):
            self = .branch(name: branch.name)
        case .detached(let sha):
            self = .detached(sha: sha)
        case .unborn(let ref):
            self = .unborn(branch: ref)
        case .unknown:
            return nil
        }
    }
}

extension RepositoryIndicator.StoppedOperation {
    /// The operation the list shows for one in progress; nil for a `git am`
    /// or a bisect, which the list doesn't show.
    public init?(_ inProgress: GitOperationInProgress) {
        switch inProgress {
        case .rebase:
            self = .rebase
        case .merge:
            self = .merge
        case .cherryPick:
            self = .cherryPick
        case .revert:
            self = .revert
        case .applyingPatches, .bisect:
            return nil
        }
    }
}
