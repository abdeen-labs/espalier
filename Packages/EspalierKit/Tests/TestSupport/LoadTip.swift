// Ported from desktop/app/src/lib/stores/git-store.ts (`loadStatus`'s tip)
//
// The tip, computed from `getStatus` and `getCommit` for the branch and
// checkout tests.

import GitKit

/// The repository's tip, from its status and its tip commit.
///
/// - Returns: `.unknown` when git status fails.
/// - Throws: when the tip commit of the current branch can't be loaded.
public func loadTip(_ repository: Repository) async throws -> Tip {
    guard let status = try await getStatus(repository) else {
        return .unknown
    }

    // JavaScript's truthiness: an empty string counts as missing.
    let currentBranch = status.currentBranch.flatMap { $0.isEmpty ? nil : $0 }
    let currentTip = status.currentTip.flatMap { $0.isEmpty ? nil : $0 }

    if let currentTip, let currentBranch {
        guard let branchTipCommit = try await getCommit(repository, currentTip) else {
            throw TestSupportError("Could not load commit: '\(currentTip)'")
        }

        let branch = Branch(
            name: currentBranch,
            upstream: status.currentUpstreamBranch.flatMap { $0.isEmpty ? nil : $0 },
            tip: BranchTip(sha: branchTipCommit.sha),
            type: .local,
            ref: "refs/heads/\(currentBranch)"
        )
        return .valid(branch: branch)
    } else if let currentTip {
        return .detached(currentSha: currentTip)
    } else if let currentBranch {
        return .unborn(ref: currentBranch)
    }

    return .unknown
}
