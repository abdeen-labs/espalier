// Ported from desktop/app/src/ui/toolbar/push-pull-button.tsx

import EspalierSupport
import GitKit

/// What the sync button does, as state, in order (the first that applies
/// wins).
public enum SyncAction: Sendable, Equatable {
    /// 1. A push, pull, or fetch runs: the button shows
    /// `RepositoryModel.networkOperation`'s progress (its title, and its
    /// description or "Hang on…") and is disabled.
    case inProgress
    /// Then, until the repository's status, remotes, and refs have loaded
    /// (`RepositoryGitState.hasLoadedRemoteState`): nothing, and disabled.
    /// A repository just selected may have only what its sidebar indicator
    /// loaded, without its remotes, which would read as one to publish.
    case loading
    /// 2. The repository has no remote: "Publish Repository".
    case publishRepository
    /// 3. and 6. "Fetch <remote>": the branch is unborn, or there's nothing
    /// to push or pull.
    case fetch(remote: String)
    /// 4. HEAD is detached: "Publish Branch", disabled.
    case detachedHead(rebaseInProgress: Bool)
    /// 5. The branch isn't published (it has no upstream, or its upstream is
    /// gone): "Publish Branch".
    case publishBranch(remote: String, isGitHubRepository: Bool)
    /// 7. Espalier rewrote the branch (rebase, squash, reorder, amend), its
    /// remote branch hasn't moved since, and it has diverged from its
    /// upstream: "Force push <remote>".
    case forcePush(remote: String, aheadBehind: AheadBehind, tagsToPush: Int)
    /// 8. The branch is behind: "Pull <remote>", or "Pull <remote> with
    /// rebase" when `pull.rebase` says so.
    case pull(remote: String, aheadBehind: AheadBehind, tagsToPush: Int, withRebase: Bool, forcePushAvailable: Bool)
    /// 9. "Push <remote>": commits or tags to push.
    case push(remote: String, aheadBehind: AheadBehind, tagsToPush: Int)

    /// The button's title; nil while in progress (the progress's title)
    /// and while loading.
    public var title: String? {
        switch self {
        case .inProgress, .loading:
            nil
        case .publishRepository:
            "Publish Repository"
        case .fetch(let remote):
            "Fetch \(remote)"
        case .detachedHead, .publishBranch:
            "Publish Branch"
        case .forcePush(let remote, _, _):
            "Force Push \(remote)"
        case .pull(let remote, _, _, let withRebase, _):
            withRebase ? "Pull \(remote) with Rebase" : "Pull \(remote)"
        case .push(let remote, _, _):
            "Push \(remote)"
        }
    }

    /// The button's description. Nil where it shows when the repository was
    /// last fetched: "Last fetched <relative date>" from
    /// `RepositoryGitState.lastFetched`, or "Never fetched" (fetch, force
    /// push, pull, push), while in progress (the progress's description,
    /// or "Hang on…"), and while loading.
    public var description: String? {
        switch self {
        case .publishRepository:
            "Publish this repository to GitHub"
        case .detachedHead(let rebaseInProgress):
            rebaseInProgress ? "Rebase in progress" : "Can't publish a detached HEAD"
        case .publishBranch(_, let isGitHubRepository):
            isGitHubRepository ? "Publish this branch to GitHub" : "Publish this branch to the remote"
        case .inProgress, .loading, .fetch, .forcePush, .pull, .push:
            nil
        }
    }

    /// Whether the button can be used.
    public var isEnabled: Bool {
        switch self {
        case .inProgress, .loading, .detachedHead:
            false
        default:
            true
        }
    }

    /// The counts next to the title: commits and queued tags to push, and
    /// commits to pull. Nil when there's nothing to show.
    public var counts: SyncCounts? {
        switch self {
        case .forcePush(_, let aheadBehind, let tags), .pull(_, let aheadBehind, let tags, _, _), .push(_, let aheadBehind, let tags):
            if aheadBehind.ahead == 0, aheadBehind.behind == 0, tags == 0 {
                return nil
            }
            return SyncCounts(toPush: aheadBehind.ahead + tags, toPull: aheadBehind.behind)
        default:
            return nil
        }
    }

    /// The other actions the button offers (its dropdown).
    public var alternatives: [SyncAlternative] {
        switch self {
        case .publishBranch(let remote, _), .forcePush(let remote, _, _), .push(let remote, _, _):
            [.fetch(remote: remote)]
        case .pull(let remote, _, _, _, let forcePushAvailable):
            forcePushAvailable ? [.fetch(remote: remote), .forcePush(remote: remote)] : [.fetch(remote: remote)]
        case .inProgress, .loading, .publishRepository, .fetch, .detachedHead:
            []
        }
    }
}

/// The counts the sync button shows.
public struct SyncCounts: Sendable, Equatable {
    /// Commits to push, plus the tags queued to push with them.
    public let toPush: Int
    /// Commits to pull.
    public let toPull: Int

    public init(toPush: Int, toPull: Int) {
        self.toPush = toPush
        self.toPull = toPull
    }
}

/// Another action the sync button offers.
public enum SyncAlternative: Sendable, Equatable {
    case fetch(remote: String)
    case forcePush(remote: String)

    public var title: String {
        switch self {
        case .fetch(let remote): "Fetch \(remote)"
        case .forcePush(let remote): "Force Push \(remote)"
        }
    }

    /// The description. A force push's adds `SyncAlternative.forcePushWarning`
    /// while force pushes aren't confirmed (the `confirmForcePush`
    /// preference is off).
    public var description: String {
        switch self {
        case .fetch(let remote): "Fetch the latest changes from \(remote)"
        case .forcePush(let remote): "Overwrite any changes on \(remote) with your local changes"
        }
    }

    /// The warning under the force push item when it won't ask first
    /// ("Warning:" is its title).
    public static let forcePushWarning = "Force pushing rewrites the branch's history on the remote. Anyone working on this branch will need to reset their local branch to match it."
}

extension SyncModel {
    /// What the sync button does now, derived from the repository's state.
    public var action: SyncAction {
        guard let repository else {
            return .publishRepository
        }
        if repository.networkOperation != nil {
            return .inProgress
        }

        let state = repository.gitState
        guard state.hasLoadedRemoteState else {
            return .loading
        }
        let tip = state.tip

        // The remote's name, or the branch's upstream remote, or the whole
        // upstream when the branch tracks a branch of another name.
        var remoteName = state.remotes.currentRemote?.name
        if case .valid(let branch) = tip, let upstreamRemoteName = branch.upstreamRemoteName {
            remoteName = upstreamRemoteName
            let tracksSameName = branch.upstreamWithoutRemote.map { JSCompat.strictEquals($0, branch.name) } ?? false
            if !tracksSameName {
                remoteName = branch.upstream
            }
        }

        guard let remoteName else {
            return .publishRepository
        }

        switch tip {
        case .unborn:
            return .fetch(remote: remoteName)
        case .detached:
            let rebaseInProgress = if case .rebase? = state.inProgress { true } else { false }
            return .detachedHead(rebaseInProgress: rebaseInProgress)
        case .valid, .unknown:
            break
        }

        // Status reports ahead/behind only for a published branch
        // (`RepositoryGitState.isCurrentBranchPublished`), so one whose
        // upstream is gone is published again, as the menu has it.
        guard let aheadBehind = state.aheadBehind else {
            return .publishBranch(remote: remoteName, isGitHubRepository: repository.record.gitHubRepository != nil)
        }

        let tagsToPush = repository.record.tagsToPush.count
        if aheadBehind.ahead == 0, aheadBehind.behind == 0, tagsToPush == 0 {
            return .fetch(remote: remoteName)
        }

        let forcePushState = repository.operations.forcePushState
        if forcePushState == .recommended {
            return .forcePush(remote: remoteName, aheadBehind: aheadBehind, tagsToPush: tagsToPush)
        }

        if aheadBehind.behind > 0 {
            return .pull(
                remote: remoteName,
                aheadBehind: aheadBehind,
                tagsToPush: tagsToPush,
                withRebase: state.branches.pullWithRebase ?? false,
                forcePushAvailable: forcePushState != .notAvailable
            )
        }

        return .push(remote: remoteName, aheadBehind: aheadBehind, tagsToPush: tagsToPush)
    }
}
