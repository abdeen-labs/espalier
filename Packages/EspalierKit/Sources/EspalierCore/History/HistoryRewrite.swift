// The history list's checks before a squash or reorder. The history shows other
// branches too, so the commits involved are found on the current branch's
// first-parent line from HEAD: they must all be on it, and no merge commit may
// be among the commits from HEAD down to the oldest of them (those commits are
// replayed). When a merge is the only obstacle (the commits are below it, or
// came in with it), the check says so, so the UI can give the reason.

import GitKit

/// A squash or reorder of commits on the current branch: the commits, and
/// where the rewrite starts.
public struct CurrentBranchRewrite: Sendable, Equatable {
    /// The commits to squash or move, newest first.
    public let commits: [Commit]
    /// The commit the rewrite replays after (`<oldest involved>^`), or nil
    /// to rewrite from the branch's root.
    public let lastRetainedCommitRef: String?
    /// How far each involved commit is from HEAD along the first-parent
    /// line (0 is HEAD's commit).
    public let positions: [String: Int]

    public init(commits: [Commit], lastRetainedCommitRef: String?, positions: [String: Int]) {
        self.commits = commits
        self.lastRetainedCommitRef = lastRetainedCommitRef
        self.positions = positions
    }

    /// Whether moving the commits so they sit right below `base` (nil: at
    /// the top) changes nothing: the commits are adjacent on the line and
    /// already there, or `base` is one of them.
    public func isNoOpReorder(below base: String?) -> Bool {
        let indexes = commits.compactMap { positions[$0.sha] }.sorted()
        guard let first = indexes.first else {
            return true
        }
        let areContiguous = zip(indexes, indexes.dropFirst()).allSatisfy { $1 == $0 + 1 }
        guard areContiguous else {
            return false
        }
        guard let base, let basePosition = positions[base] else {
            return first == 0
        }
        return basePosition == first - 1 || indexes.contains(basePosition)
    }
}

/// Whether commits can be squashed or reordered on the current branch.
public enum CurrentBranchRewriteCheck: Sendable, Equatable {
    /// They can: the rewrite.
    case allowed(CurrentBranchRewrite)
    /// The commits are in the current branch's history, but a merge commit
    /// is among the commits the rewrite would replay: they're below a
    /// merge, or came in with one (`mergeCommitReplayedError`).
    case mergeCommitReplayed
    /// They can't, and there's nothing to explain: HEAD isn't on a branch,
    /// History shows a comparison, a commit isn't loaded, or one isn't in
    /// the current branch's history (cherry-pick it instead).
    case unavailable

    /// The rewrite, when it's allowed.
    public var rewrite: CurrentBranchRewrite? {
        if case .allowed(let rewrite) = self {
            return rewrite
        }
        return nil
    }
}

extension HistoryModel {
    /// The rewrite of `shas` relative to `target` (the commit to squash
    /// into, or the commit to move them below; nil for the top), or nil when
    /// it can't be done (`checkCurrentBranchRewrite`).
    public func currentBranchRewrite(moving shas: [String], relativeTo target: String?) -> CurrentBranchRewrite? {
        checkCurrentBranchRewrite(moving: shas, relativeTo: target).rewrite
    }

    /// Whether `shas` can be squashed into `target`, or moved below it (nil
    /// for the top): allowed when every commit is on the current branch's
    /// first-parent line with no merge commit from HEAD down to the oldest
    /// of them. Only the history (not a comparison) rewrites.
    public func checkCurrentBranchRewrite(moving shas: [String], relativeTo target: String?) -> CurrentBranchRewriteCheck {
        guard mode == .history, !shas.isEmpty, let head = repository?.gitState.tip.branch?.tip.sha else {
            return .unavailable
        }
        var involved = Set(shas)
        if let target {
            involved.insert(target)
        }
        // History is in topological order: the line can't reach an
        // involved commit below the lowest of them.
        var lowestRow = -1
        for sha in involved {
            guard let row = row(of: sha) else {
                // In the simple list, a commit an expanded merge brought in
                // is in the branch's history, and replaying it replays the
                // merge.
                return isSimpleListShown && mergedCommit(sha) != nil ? .mergeCommitReplayed : .unavailable
            }
            lowestRow = max(lowestRow, row)
        }
        var positions: [String: Int] = [:]
        var found = 0
        var next: String? = head
        var oldest: Commit?
        var position = 0
        var replaysMerge = false
        while found < involved.count, let sha = next {
            guard let commit = commit(sha), let row = row(of: sha), row <= lowestRow else {
                break
            }
            if commit.isMergeCommit {
                replaysMerge = true
            }
            if involved.contains(sha) {
                found += 1
                positions[sha] = position
                oldest = commit
            }
            position += 1
            next = commit.parentSHAs.first
        }
        guard found == involved.count, let oldest else {
            // Some commits are off the line: a merge brought them into the
            // branch, or they're another branch's.
            return replaysMerge && areReachable(involved, from: head, lowestRow: lowestRow) ? .mergeCommitReplayed : .unavailable
        }
        if replaysMerge {
            return .mergeCommitReplayed
        }
        let commits = shas.compactMap { sha in commit(sha) }.sorted { (positions[$0.sha] ?? 0) < (positions[$1.sha] ?? 0) }
        return .allowed(CurrentBranchRewrite(
            commits: commits,
            lastRetainedCommitRef: oldest.parentSHAs.isEmpty ? nil : "\(oldest.sha)^",
            positions: positions
        ))
    }

    /// Whether every commit in `shas` is reachable from `head` through the
    /// loaded commits, never walking below `lowestRow`, the lowest of them.
    private func areReachable(_ shas: Set<String>, from head: String, lowestRow: Int) -> Bool {
        var remaining = shas
        var queue = [head]
        var visited: Set<String> = []
        while let sha = queue.popLast(), !remaining.isEmpty {
            guard visited.insert(sha).inserted else {
                continue
            }
            remaining.remove(sha)
            guard let commit = commit(sha), let row = row(of: sha), row < lowestRow else {
                continue
            }
            queue.append(contentsOf: commit.parentSHAs)
        }
        return remaining.isEmpty
    }
}
