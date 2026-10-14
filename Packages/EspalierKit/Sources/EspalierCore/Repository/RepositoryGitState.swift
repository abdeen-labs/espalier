import EspalierSupport
import Foundation
import GitKit
import Observation

/// The repository's git state as the last refresh pass loaded it.
///
/// Only `RepositoryRefresher` writes it, and only when a value changed, so a
/// view reading one property isn't invalidated by a pass that changed
/// another (observable setters always notify).
@MainActor @Observable
public final class RepositoryGitState {
    /// HEAD: a branch, a detached commit, an unborn branch, or unknown.
    public internal(set) var tip: Tip = .unknown
    /// How far the current branch is ahead of and behind its upstream.
    public internal(set) var aheadBehind: AheadBehind?
    /// The merge, rebase, cherry-pick, or revert in progress, if any.
    public internal(set) var inProgress: GitOperationInProgress?
    public internal(set) var branches = BranchesSnapshot()
    public internal(set) var remotes = RemotesSnapshot()
    /// Tag name to the SHA of the commit it points at; nil before the first
    /// load.
    public internal(set) var tags: [String: String]?
    public internal(set) var stashes = StashSnapshot()
    public internal(set) var worktrees: [WorktreeEntry] = []
    /// The identity git commits as (`git var GIT_AUTHOR_IDENT`).
    public internal(set) var commitAuthor: CommitIdentity?
    /// When the repository was last fetched (`FETCH_HEAD`'s modification
    /// date), if ever.
    public internal(set) var lastFetched: Date?
    /// The current branch's commits that aren't on its upstream (or on any
    /// remote), newest first, at most 100.
    public internal(set) var localCommitSHAs: [String] = []
    /// The tip `localCommitSHAs` and the branches were loaded for; a status
    /// showing another tip loads them again.
    @ObservationIgnored var refsTip: RefsTip?
    /// Counts the changes the features were told about (a pass's status,
    /// then its other steps), so features can tell a new snapshot.
    public internal(set) var generation: UInt64 = 0
    /// What the passes have loaded since the state was last reset (a new
    /// model, or a new path): a scope is here once a pass's steps for it
    /// have landed. A repository only the sidebar's status indicator
    /// refreshed hasn't loaded its remotes yet.
    public internal(set) var loaded: RefreshScope = []

    /// Whether the status, remotes, and refs have all loaded since the
    /// last reset. Before then, the remotes and the branch's upstream
    /// aren't known: a repository without them reads as one to publish.
    public var hasLoadedRemoteState: Bool {
        loaded.isSuperset(of: [.status, .remotes, .refs])
    }

    init() {}
}

/// The branches of a repository.
public struct BranchesSnapshot: Sendable, Equatable {
    /// Local branches and the remote branches no local branch tracks
    /// (`mergeRemoteAndLocalBranches`).
    public var all: [Branch] = []
    /// The default branch (`findDefaultBranch`).
    public var defaultBranch: Branch?
    /// The parent's default branch, for forks contributing to it.
    public var upstreamDefaultBranch: Branch?
    /// The most recently checked out branches, at most five, without the
    /// default branch.
    public var recent: [Branch] = []
    /// `pull.rebase`: true or false, nil when unset or unrecognized.
    public var pullWithRebase: Bool?
    /// Each local branch's upstream, by the local branch's ref, when the
    /// upstream is a branch of the same listing (a remote-tracking branch,
    /// or a local branch for `branch.<name>.remote = .`): its full ref and
    /// tip. The upstream states key their cache by the two tips
    /// (BranchUpstreamStates.swift).
    public var upstreams: [ExactString: Branch]

    public init(
        all: [Branch] = [],
        defaultBranch: Branch? = nil,
        upstreamDefaultBranch: Branch? = nil,
        recent: [Branch] = [],
        pullWithRebase: Bool? = nil,
        upstreams: [ExactString: Branch] = [:]
    ) {
        self.all = all
        self.defaultBranch = defaultBranch
        self.upstreamDefaultBranch = upstreamDefaultBranch
        self.recent = recent
        self.pullWithRebase = pullWithRebase
        self.upstreams = upstreams
    }
}

/// The remotes of a repository.
public struct RemotesSnapshot: Sendable, Equatable {
    public var all: [Remote] = []
    /// `origin`, or else the first remote (`findDefaultRemote`).
    public var defaultRemote: Remote?
    /// The current branch's upstream remote if it exists, else the default.
    public var currentRemote: Remote?
    /// The remote pointing at a fork's parent (`findUpstreamRemote`).
    public var upstreamRemote: Remote?
    /// The names of the fork remotes Espalier added, which the repository's
    /// configuration marks (`getForkRemoteNames`): their branches are hidden
    /// and they're pruned once unused. Empty when the marks can't be read.
    public var forkRemoteNames: Set<ExactString>

    public init(
        all: [Remote] = [],
        defaultRemote: Remote? = nil,
        currentRemote: Remote? = nil,
        upstreamRemote: Remote? = nil,
        forkRemoteNames: Set<ExactString> = []
    ) {
        self.all = all
        self.defaultRemote = defaultRemote
        self.currentRemote = currentRemote
        self.upstreamRemote = upstreamRemote
        self.forkRemoteNames = forkRemoteNames
    }
}

/// The stash entries with an automatic stash marker.
public struct StashSnapshot: Sendable, Equatable {
    /// The newest entry with an automatic stash marker (`!!Espalier<branch>`
    /// or `!!GitHub_Desktop<branch>`) per branch name.
    public var entriesByBranch: [String: StashEntry] = [:]
    /// How many stash entries there are, made by anything.
    public var totalCount = 0

    public init(entriesByBranch: [String: StashEntry] = [:], totalCount: Int = 0) {
        self.entriesByBranch = entriesByBranch
        self.totalCount = totalCount
    }
}

/// An operation git has in progress in the repository, as status shows it.
public enum GitOperationInProgress: Sendable, Equatable {
    /// A merge (`MERGE_HEAD`), or a squash merge with conflicts
    /// (`SQUASH_MSG`).
    case merge(squash: Bool)
    case rebase(RebaseInternalState)
    case cherryPick
    /// A revert (`REVERT_HEAD`).
    case revert
    /// `git am` stopped on a patch (`rebase-apply/applying`), which
    /// Espalier can't continue or abort.
    case applyingPatches
    /// A bisect (`BISECT_START`), which Espalier can't continue or end.
    case bisect
}

extension GitOperationInProgress {
    /// For an operation only git can continue or abort, why Espalier can't
    /// and what to run instead; nil for the ones Espalier continues.
    public var unsupportedMessage: String? {
        switch self {
        case .applyingPatches:
            "Git is applying patches (git am) and stopped on one. Espalier can't continue or abort it: in Terminal, run git am --continue after resolving it, or git am --skip or git am --abort."
        case .bisect:
            "A bisect is in progress. Espalier can't continue or end it: in Terminal, mark commits with git bisect good or git bisect bad, and end it with git bisect reset."
        case .merge, .rebase, .cherryPick, .revert:
            nil
        }
    }

    /// For an operation only git can continue or abort, a short note that
    /// it's in progress and where to finish it; nil for the others.
    public var unsupportedSummary: String? {
        switch self {
        case .applyingPatches:
            "Git is applying patches (git am). Finish in Terminal."
        case .bisect:
            "A bisect is in progress. Finish in Terminal."
        case .merge, .rebase, .cherryPick, .revert:
            nil
        }
    }

    /// For an operation only git can continue or abort, its name for a
    /// title; nil for the others.
    public var unsupportedTitle: String? {
        switch self {
        case .applyingPatches:
            "Applying patches"
        case .bisect:
            "Bisect in progress"
        case .merge, .rebase, .cherryPick, .revert:
            nil
        }
    }
}

extension Tip {
    /// The branch, when HEAD is on one with a commit.
    public var branch: Branch? {
        if case .valid(let branch) = self { branch } else { nil }
    }

    /// Whether HEAD is on a branch with a commit (a valid tip).
    public var isValidBranch: Bool {
        branch != nil
    }

    /// The commit HEAD points at, if any.
    public var sha: String? {
        switch self {
        case .valid(let branch): branch.tip.sha
        case .detached(let sha): sha
        case .unborn, .unknown: nil
        }
    }
}

/// A tip as the refs loaded for it see it: its commit and its branch.
struct RefsTip: Equatable, Sendable {
    let sha: String?
    let branch: String?

    init(_ tip: Tip) {
        sha = tip.sha
        branch = tip.branch?.name
    }
}
