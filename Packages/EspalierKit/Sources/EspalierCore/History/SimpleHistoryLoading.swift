// Loading History's simple mode (SimpleHistory.swift) off the main actor. A
// page is one `git log --first-parent` with each commit's changed-file count
// (`getCommitsWithChangedFileCounts`), starting from a commit rather than a ref
// and skipping nothing, so pages stay consistent while refs move. The unpushed
// rows and the base's new commits come from a few counts
// (`git rev-list --count`), loaded with the first page, as does where the
// branch started (the rows the base doesn't have).

import EspalierSupport
import Foundation
import GitKit

/// A page of the simple list.
struct SimplePage: Sendable {
    var commits: [Commit]
    var details: [SimpleCommitDetails]
    var isLastPage: Bool
    /// The page's rows matching the search query it was loaded with.
    var searchRows: [Int]?
}

/// Loads up to `limit` commits of the first-parent line from `start` (a
/// commit), with their details.
///
/// - Parameter firstRow: The row of `start` in the list, for search rows.
@concurrent
func loadSimplePage(
    _ context: HistoryLoadContext,
    from start: String,
    limit: Int,
    firstRow: Int,
    search: SearchQuery?
) async throws -> SimplePage {
    let loaded = try await context.environment.withRuntimes {
        try await getCommitsWithChangedFileCounts(
            context.repository,
            revisions: [start],
            limit: limit,
            additionalArgs: ["--first-parent"]
        )
    }
    try Task.checkCancellation()
    let commits = loaded.map(\.commit)
    var searchRows: [Int]?
    if let search {
        searchRows = await searchMatchingRows(commits[...], query: search, rowOffset: firstRow)
    }
    return SimplePage(
        commits: commits,
        details: loaded.map(SimpleCommitDetails.init),
        // A root commit (or a shallow clone's last) ends the line.
        isLastPage: loaded.count < limit || loaded.last?.commit.parentSHAs.isEmpty != false,
        searchRows: searchRows
    )
}

/// The simple list's commits laid out as one line: a builder that sees only
/// first parents.
func simpleListBuilder(head: String?) -> CommitGraphBuilder {
    CommitGraphBuilder(options: CommitGraphOptions(trunkTip: head, headSHA: head))
}

/// The commits of a page as the simple list's line sees them.
func simpleGraphCommits(_ commits: [Commit]) -> [CommitGraphCommit] {
    commits.map { CommitGraphCommit(sha: $0.sha, parentSHAs: Array($0.parentSHAs.prefix(1))) }
}

/// A simple list as loaded: its first commits and its frame.
struct LoadedSimpleHistory: Sendable {
    var list: SimpleHistoryList
    var frame: SimpleHistoryFrame
    var shas: [String]
    var searchRows: [Int]?
}

/// Loads the first `count` commits of the simple list for `source` and its
/// frame, in parallel.
@concurrent
func loadSimpleHistory(
    _ context: HistoryLoadContext,
    _ source: SimpleHistorySource,
    count: Int,
    search: SearchQuery?
) async -> Result<LoadedSimpleHistory, OperationError> {
    guard let head = source.head else {
        // An unborn branch: no commits yet.
        var builder = simpleListBuilder(head: nil)
        builder.finish()
        return .success(LoadedSimpleHistory(
            list: SimpleHistoryList(commits: CommitList(commits: [], builder: builder, isComplete: true), details: []),
            frame: SimpleHistoryFrame(source: source),
            shas: [],
            searchRows: search == nil ? nil : []
        ))
    }
    do {
        async let frame = loadSimpleFrame(context, source)
        let page = try await loadSimplePage(context, from: head, limit: count, firstRow: 0, search: search)
        var builder = simpleListBuilder(head: head)
        builder.append(simpleGraphCommits(page.commits))
        if page.isLastPage {
            builder.finish()
        }
        let list = SimpleHistoryList(
            commits: CommitList(commits: page.commits, builder: builder, isComplete: page.isLastPage),
            details: page.details
        )
        return .success(LoadedSimpleHistory(
            list: list,
            frame: await frame,
            shas: page.commits.map(\.sha),
            searchRows: page.searchRows
        ))
    } catch {
        return .failure(await context.failure(error, .loadHistory))
    }
}

/// Counts what the simple list for `source` knows besides its commits: its
/// unpushed rows, the base's new commits, whether it shares history with
/// the branch, and the line's commits it doesn't have (where the branch
/// started). A count git can't make leaves its mark or notice out rather
/// than failing the history.
@concurrent
func loadSimpleFrame(_ context: HistoryLoadContext, _ source: SimpleHistorySource) async -> SimpleHistoryFrame {
    guard let head = source.head else {
        return SimpleHistoryFrame(source: source)
    }
    let repository = context.repository
    return await context.environment.withRuntimes { () async -> SimpleHistoryFrame in
        var frame = SimpleHistoryFrame(source: source)
        async let unpushed = countUnpushed(repository, head: head, source.unpushedReference)
        if let base = source.base?.tip.sha {
            async let behind = countCommits(repository, [base, "^\(head)"], firstParent: false)
            async let mergeBase = try? getMergeBase(repository, head, base)
            // The base's history is a suffix of the line: once a commit on
            // it is the base's, so are its ancestors.
            async let own = countCommits(repository, [head, "^\(base)"], firstParent: true)
            frame.behindCount = await behind ?? 0
            frame.sharesHistoryWithBase = await mergeBase != nil
            frame.ownCommitCount = await own
        }
        frame.unpushedCount = await unpushed ?? 0
        return frame
    }
}

/// The commits on the first-parent line from `head` that `reference`
/// doesn't have; nil when git fails.
@concurrent
private func countUnpushed(_ repository: Repository, head: String, _ reference: SimpleUnpushedReference?) async -> Int? {
    switch reference {
    case .upstream(let sha)?:
        await countCommits(repository, [head, "^\(sha)"], firstParent: true)
    case .remotes?:
        await countCommits(repository, [head], firstParent: true, excludingRemotes: true)
    case nil:
        0
    }
}

/// `git rev-list --count` of `revisions` (`^<sha>` excludes a history),
/// following first parents when asked, without the commits every remote
/// branch has when asked; nil when git fails.
@concurrent
func countCommits(
    _ repository: Repository,
    _ revisions: [String],
    firstParent: Bool,
    excludingRemotes: Bool = false
) async -> Int? {
    var args = ["rev-list", "--count"]
    if firstParent {
        args.append("--first-parent")
    }
    // Revisions on standard input are read as given, whatever `--not`
    // says on the command line.
    args.append("--stdin")
    if excludingRemotes {
        args.append(contentsOf: ["--not", "--remotes"])
    }
    let input = revisions.map { "\($0)\n" }.joined()
    guard let result = try? await git(args, repository.path, "countHistoryCommits", options: GitExecutionOptions(stdin: input)) else {
        return nil
    }
    return JSCompat.parseInt(JSCompat.trim(result.stdout))
}

/// Loads up to `limit` (nil: all) of the commits `merge` brought in (those
/// its other parents have and its first parent doesn't), newest first in
/// topological order, and which of them aren't pushed when the merge isn't.
@concurrent
func loadMergedCommits(
    _ context: HistoryLoadContext,
    merge: Commit,
    isMergeUnpushed: Bool,
    unpushedReference: SimpleUnpushedReference?,
    limit: Int?
) async -> Result<LoadedMergedCommits, OperationError> {
    guard let firstParent = merge.parentSHAs.first, merge.parentSHAs.count > 1 else {
        return .success(LoadedMergedCommits(commits: [], details: [], unpushed: [], hasMore: false))
    }
    let revisions = Array(merge.parentSHAs.dropFirst()) + ["^\(firstParent)"]
    let repository = context.repository
    do {
        return try await context.environment.withRuntimes { () async throws -> Result<LoadedMergedCommits, OperationError> in
            async let unpushedSHAs: [String]? = isMergeUnpushed
                ? listUnpushed(repository, revisions, unpushedReference)
                : []
            let loaded = try await getCommitsWithChangedFileCounts(
                repository,
                revisions: revisions,
                limit: limit.map { $0 + 1 },
                additionalArgs: ["--topo-order"]
            )
            let shown = loaded.prefix(limit ?? loaded.count)
            return .success(LoadedMergedCommits(
                commits: shown.map(\.commit),
                details: shown.map(SimpleCommitDetails.init),
                unpushed: Set(await unpushedSHAs ?? []),
                hasMore: loaded.count > shown.count
            ))
        }
    } catch {
        return .failure(await context.failure(error, .loadHistory))
    }
}

/// The commits of `revisions` that `reference` doesn't have; nil when git
/// fails.
@concurrent
private func listUnpushed(
    _ repository: Repository,
    _ revisions: [String],
    _ reference: SimpleUnpushedReference?
) async -> [String]? {
    var input = revisions
    var args = ["rev-list", "--stdin"]
    switch reference {
    case .upstream(let sha)?:
        input.append("^\(sha)")
    case .remotes?:
        args.append(contentsOf: ["--not", "--remotes"])
    case nil:
        return []
    }
    let stdin = input.map { "\($0)\n" }.joined()
    guard let result = try? await git(args, repository.path, "listUnpushedCommits", options: GitExecutionOptions(stdin: stdin)) else {
        return nil
    }
    return JSCompat.split(result.stdout, "\n").filter { !$0.isEmpty }
}

/// Where a commit is on the first-parent line from `head`.
enum FirstParentPosition: Sendable, Equatable {
    /// On the line, at this row.
    case onLine(row: Int)
    /// Brought in by the merge `merge`, at this row.
    case inMerge(row: Int, merge: String)
    /// Not in `head`'s history.
    case notInHistory
}

/// Finds `sha` on the first-parent line from `head`, or the merge on the
/// line that brought it in: the oldest commit on the line that has it,
/// found by halving (each step one `git merge-base --is-ancestor`).
@concurrent
func findOnFirstParentLine(_ repository: Repository, _ sha: String, head: String) async -> FirstParentPosition {
    // The line's commits that `sha` doesn't have come before it (or before
    // the commits that have it).
    guard let above = await countCommits(repository, [head, "^\(sha)"], firstParent: true) else {
        return .notInHistory
    }
    if await resolveHistoryCommit(repository, "\(head)~\(above)") == sha {
        return .onLine(row: above)
    }
    guard above > 0, await isAncestor(repository, sha, of: head) else {
        return .notInHistory
    }
    // Rows 0..<above may have it, and having it is a prefix of them: find
    // the last row that does.
    var low = 0
    var high = above - 1
    while low < high {
        let middle = (low + high + 1) / 2
        if await isAncestor(repository, sha, of: "\(head)~\(middle)") {
            low = middle
        } else {
            high = middle - 1
        }
    }
    guard let merge = await resolveHistoryCommit(repository, "\(head)~\(low)") else {
        return .notInHistory
    }
    return .inMerge(row: low, merge: merge)
}

/// `git merge-base --is-ancestor`: whether `ancestor` is in `descendant`'s
/// history (a commit is in its own).
@concurrent
func isAncestor(_ repository: Repository, _ ancestor: String, of descendant: String) async -> Bool {
    guard let result = try? await git(
        ["merge-base", "--is-ancestor", "--end-of-options", ancestor, descendant],
        repository.path,
        "isAncestor",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    ) else {
        return false
    }
    return result.exitCode == 0
}
