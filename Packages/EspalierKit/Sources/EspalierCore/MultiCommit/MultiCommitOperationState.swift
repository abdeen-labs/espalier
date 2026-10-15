// Ported in part from desktop/app/src/models/multi-commit-operation.ts
//
// The operation's phase derives from git's state.

import GitKit

/// The details of a multi-commit operation, by kind.
public enum MultiCommitOperationDetail: Sendable, Equatable {
    case merge(sourceBranch: Branch?, isSquash: Bool)
    case rebase(sourceBranch: Branch?, commits: [CommitOneLine], currentTip: String)
    case cherryPick(sourceBranch: Branch?, branchCreated: Bool, commits: [CommitOneLine])
    case squash(commits: [Commit], currentTip: String, lastRetainedCommitRef: String?, targetCommit: Commit, commitContext: CommitContext)
    case reorder(commits: [Commit], currentTip: String, lastRetainedCommitRef: String?, beforeCommit: Commit?)
    /// The commit being reverted; nil for a revert rebuilt from `.git` until
    /// `REVERT_HEAD` is read.
    case revert(commit: Commit?)
}

/// Where a multi-commit operation is.
public enum MultiCommitOperationPhase: Sendable, Equatable {
    case running(MultiCommitOperationProgress)
    /// Stopped on conflicts (from the status pass).
    case conflicted
    /// Continuing after conflicts were resolved.
    case continuing(MultiCommitOperationProgress)
    /// A rebase that stopped between two commits without conflicts, its git
    /// process killed (a quit, a crash) or paused by a `break` or a failed
    /// `exec` of a rebase run elsewhere: git keeps its state directory but no
    /// `REBASE_HEAD`. It can be continued or aborted.
    case interrupted
}

/// A merge, rebase, cherry-pick, squash, reorder, or revert that Espalier
/// started or found in progress.
public struct MultiCommitOperation: Sendable, Equatable {
    /// Who started it.
    public enum Origin: Sendable, Equatable {
        /// Espalier started it in this session.
        case espalier
        /// Rebuilt from `.git` after launch or an external command.
        case rebuilt
    }

    public let kind: MultiCommitOperationKind
    public var detail: MultiCommitOperationDetail
    public var phase: MultiCommitOperationPhase
    /// Whether the user has resolved conflicts in this operation (in any of
    /// its rounds): aborting then asks first.
    public var userHasResolvedConflicts: Bool
    public var originalBranchTip: String?
    /// The tip of the target branch's upstream when Espalier started the
    /// operation, which a completed rewrite is recorded with for the force
    /// push recommendation (`recordRewrite`); nil without an upstream, and
    /// for an operation rebuilt from `.git`.
    public var originalUpstreamTip: String?
    public var targetBranch: Branch?
    public let origin: Origin

    public init(
        kind: MultiCommitOperationKind,
        detail: MultiCommitOperationDetail,
        phase: MultiCommitOperationPhase,
        userHasResolvedConflicts: Bool = false,
        originalBranchTip: String? = nil,
        originalUpstreamTip: String? = nil,
        targetBranch: Branch? = nil,
        origin: Origin
    ) {
        self.kind = kind
        self.detail = detail
        self.phase = phase
        self.userHasResolvedConflicts = userHasResolvedConflicts
        self.originalBranchTip = originalBranchTip
        self.originalUpstreamTip = originalUpstreamTip
        self.targetBranch = targetBranch
        self.origin = origin
    }

    /// Whether this is a squash merge.
    public var isSquashMerge: Bool {
        if case .merge(_, let isSquash) = detail { isSquash } else { false }
    }

    /// What the conflicts banner says while the operation waits for the user
    /// ("Resolve conflicts to continue merging into main.").
    public var conflictsMessage: String {
        let prefix: String = switch detail {
        case .merge: "merging into"
        case .rebase: "rebasing"
        case .cherryPick: "cherry-picking onto"
        case .squash: "squashing commits on"
        case .reorder: "reordering commits on"
        case .revert: "reverting on"
        }
        guard let targetBranch else {
            return "Resolve conflicts to continue \(prefix)."
        }
        return "Resolve conflicts to continue \(prefix) \(targetBranch.name)."
    }

    /// What to say about a rebase that git was interrupted in (phase
    /// `.interrupted`).
    public var interruptedMessage: String {
        guard let targetBranch else {
            return "A rebase was interrupted. Continue or abort it."
        }
        return "Rebasing \(targetBranch.name) was interrupted. Continue or abort the rebase."
    }

    /// The number of commits it changes, for its banners: the commits
    /// rebased, cherry-picked, or reordered; for a squash, the commits
    /// squashed and the one they're squashed into.
    var commitCount: Int {
        switch detail {
        case .merge: 0
        case .rebase(_, let commits, _): commits.count
        case .cherryPick(_, _, let commits): commits.count
        case .squash(let commits, _, _, _, _): commits.count + 1
        case .reorder(let commits, _, _, _): commits.count
        case .revert: 1
        }
    }
}

/// What a merge did. `summary` is the banner copy.
public enum MergeOutcome: Sendable, Equatable {
    /// The branch was merged (or squash merged). `theirs` is nil when a
    /// conflicted merge Espalier didn't start was finished and the branch it
    /// merged isn't known.
    case merged(ours: String, theirs: String?)
    /// Nothing to merge.
    case alreadyUpToDate(ours: String, theirs: String)
    /// Stopped on conflicts; `conflictState` has them.
    case conflicted

    /// The banner copy; nil for conflicts, whose state is
    /// `MultiCommitOperation.conflictsMessage`.
    public var summary: String? {
        switch self {
        case .merged(let ours, let theirs?):
            "Merged \(theirs) into \(ours)"
        case .merged(let ours, nil):
            "Merged into \(ours)"
        case .alreadyUpToDate(let ours, let theirs):
            "\(ours) is already up to date with \(theirs)"
        case .conflicted:
            nil
        }
    }
}

/// How an operation that can stop on conflicts ended (a pull's outcome;
/// `MultiCommitResult.outcome` for the others).
public enum MultiCommitOutcome: Sendable, Equatable {
    case completed
    case alreadyUpToDate
    /// Stopped on conflicts; `conflictState` has them.
    case conflicted
}

/// What a rebase, cherry-pick, squash, reorder, or revert did. `summary` is
/// the banner copy.
public enum MultiCommitResult: Sendable, Equatable {
    /// The branch was rebased. `baseBranch` is nil when the rebase wasn't
    /// started by Espalier (rebuilt from `.git`) and its base isn't known.
    case rebased(targetBranch: String, baseBranch: String?)
    /// Nothing to rebase.
    case alreadyUpToDate(ours: String, theirs: String)
    /// The commits were copied to the branch (the local branch checked out,
    /// also when a remote branch was the target).
    case cherryPicked(count: Int, targetBranch: String)
    /// The commits were squashed: `count` counts them all, the commit they
    /// were squashed into too.
    case squashed(count: Int)
    case reordered(count: Int)
    case reverted
    /// Stopped on conflicts; `conflictState` has them.
    case conflicted

    /// How it ended.
    public var outcome: MultiCommitOutcome {
        switch self {
        case .rebased, .cherryPicked, .squashed, .reordered, .reverted: .completed
        case .alreadyUpToDate: .alreadyUpToDate
        case .conflicted: .conflicted
        }
    }

    /// The banner copy; nil for a revert, which has no banner, and for
    /// conflicts, whose state is `MultiCommitOperation.conflictsMessage`. The
    /// banners of squash, reorder, and cherry-pick offer Undo: see
    /// `operations.undo`.
    public var summary: String? {
        switch self {
        case .rebased(let target, let base?):
            "Rebased \(target) onto \(base)"
        case .rebased(let target, nil):
            "Rebased \(target)"
        case .alreadyUpToDate(let ours, let theirs):
            "\(ours) is already up to date with \(theirs)"
        case .cherryPicked(let count, let target):
            "Copied \(count) \(commitsNoun(count)) to \(target)."
        case .squashed(let count):
            "Squashed \(count) \(commitsNoun(count))."
        case .reordered(let count):
            "Reordered \(count) \(commitsNoun(count))."
        case .reverted, .conflicted:
            nil
        }
    }
}

/// "commit" or "commits", as the banners pluralize.
func commitsNoun(_ count: Int) -> String {
    count == 1 ? "commit" : "commits"
}

/// What continuing an operation after its conflicts did.
public enum ContinueOutcome: Sendable, Equatable {
    /// The merge was committed (`.merged`).
    case merge(MergeOutcome)
    /// A rebase, squash, reorder, cherry-pick, or revert went on: it
    /// completed, or stopped on the next conflicts.
    case multiCommit(MultiCommitResult)
}

/// The branches on each side of the conflicts, for labels such as "Use the
/// modified file from main". Either may be unknown.
public struct ConflictBranches: Sendable, Equatable {
    public var ours: String?
    public var theirs: String?

    public init(ours: String?, theirs: String?) {
        self.ours = ours
        self.theirs = theirs
    }
}
