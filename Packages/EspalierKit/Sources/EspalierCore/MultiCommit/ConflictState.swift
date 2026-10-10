// Ported in part from desktop/app/src/lib/app-state.ts
//
// Derived from status on every pass by the reducer in
// ConflictReconciler.swift.

import EspalierSupport
import GitKit

/// The conflicts of the operation in progress, with the manual resolutions
/// the user chose.
public enum ConflictState: Sendable, Equatable {
    case merge(currentBranch: String, currentTip: String, manualResolutions: [String: ManualConflictResolution])
    case rebase(
        currentTip: String,
        targetBranch: String,
        baseBranch: String?,
        originalBranchTip: String,
        baseBranchTip: String,
        manualResolutions: [String: ManualConflictResolution]
    )
    case cherryPick(targetBranchName: String, manualResolutions: [String: ManualConflictResolution])
    case revert(targetBranchName: String, manualResolutions: [String: ManualConflictResolution])

    /// The manual resolutions chosen so far, by path.
    public var manualResolutions: [String: ManualConflictResolution] {
        switch self {
        case .merge(_, _, let resolutions),
             .rebase(_, _, _, _, _, let resolutions),
             .cherryPick(_, let resolutions),
             .revert(_, let resolutions):
            resolutions
        }
    }

    /// The branch the operation changes: the merge's current branch, the
    /// branch being rebased, or the cherry-pick's or revert's target.
    public var targetBranchName: String {
        switch self {
        case .merge(let currentBranch, _, _): currentBranch
        case .rebase(_, let targetBranch, _, _, _, _): targetBranch
        case .cherryPick(let targetBranchName, _), .revert(let targetBranchName, _): targetBranchName
        }
    }

    /// The same conflicts with other manual resolutions.
    func withManualResolutions(_ resolutions: [String: ManualConflictResolution]) -> ConflictState {
        switch self {
        case .merge(let currentBranch, let currentTip, _):
            .merge(currentBranch: currentBranch, currentTip: currentTip, manualResolutions: resolutions)
        case .rebase(let currentTip, let targetBranch, let baseBranch, let originalBranchTip, let baseBranchTip, _):
            .rebase(
                currentTip: currentTip,
                targetBranch: targetBranch,
                baseBranch: baseBranch,
                originalBranchTip: originalBranchTip,
                baseBranchTip: baseBranchTip,
                manualResolutions: resolutions
            )
        case .cherryPick(let targetBranchName, _):
            .cherryPick(targetBranchName: targetBranchName, manualResolutions: resolutions)
        case .revert(let targetBranchName, _):
            .revert(targetBranchName: targetBranchName, manualResolutions: resolutions)
        }
    }

    /// Whether `other` is a later look at the same operation's conflicts,
    /// so the manual resolutions chosen so far still apply.
    ///
    /// A merge keeps its branch and HEAD until it ends; a rebase keeps the
    /// branch it rebases and the tips it started from (`rebase-merge`'s
    /// files), while HEAD moves from round to round; a cherry-pick or revert
    /// keeps its target branch. Carried over to another operation's
    /// conflicts, the resolutions would apply old choices to files the user
    /// hadn't chosen for.
    func isSameOperation(as other: ConflictState) -> Bool {
        switch (self, other) {
        case (.merge(let branch, let tip, _), .merge(let otherBranch, let otherTip, _)):
            JSCompat.strictEquals(branch, otherBranch) && JSCompat.strictEquals(tip, otherTip)
        case (.rebase(_, let target, _, let original, let base, _), .rebase(_, let otherTarget, _, let otherOriginal, let otherBase, _)):
            JSCompat.strictEquals(target, otherTarget)
                && JSCompat.strictEquals(original, otherOriginal)
                && JSCompat.strictEquals(base, otherBase)
        case (.cherryPick(let target, _), .cherryPick(let otherTarget, _)),
             (.revert(let target, _), .revert(let otherTarget, _)):
            JSCompat.strictEquals(target, otherTarget)
        default:
            false
        }
    }
}
