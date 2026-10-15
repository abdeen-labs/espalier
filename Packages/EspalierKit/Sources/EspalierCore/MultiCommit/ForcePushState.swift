// Ported from desktop/app/src/lib/rebase.ts

import EspalierSupport
import GitKit

/// Represents the force-push availability state of a branch.
public enum ForcePushBranchState: Sendable, Equatable {
    /// The branch cannot be force-pushed (it hasn't diverged from its upstream)
    case notAvailable

    /// The branch can be force-pushed, but the user didn't do any operation that
    /// we consider should be followed by a force-push, like rebasing or amending a
    /// pushed commit.
    case available

    /// The branch can be force-pushed, and the user did some operation that we
    /// consider should be followed by a force-push, like rebasing or amending a
    /// pushed commit.
    case recommended
}

/// Check application state to see whether the action applied to the current
/// branch should be a force push
///
/// - Parameters:
///   - tip: The repository's HEAD.
///   - forcePushBranches: The branches Espalier rewrote, by name without
///     the remote, to their upstream's tip when Espalier rewrote them.
///   - upstreamTip: The current branch's upstream's tip now; nil when it
///     isn't known.
///   - aheadBehind: How far the current branch is ahead of and behind its
///     upstream; nil without one.
public func getCurrentBranchForcePushState(
    tip: Tip,
    forcePushBranches: [String: String],
    upstreamTip: String?,
    aheadBehind: AheadBehind?
) -> ForcePushBranchState {
    guard let aheadBehind else {
        // no tracking branch found
        return .notAvailable
    }

    if aheadBehind.behind == 0 || aheadBehind.ahead == 0 {
        // no a diverged branch to force push
        return .notAvailable
    }

    // Recommended while the remote branch is where it was when Espalier
    // rewrote the branch, whatever the branch's tip since.
    var canForcePushBranch = false
    if case .valid(let branch) = tip, let upstreamTip {
        let localBranchName = branch.nameWithoutRemote
        let foundEntry = forcePushBranches[localBranchName]
        canForcePushBranch = foundEntry.map { JSCompat.strictEquals($0, upstreamTip) } ?? false
    }

    return canForcePushBranch ? .recommended : .available
}

extension MultiCommitOperationsModel {
    /// Branches whose history Espalier rewrote (amend, rebase, squash,
    /// reorder), by name without the remote, to their upstream's tip when
    /// Espalier rewrote them (`RepositoryRecord.rewrittenBranches`, saved
    /// with the repository list).
    public var rewrittenBranches: [String: String] {
        repository?.record.rewrittenBranches ?? [:]
    }

    /// Whether pushing the current branch can or should force.
    public var forcePushState: ForcePushBranchState {
        guard let repository else {
            return .notAvailable
        }
        let state = repository.gitState
        return getCurrentBranchForcePushState(
            tip: state.tip,
            forcePushBranches: rewrittenBranches,
            upstreamTip: state.tip.branch.flatMap { upstreamTip(of: $0) },
            aheadBehind: state.aheadBehind
        )
    }

    /// Records that `branch`'s history was rewritten from `previousTip`
    /// while its upstream was at `upstreamTip`, both read when the rewrite
    /// started: pushing it recommends force while the upstream stays there,
    /// and the force push leases against it.
    ///
    /// Only a rewrite that alone made the branch diverge is recorded: the
    /// branch before it (`previousTip`) contains `upstreamTip`. A branch
    /// that was already behind its remote branch records nothing (and loses
    /// any earlier record), so force pushing never drops commits the user
    /// never had. Nothing is recorded when the tip didn't change, and
    /// without an upstream tip there's nothing to force push over.
    func recordRewrite(of branch: Branch, previousTip: String, upstreamTip: String?) async {
        // if the commit id of the branch is unchanged, it can be excluded from
        // this list
        guard !JSCompat.strictEquals(branch.tip.sha, previousTip), let repository else {
            return
        }
        var recorded: String?
        if let upstreamTip {
            let gitRepository = repository.gitRepository
            let contained = await repository.environment.withRuntimes {
                await isAncestor(gitRepository, upstreamTip, of: previousTip)
            }
            recorded = contained ? upstreamTip : nil
        }
        updateRewrittenBranches { $0[branch.nameWithoutRemote] = recorded }
    }

    /// The upstream's tip for a rewrite whose start Espalier didn't see (a
    /// rebase started elsewhere, or before a relaunch): the current
    /// branch's, if it's `branchName`, as last loaded. `recordRewrite`
    /// counts it only if the branch had it before the rewrite, so a remote
    /// branch that a fetch moved during the rewrite recommends nothing.
    func currentUpstreamTip(of branchName: String) -> String? {
        guard let branch = repository?.gitState.tip.branch, JSCompat.strictEquals(branch.name, branchName) else {
            return nil
        }
        return upstreamTip(of: branch)
    }

    /// Forgets that `branch` was rewritten, after it was force pushed.
    func forgetRewrite(of branch: Branch) {
        updateRewrittenBranches { $0[branch.nameWithoutRemote] = nil }
    }

    /// Keeps a rewritten branch's entry when the branch is renamed, so the
    /// renamed branch keeps its force push recommendation.
    func renameRewrite(from oldName: String, to newName: String) {
        guard let upstreamTip = rewrittenBranches[oldName] else {
            return
        }
        updateRewrittenBranches { rewritten in
            rewritten[oldName] = nil
            rewritten[newName] = upstreamTip
        }
    }

    /// Forgets the rewritten branches whose remote branch moved since the
    /// rewrite (a force push, someone else's push a fetch brought in), or
    /// that are gone, once the branches have loaded: they no longer
    /// recommend a force push. Nothing is forgotten while no branch is
    /// loaded.
    func forgetMovedRewrites() {
        guard let repository else {
            return
        }
        let rewritten = rewrittenBranches
        let branches = repository.gitState.branches.all
        guard !rewritten.isEmpty, !branches.isEmpty else {
            return
        }
        let kept = rewritten.filter { name, upstreamTip in
            guard let branch = branches.first(where: { $0.type == .local && JSCompat.strictEquals($0.name, name) }) else {
                return false
            }
            return self.upstreamTip(of: branch).map { JSCompat.strictEquals($0, upstreamTip) } ?? false
        }
        if kept.count != rewritten.count {
            updateRewrittenBranches { $0 = kept }
        }
    }

    /// The tip of `branch`'s upstream as the branches were last loaded; nil
    /// without one or before they've loaded. Never newer than git's: a
    /// recorded tip read from it can only end a recommendation sooner.
    func upstreamTip(of branch: Branch) -> String? {
        repository?.gitState.branches.upstreams[ExactString(branch.ref)]?.tip.sha
    }

    /// Changes the rewritten branches in the repository's record, which
    /// saves them.
    private func updateRewrittenBranches(_ change: (inout [String: String]) -> Void) {
        guard let repository, let app = repository.app else {
            return
        }
        app.updateRecord(repository.id) { change(&$0.rewrittenBranches) }
    }
}

/// The tip of the upstream of the branch named `branchName`, as git has it
/// now; nil without one, or when its remote-tracking branch is gone.
func getUpstreamTip(_ repository: Repository, branchName: String) async -> String? {
    await resolveCommit(repository, "\(branchName)@{upstream}")
}
