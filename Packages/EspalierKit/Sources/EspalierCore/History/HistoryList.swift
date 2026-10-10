// A list of commits owns its graph layout (`CommitGraphBuilder`), is paged
// off the main actor, and is dropped with the history it belongs to.

import EspalierSupport
import GitKit

/// How the last change to the history's list touched its rows, for a view
/// that draws them.
///
/// Changes can coalesce between two observations: a view that remembers how
/// many rows it drew and how many of them were stable can always redraw from
/// its own stable row count, and reloads everything when `reloadGeneration`
/// moved.
public struct HistoryGraphChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The list was replaced (a new tip, scope, or mode): every row.
        case reload
        /// Commits were appended: `insertedRows` are new, and `relaidRows`
        /// were provisional and are drawn again.
        case append
    }

    public let kind: Kind
    /// One more for every change.
    public let generation: UInt64
    /// One more for every reload; appends keep it.
    public let reloadGeneration: UInt64
    /// Rows that were drawn before and changed: the provisional rows an
    /// append laid out again. Empty for a reload.
    public let relaidRows: Range<Int>
    /// Rows that are new: every row for a reload.
    public let insertedRows: Range<Int>

    public init(kind: Kind, generation: UInt64, reloadGeneration: UInt64, relaidRows: Range<Int>, insertedRows: Range<Int>) {
        self.kind = kind
        self.generation = generation
        self.reloadGeneration = reloadGeneration
        self.relaidRows = relaidRows
        self.insertedRows = insertedRows
    }

    /// The rows to redraw: relaid and inserted.
    public var changedRows: Range<Int> {
        relaidRows.isEmpty ? insertedRows : relaidRows.lowerBound..<insertedRows.upperBound
    }
}

/// A list of commits (a history, or a comparison's commits) with its graph.
struct CommitList: Sendable {
    /// Distinguishes this list from the ones before it; the model numbers
    /// lists as it shows them.
    var id: UInt64 = 0
    private(set) var commits: [Commit] = []
    /// A commit's index by SHA (its first appearance).
    private(set) var indexBySHA: [String: Int] = [:]
    var layout: CommitGraphLayout
    /// The builder the next page appends to; nil while a page is loading
    /// off the main actor, and once the list is complete.
    var builder: CommitGraphBuilder?
    private(set) var isComplete: Bool

    /// A list of `commits`, laid out by `builder`. Build it off the main
    /// actor: indexing a long list takes a while.
    init(commits: [Commit], builder: CommitGraphBuilder, isComplete: Bool) {
        layout = builder.layout
        self.builder = isComplete ? nil : builder
        self.isComplete = isComplete
        append(commits)
    }

    /// The first row of a commit: after the uncommitted-work row, if any.
    var rowOffset: Int {
        layout.hasUncommittedWorkRow ? 1 : 0
    }

    /// The row of the commit with `sha`, if it's loaded.
    func row(of sha: String) -> Int? {
        indexBySHA[sha].map { $0 + rowOffset }
    }

    /// The commit in `row`; nil for the uncommitted-work row or a row out of
    /// range.
    func commit(atRow row: Int) -> Commit? {
        let index = row - rowOffset
        return commits.indices.contains(index) ? commits[index] : nil
    }

    func commit(_ sha: String) -> Commit? {
        indexBySHA[sha].map { commits[$0] }
    }

    /// Appends a page laid out by `builder`.
    mutating func append(_ page: [Commit], builder: CommitGraphBuilder, isComplete: Bool) {
        append(page)
        layout = builder.layout
        self.builder = isComplete ? nil : builder
        self.isComplete = isComplete
    }

    private mutating func append(_ page: [Commit]) {
        indexBySHA.reserveCapacity(commits.count + page.count)
        for (offset, commit) in page.enumerated() where indexBySHA[commit.sha] == nil {
            indexBySHA[commit.sha] = commits.count + offset
        }
        commits.append(contentsOf: page)
    }
}

/// A page of commits laid out off the main actor, and the builder (returned
/// whether or not the page loaded, so it's never lost).
struct PageOutcome: Sendable {
    var builder: CommitGraphBuilder
    var result: Result<LoadedPage, any Error>
}

struct LoadedPage: Sendable {
    var commits: [Commit]
    var shas: [String]
    var isLastPage: Bool
    /// The page's rows matching the search query it was loaded with.
    var searchRows: [Int]?
}

/// Loads `limit` commits from `revisions` after the first `skip`, in
/// topological order, and lays them out with `builder`.
@concurrent
func loadCommitPage(
    _ context: HistoryLoadContext,
    revisions: [String],
    skip: Int,
    limit: Int,
    builder: consuming CommitGraphBuilder,
    search: SearchQuery?,
    rowOffset: Int
) async -> PageOutcome {
    do {
        let commits = try await context.environment.withRuntimes {
            try await getCommits(context.repository, revisions: revisions, limit: limit, skip: skip, additionalArgs: ["--topo-order"])
        }
        try Task.checkCancellation()
        let isLastPage = commits.count < limit
        builder.append(commits.map(CommitGraphCommit.init))
        if isLastPage {
            builder.finish()
        }
        var searchRows: [Int]?
        if let search {
            searchRows = await searchMatchingRows(commits[...], query: search, rowOffset: rowOffset + skip)
        }
        return PageOutcome(builder: builder, result: .success(LoadedPage(
            commits: commits,
            shas: commits.map(\.sha),
            isLastPage: isLastPage,
            searchRows: searchRows
        )))
    } catch {
        return PageOutcome(builder: builder, result: .failure(error))
    }
}

/// A history list as loaded: where from, its trunk, and its first commits.
struct LoadedHistory: Sendable {
    var source: HistorySource
    var refs: RefListing
    var trunkTip: String?
    var list: CommitList
    /// The list's SHAs, in order.
    var shas: [String]
    var searchRows: [Int]?
}

/// What checking whether the history changed found.
enum HistoryCheckOutcome: Sendable {
    /// The history's source didn't change; the refs may have.
    case unchanged(RefListing)
    case loaded(LoadedHistory)
    case failed(OperationError)
}

/// What a history check needs, captured on the main actor.
struct HistoryCheckRequest: Sendable {
    var scope: HistoryScope
    var head: String?
    var defaultBranchRef: String?
    var defaultBranchSHA: String?
    /// The current list's source; nil to load anyway.
    var current: HistorySource?
    /// The current list's commits (their indexes by SHA).
    var loadedCommits: [String: Int] = [:]
    /// How many commits to load.
    var count: Int
    var search: SearchQuery?
}

/// Lists the refs and, when the history's source changed (or there's no
/// current one), loads its first `count` commits and lays them out with the
/// uncommitted-work row on top.
@concurrent
func loadHistoryIfChanged(_ context: HistoryLoadContext, _ request: HistoryCheckRequest) async -> HistoryCheckOutcome {
    do {
        return try await context.environment.withRuntimes { () async throws -> HistoryCheckOutcome in
            let refs = try await listRefs(context.repository, includingTags: request.scope == .allBranches)
            let source = HistorySource(
                scope: request.scope,
                head: request.head,
                refs: refs,
                defaultBranchRef: request.defaultBranchRef,
                defaultBranchSHA: request.defaultBranchSHA
            )
            if let current = request.current, current.shows(sameCommitsAs: source, loaded: request.loadedCommits) {
                return .unchanged(refs)
            }
            async let trunkTip = resolveTrunkTip(context.repository, source)
            let commits = try await getCommits(
                context.repository,
                revisions: source.revisions,
                limit: request.count,
                additionalArgs: ["--topo-order"]
            )
            let isComplete = commits.count < request.count
            let trunk = await trunkTip
            var builder = CommitGraphBuilder(options: CommitGraphOptions(
                trunkTip: trunk,
                includesUncommittedWork: true,
                headSHA: source.head
            ))
            builder.append(commits.map(CommitGraphCommit.init))
            if isComplete {
                builder.finish()
            }
            var searchRows: [Int]?
            if let search = request.search {
                searchRows = await searchMatchingRows(commits[...], query: search, rowOffset: 1)
            }
            return .loaded(LoadedHistory(
                source: source,
                refs: refs,
                trunkTip: trunk,
                list: CommitList(commits: commits, builder: builder, isComplete: isComplete),
                shas: commits.map(\.sha),
                searchRows: searchRows
            ))
        }
    } catch {
        return .failed(await context.failure(error, .loadHistory))
    }
}

/// A comparison's list as loaded.
struct LoadedComparison: Sendable {
    var aheadBehind: AheadBehind
    var list: CommitList
    /// The list's SHAs, in order.
    var shas: [String]
}

/// Compares `current` with `branch`: how far apart they are, and the commits of
/// `direction` (all of them: a comparison isn't paged), laid out with the
/// newest commit's line straight. Nil when git can't compare them (a commit is
/// gone).
@concurrent
func loadComparison(
    _ context: HistoryLoadContext,
    current: Branch,
    branch: Branch,
    direction: ComparisonDirection
) async -> Result<LoadedComparison?, OperationError> {
    do {
        return try await context.environment.withRuntimes { () async throws -> Result<LoadedComparison?, OperationError> in
            guard let aheadBehind = try await getAheadBehind(
                context.repository,
                revSymmetricDifference(current.tip.sha, branch.tip.sha)
            ) else {
                return .success(nil)
            }
            let (range, count) = switch direction {
            case .ahead: (revRange(branch.tip.sha, current.tip.sha), aheadBehind.ahead)
            case .behind: (revRange(current.tip.sha, branch.tip.sha), aheadBehind.behind)
            }
            let commits = count > 0
                ? try await getCommits(context.repository, range, limit: count, additionalArgs: ["--topo-order"])
                : []
            var builder = CommitGraphBuilder(options: CommitGraphOptions(trunkTip: commits.first?.sha))
            builder.append(commits.map(CommitGraphCommit.init))
            builder.finish()
            return .success(LoadedComparison(
                aheadBehind: aheadBehind,
                list: CommitList(commits: commits, builder: builder, isComplete: true),
                shas: commits.map(\.sha)
            ))
        }
    } catch {
        return .failure(await context.failure(error, .loadHistory))
    }
}

/// The number of commits the history starts from reaches
/// (`git rev-list --count`).
@concurrent
func countCommits(_ context: HistoryLoadContext, revisions: [String]) async -> Int? {
    guard !revisions.isEmpty else {
        return 0
    }
    let input = revisions.map { "\($0)\n" }.joined()
    guard let result = try? await context.environment.withRuntimes({
        try await git(["rev-list", "--count", "--stdin"], context.repository.path, "countHistoryCommits", options: GitExecutionOptions(stdin: input))
    }) else {
        return nil
    }
    return JSCompat.parseInt(JSCompat.trim(result.stdout))
}

/// Whether `sha` is reachable from `revisions`: nothing it reaches is
/// left once their history is taken away.
@concurrent
func isReachable(_ context: HistoryLoadContext, _ sha: String, from revisions: [String]) async -> Bool {
    guard !revisions.isEmpty else {
        return false
    }
    let input = "\(sha)\n--not\n" + revisions.map { "\($0)\n" }.joined()
    guard let result = try? await context.environment.withRuntimes({
        try await git(["rev-list", "--count", "--stdin"], context.repository.path, "isInHistory", options: GitExecutionOptions(stdin: input))
    }) else {
        return false
    }
    return JSCompat.parseInt(JSCompat.trim(result.stdout)) == 0
}
