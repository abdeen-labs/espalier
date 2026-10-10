// History's simple mode.
//
// The simple list is the current branch's history following first parents (or,
// in another branch's place, that branch's), one commit after another,
// ungrouped, so a merged branch is one row. Its commits
// are the history's rows, as the graph's are in Graph mode
// (`HistoryModel.commit(atRow:)`; there's no uncommitted-work row). A merge's
// row can expand to the commits it brought in, loaded on demand; the outline
// lists the rows with those commits under their merges. Above the list, a
// notice says when the base branch (the one Update from <branch> merges) has
// commits the branch doesn't.

import EspalierSupport
import Foundation
import GitKit

/// How History shows commits (the `history-style` preference).
public enum HistoryStyle: String, Sendable, Hashable, CaseIterable {
    /// The current branch's first-parent line, one commit after another.
    case simple
    /// The commits of the history's scope, with the graph.
    case graph

    /// The style's name in the History header.
    public var title: String {
        switch self {
        case .simple: "Simple"
        case .graph: "Graph"
        }
    }
}

/// The base branch has commits the current branch doesn't.
public struct SimpleHistoryBaseStatus: Sendable, Hashable {
    /// The base: the branch Update from <branch> merges (the default
    /// branch, or a fork's parent's).
    public let branch: Branch
    /// How many commits the base has that the current branch doesn't.
    public let newCommitCount: Int

    public init(branch: Branch, newCommitCount: Int) {
        self.branch = branch
        self.newCommitCount = newCommitCount
    }

    /// The base's name ("main", "upstream/main").
    public var name: String {
        branch.name
    }
}

/// Where the current branch began on the simple list's line, which takes
/// the base's color from there.
public struct SimpleHistoryStart: Sendable, Hashable {
    /// The base: the branch Update from <branch> merges.
    public let base: Branch
    /// The row of the commit the branch started from: the first on the
    /// line the base has. The rows above it are the branch's own.
    public let row: Int

    public init(base: Branch, row: Int) {
        self.base = base
        self.row = row
    }
}

/// One line of the simple list, top to bottom.
public enum SimpleHistoryItem: Sendable, Hashable {
    /// A commit on the first-parent line, by its row
    /// (`HistoryModel.simpleRow(atRow:)`).
    case commit(row: Int)
    /// A commit an expanded merge brought in: the merge's row and the
    /// commit's position among its commits
    /// (`HistoryModel.simpleMergedRow(mergeRow:index:)`).
    case mergedCommit(mergeRow: Int, index: Int)
    /// After an expanded merge's commits: they're loading, couldn't load,
    /// or there are more than shown (`HistoryModel.mergedCommits(ofRow:)`).
    case mergedCommitsStatus(mergeRow: Int)
}

/// The simple list's lines for the commits loaded: each row, with the
/// commits of each expanded merge under it.
public struct SimpleHistoryOutline: Sendable, Equatable {
    /// The lines, top to bottom.
    public internal(set) var items: [SimpleHistoryItem] = []
    /// The item of each row's commit.
    var itemIndexByRow: [Int] = []

    public init() {}

    /// The position in `items` of the commit in `row`, if it's loaded.
    public func itemIndex(ofRow row: Int) -> Int? {
        itemIndexByRow.indices.contains(row) ? itemIndexByRow[row] : nil
    }
}

/// What a merge commit's row shows besides the commit.
public struct SimpleHistoryMerge: Sendable, Hashable {
    /// The merged branch, as the merge's message names it.
    public let branchName: String?
    /// The pull request's number, for a pull request merge.
    public let pullRequestNumber: Int?
    /// Whether the row shows the commits the merge brought in.
    public let isExpanded: Bool

    public init(branchName: String?, pullRequestNumber: Int?, isExpanded: Bool) {
        self.branchName = branchName
        self.pullRequestNumber = pullRequestNumber
        self.isExpanded = isExpanded
    }
}

/// What a row of the simple list shows.
public struct SimpleHistoryRow: Sendable, Equatable {
    public let commit: Commit
    /// The tags pointing at the commit, by name.
    public let tags: [String]
    /// Whether the upstream (or, before the branch is published, every
    /// remote) doesn't have the commit.
    public let isUnpushed: Bool
    /// How many files the commit changed (a merge against its first
    /// parent).
    public let changedFileCount: Int
    /// For a merge commit: what it merged, and whether it's expanded.
    public let merge: SimpleHistoryMerge?

    public init(commit: Commit, tags: [String], isUnpushed: Bool, changedFileCount: Int, merge: SimpleHistoryMerge?) {
        self.commit = commit
        self.tags = tags
        self.isUnpushed = isUnpushed
        self.changedFileCount = changedFileCount
        self.merge = merge
    }
}

/// The commits an expanded merge brought in.
public struct SimpleMergedCommits: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case loading
        case loaded
        case failed(OperationError)
    }

    public let state: State
    /// How many commits are loaded (`HistoryModel.simpleMergedRow`).
    public let count: Int
    /// Whether the merge brought in more commits than are loaded (the
    /// graph shows them all).
    public let hasMore: Bool

    public init(state: State, count: Int, hasMore: Bool) {
        self.state = state
        self.count = count
        self.hasMore = hasMore
    }
}

// MARK: - Internals

/// What the simple list's rows are marked unpushed against.
enum SimpleUnpushedReference: Sendable, Hashable {
    /// The current branch's upstream and its commit.
    case upstream(sha: String)
    /// Every remote's branches: the branch isn't published.
    case remotes
}

/// What a simple list is loaded from, captured on the main actor from the
/// refresh's state.
struct SimpleHistorySource: Sendable, Equatable {
    /// The commit the line starts from: HEAD's, or the tip of the branch
    /// shown instead (`HistoryModel.showBranch(ref:)`); nil on an unborn
    /// branch.
    var head: String?
    /// The base branch with its commit; nil on a detached HEAD, an unborn
    /// branch, the base itself, or when there's no base.
    var base: Branch?
    /// What rows are marked unpushed against; nil on a detached HEAD, an
    /// unborn branch, a remote branch, or without a remote.
    var unpushedReference: SimpleUnpushedReference?
    /// Whether the line is HEAD's. Another branch's line shows where it
    /// started, but not the base's notice: Update merges into the current
    /// branch.
    var isHead = true
}

/// What the simple list knows besides its commits, counted with git.
struct SimpleHistoryFrame: Sendable, Equatable {
    var source: SimpleHistorySource
    /// The commits on the first-parent line that `unpushedReference`
    /// doesn't have: the first rows.
    var unpushedCount = 0
    /// The commits the base has that the branch doesn't.
    var behindCount = 0
    /// Whether the branch and the base have a merge base.
    var sharesHistoryWithBase = false
    /// The commits on the first-parent line the base doesn't have: the
    /// rows above the one the branch started from. Nil without a base, or
    /// when git couldn't count them.
    var ownCommitCount: Int?

    /// The base's new commits, when the line is HEAD's, the base has any,
    /// and the branch shares history with it.
    var baseStatus: SimpleHistoryBaseStatus? {
        guard source.isHead, let base = source.base, behindCount > 0, sharesHistoryWithBase else {
            return nil
        }
        return SimpleHistoryBaseStatus(branch: base, newCommitCount: behindCount)
    }

    /// Where the branch started, when it shares history with the base.
    var start: SimpleHistoryStart? {
        guard let base = source.base, sharesHistoryWithBase, let ownCommitCount else {
            return nil
        }
        return SimpleHistoryStart(base: base, row: ownCommitCount)
    }

    /// Whether `row` isn't pushed.
    func isUnpushed(row: Int) -> Bool {
        row < unpushedCount
    }
}

/// What a row shows besides its commit, read with the page.
struct SimpleCommitDetails: Sendable {
    let changedFileCount: Int
    /// For a merge commit: what its message says it merged.
    let merge: MergeCommitSummary?

    init(_ commit: CommitWithChangedFileCount) {
        changedFileCount = commit.changedFileCount
        merge = commit.commit.isMergeCommit ? MergeCommitSummary(commit.commit.summary) : nil
    }
}

/// The simple list's commits (the history's rows) and their details.
struct SimpleHistoryList: Sendable {
    var commits: CommitList
    var details: [SimpleCommitDetails]

    /// Where the next page starts: the last commit's first parent; nil once
    /// the list is complete.
    var nextStart: String? {
        commits.isComplete ? nil : commits.commits.last?.parentSHAs.first
    }
}

/// The commits a merge brought in, as loaded.
struct LoadedMergedCommits: Sendable {
    var commits: [Commit]
    var details: [SimpleCommitDetails]
    /// The ones that aren't pushed.
    var unpushed: Set<String>
    var hasMore: Bool
}

/// A merge's commits, loaded when it was first expanded and kept while
/// it's collapsed.
struct MergedCommitsExpansion: Sendable {
    var load: Loadable<LoadedMergedCommits, OperationError>
    /// The unpushed reference the commits' unpushed state was read for.
    var unpushedReference: SimpleUnpushedReference?
    var isExpanded: Bool
    /// The load in flight's number; a finished load applies only if it's
    /// still the latest.
    var loadID: UInt64 = 0
}

/// The outline of `list`: its rows, with the commits of each merge expanded
/// in `expansions` (by merge SHA) under it.
func makeSimpleHistoryOutline(list: SimpleHistoryList, expansions: [String: MergedCommitsExpansion]) -> SimpleHistoryOutline {
    var outline = SimpleHistoryOutline()
    let commits = list.commits.commits
    outline.itemIndexByRow.reserveCapacity(commits.count)
    var items: [SimpleHistoryItem] = []
    items.reserveCapacity(commits.count)
    for (row, commit) in commits.enumerated() {
        outline.itemIndexByRow.append(items.count)
        items.append(.commit(row: row))
        guard commit.isMergeCommit, let expansion = expansions[commit.sha], expansion.isExpanded else {
            continue
        }
        switch expansion.load {
        case .loaded(let merged):
            for index in merged.commits.indices {
                items.append(.mergedCommit(mergeRow: row, index: index))
            }
            if merged.hasMore {
                items.append(.mergedCommitsStatus(mergeRow: row))
            }
        case .loading(let previous):
            for index in (previous?.commits ?? []).indices {
                items.append(.mergedCommit(mergeRow: row, index: index))
            }
            items.append(.mergedCommitsStatus(mergeRow: row))
        case .failed, .idle:
            items.append(.mergedCommitsStatus(mergeRow: row))
        }
    }
    outline.items = items
    return outline
}
