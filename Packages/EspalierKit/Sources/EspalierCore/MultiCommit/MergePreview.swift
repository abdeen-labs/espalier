// Ported in part from desktop/app/src/ui/multi-commit-operation/choose-branch/merge-choose-branch-dialog.tsx
//
// What merging a branch into the current one would do, for the merge
// sheet's status line, before anything runs. Read-only.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "merge")

/// What merging a branch into the current branch would do.
public struct MergePreview: Sendable, Equatable {
    /// Clean, conflicted (and in how many files), or impossible (unrelated
    /// histories).
    public let status: MergeTreeResult
    /// The commits the merge brings in: those the branch has that the
    /// current branch doesn't (0 when the current branch is up to date).
    public let commitCount: Int

    public init(status: MergeTreeResult, commitCount: Int) {
        self.status = status
        self.commitCount = commitCount
    }
}

extension MultiCommitOperationsModel {
    /// What merging `branch` into the current branch would do: `git merge-tree`
    /// for the outcome, then how many commits it brings in (`HEAD...branch`). A
    /// merge-tree failure counts as clean (logged), a count that can't be read
    /// is 0, and unrelated histories are invalid, with no count. Nil without a
    /// current branch.
    public func mergePreview(of branch: Branch) async -> MergePreview? {
        guard let repository, let currentBranch = repository.gitState.tip.branch else {
            return nil
        }
        let gitRepository = repository.gitRepository
        return await repository.environment.withRuntimes { () async -> MergePreview? in
            let status: MergeTreeResult
            do {
                status = try await determineMergeability(gitRepository, currentBranch, branch)
            } catch {
                logger.error("Failed determining mergeability: \(error.localizedDescription, privacy: .public)")
                status = .clean
            }
            // Can't go forward if the merge status is invalid, no need to
            // check commit count.
            if status == .invalid {
                return MergePreview(status: status, commitCount: 0)
            }
            // Commit count is used in the UI output as well as determining
            // whether the submit button is enabled.
            guard let aheadBehind = try? await getAheadBehind(gitRepository, revSymmetricDifference("", branch.name)) else {
                return MergePreview(status: status, commitCount: 0)
            }
            return MergePreview(status: status, commitCount: aheadBehind.behind)
        }
    }
}
