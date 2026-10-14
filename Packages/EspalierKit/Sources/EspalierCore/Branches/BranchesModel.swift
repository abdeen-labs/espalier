// The intents live in CheckoutOperation.swift (checking out branches and
// commits), BranchOperations.swift (creating, renaming, deleting),
// TagOperations.swift, AheadBehindCache.swift, BranchGrouping.swift, and
// BranchUpstreamStates.swift.

import GitKit
import Observation

/// Branches and tags: checking out, creating, renaming, deleting.
@MainActor @Observable
public final class BranchesModel: RepositoryFeature {
    @ObservationIgnored weak var repository: RepositoryModel?

    /// Ahead/behind counts of pairs of commits, for branch lists.
    @ObservationIgnored let aheadBehindCache = AheadBehindCache()
    /// The author dates of branch tips, for branch lists
    /// (BranchTipDates.swift).
    @ObservationIgnored let tipDateCache = BranchTipDateCache()
    /// How the local branches on screen compare with their upstreams
    /// (BranchUpstreamStates.swift).
    @ObservationIgnored let upstreamStatesLoader = UpstreamStatesLoader()

    /// How local branches compare with their upstreams, by the branch's
    /// full ref (`refs/heads/main`): the branches rows on screen watch
    /// (`watchUpstreamState(of:)`), and the others already compared at
    /// their current commits. Branches without an upstream, or not loaded
    /// yet, are left out.
    public internal(set) var upstreamStates: [String: BranchUpstreamState] = [:]

    init() {
        upstreamStatesLoader.host = self
    }

    func attach(to repository: RepositoryModel) {
        self.repository = repository
        upstreamStatesLoader.branchesDidChange(repository.gitState.branches)
    }

    /// The branch list's groups: the default branch, the recent branches,
    /// and the others.
    public var groups: [BranchGroup] {
        guard let repository else {
            return []
        }
        let state = repository.gitState
        return groupBranches(
            state.branches.defaultBranch,
            state.tip.branch,
            state.branches.all,
            state.branches.recent,
            forkRemoteNames: state.remotes.forkRemoteNames
        )
    }

    func repositoryDidRefresh(_ update: RefreshUpdate) {
        // Refs changed (a fetch may have brought missing commits): failed
        // comparisons may succeed now.
        if update.applied.contains(.refs) {
            aheadBehindCache.forgetFailures()
            if let repository {
                upstreamStatesLoader.branchesDidChange(repository.gitState.branches)
            }
        }
    }

    func repositoryPathDidChange(keepingSharedState: Bool) {
        // Another worktree shares the objects; another path may not.
        if keepingSharedState {
            aheadBehindCache.forgetFailures()
        } else {
            aheadBehindCache.removeAll()
            tipDateCache.removeAll()
        }
        upstreamStatesLoader.reset(keepingCache: keepingSharedState)
        if let repository {
            upstreamStatesLoader.branchesDidChange(repository.gitState.branches)
        }
    }
}
