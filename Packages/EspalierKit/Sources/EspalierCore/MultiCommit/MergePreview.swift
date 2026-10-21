// Ported in part from desktop/app/src/ui/multi-commit-operation/choose-branch/merge-choose-branch-dialog.tsx
//
// What merging a branch into the current one would do, for the status
// lines of the merge sheet and Compare, before anything runs, and when the
// merge can start. Read-only.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "merge")

/// What merging a branch into the current branch would do.
public struct MergePreview: Sendable, Equatable {
    /// Clean, conflicted (and in how many files), or impossible (unrelated
    /// histories), `.loading` while git works it out; nil when git couldn't
    /// tell.
    public let status: MergeTreeResult?
    /// The commits the merge brings in: those the branch has that the
    /// current branch doesn't (0 when the current branch is up to date, or
    /// the histories are unrelated); nil when git couldn't count them.
    public let commitCount: Int?

    public init(status: MergeTreeResult?, commitCount: Int?) {
        self.status = status
        self.commitCount = commitCount
    }

    /// Whether a merge or squash merge can start, in Compare and the merge
    /// sheet: git has checked, the branch brings in commits, and the
    /// histories are related. Conflicts don't stop it, and neither does a
    /// check git couldn't make (no status) or commits it couldn't count.
    public var canStart: Bool {
        switch status {
        case .loading?, .invalid?:
            false
        case .clean?, .conflicts?, nil:
            commitCount.map { $0 > 0 } ?? true
        }
    }
}

extension MultiCommitOperationsModel {
    /// What merging `branch` into the current branch would do: `git merge-tree`
    /// for the outcome, then how many commits it brings in (`HEAD...branch`).
    /// Either one git fails at is nil (logged); unrelated histories are
    /// invalid, with no count. Nil without a current branch.
    public func mergePreview(of branch: Branch) async -> MergePreview? {
        guard let repository, let currentBranch = repository.gitState.tip.branch else {
            return nil
        }
        let gitRepository = repository.gitRepository
        return await repository.environment.withRuntimes { () async -> MergePreview? in
            let status: MergeTreeResult?
            do {
                status = try await determineMergeability(gitRepository, currentBranch, branch)
            } catch {
                logger.error("Failed determining mergeability: \(error.localizedDescription, privacy: .public)")
                status = nil
            }
            // Can't go forward if the merge status is invalid, no need to
            // check commit count.
            if status == .invalid {
                return MergePreview(status: .invalid, commitCount: 0)
            }
            // Commit count is used in the UI output as well as determining
            // whether the submit button is enabled.
            let commitCount: Int?
            do {
                // The branch's full ref, which the merge merges: git reads its
                // short name as a tag of that name first.
                commitCount = try await getAheadBehind(gitRepository, revSymmetricDifference("", branch.ref))?.behind
            } catch {
                logger.error("Failed counting the commits to merge: \(error.localizedDescription, privacy: .public)")
                commitCount = nil
            }
            return MergePreview(status: status, commitCount: commitCount)
        }
    }
}
