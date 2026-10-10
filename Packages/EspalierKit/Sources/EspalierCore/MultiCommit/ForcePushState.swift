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
///     the remote, to the tip it left them at.
///   - aheadBehind: How far the current branch is ahead of and behind its
///     upstream; nil without one.
public func getCurrentBranchForcePushState(
    tip: Tip,
    forcePushBranches: [String: String],
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

    var canForcePushBranch = false
    if case .valid(let branch) = tip {
        let localBranchName = branch.nameWithoutRemote
        let sha = branch.tip.sha
        let foundEntry = forcePushBranches[localBranchName]
        canForcePushBranch = foundEntry.map { JSCompat.strictEquals($0, sha) } ?? false
    }

    return canForcePushBranch ? .recommended : .available
}

extension MultiCommitOperationsModel {
    /// Whether pushing the current branch can or should force.
    public var forcePushState: ForcePushBranchState {
        guard let repository else {
            return .notAvailable
        }
        return getCurrentBranchForcePushState(
            tip: repository.gitState.tip,
            forcePushBranches: rewrittenBranches,
            aheadBehind: repository.gitState.aheadBehind
        )
    }

    /// Records that `branch`'s history was rewritten from `previousTip`, so
    /// the next push needs force. Nothing is recorded when the tip didn't
    /// change.
    func recordRewrite(of branch: Branch, previousTip: String) {
        // if the commit id of the branch is unchanged, it can be excluded from
        // this list
        guard !JSCompat.strictEquals(branch.tip.sha, previousTip) else {
            return
        }
        rewrittenBranches[branch.nameWithoutRemote] = branch.tip.sha
    }

    /// Forgets that `branch` was rewritten, after it was force pushed.
    func forgetRewrite(of branch: Branch) {
        if rewrittenBranches[branch.nameWithoutRemote] != nil {
            rewrittenBranches[branch.nameWithoutRemote] = nil
        }
    }

    /// Keeps a rewritten branch's entry when the branch is renamed, so the
    /// renamed branch keeps its force push recommendation.
    func renameRewrite(from oldName: String, to newName: String) {
        guard let tip = rewrittenBranches[oldName] else {
            return
        }
        rewrittenBranches[oldName] = nil
        rewrittenBranches[newName] = tip
    }
}
