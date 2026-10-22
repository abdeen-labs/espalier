// The history draws a graph, shows more than HEAD's commits (the scope), keeps
// the uncommitted-work row on top, and can be searched. It reloads only when
// the commits the history starts from change, keeping as many commits as were
// loaded. Its simple style (the default) shows the current branch's
// first-parent line, one commit after another, instead of the graph
// (HistoryModel+SimpleMode.swift); rows, selection, search, and Go to Commit
// work on whichever list shows. Another branch's place shows that branch's
// line in the simple style (`showBranch(ref:)`), where nothing rewrites
// history (`showsCurrentBranchHistory`).

import EspalierSupport
import Foundation
import GitKit
import Observation
import os

private let logger = Log.logger(category: "history")

/// Which way a comparison goes.
public enum ComparisonDirection: String, Sendable, Hashable {
    /// The commits the other branch has that the current branch doesn't.
    case behind
    /// The commits the current branch has that the other branch doesn't.
    case ahead
}

/// What the history list shows.
public enum HistoryMode: Sendable, Equatable {
    case history
    case compare(Branch, ComparisonDirection)
}

/// The selected commits, their changed files, and the selected file's
/// diff, replaced as one value.
public struct CommitSelection: Sendable, Equatable {
    /// The selected commits, in the order they were selected.
    public var shas: [String] = []
    /// The commits whose changes the diff shows (contiguous selections).
    public var shasInDiff: [String] = []
    public var isContiguous = true
    public var changeset: Loadable<ChangesetData, OperationError> = .idle
    public var file: CommittedFileChange?
    public var diff: Loadable<Diff, OperationError> = .idle

    public init() {}
}

/// What going to a commit found (`HistoryModel.loadUntil(sha:)`).
public enum GoToCommitResult: Sendable, Equatable {
    /// The commit is loaded, in `row`, and selected.
    case found(row: Int)
    /// In the simple list: the commit came in with the merge in `mergeRow`,
    /// which is expanded to show it, and it's selected.
    case foundInMerge(mergeRow: Int, sha: String)
    /// No commit has that ID (or the prefix is ambiguous).
    case notFound
    /// The commit exists, but the history's scope doesn't include it.
    case notInHistory(sha: String)
    /// `cancelLoading()`, or a newer load, stopped it.
    case cancelled
}

/// The history and compare views: the list of commits and its graph, the
/// selection with its changes, search, comparisons, and pull request
/// previews.
///
/// History loads only while a view showing it is active (`activate()`).
/// Rows are those of the list that shows: the graph's, where row 0 is the
/// uncommitted-work node in history mode and commits follow, or in the
/// simple style the first-parent line's commits from row 0
/// (`commit(atRow:)`, `simpleOutline`).
@MainActor @Observable
public final class HistoryModel: RepositoryFeature {
    /// The first page: enough for a fast first paint.
    static let firstPageSize = 100
    /// The pages after it.
    static let pageSize = 1_000
    /// The pages loaded while loading the rest (dragging to the end,
    /// searching older commits, going to a commit).
    static let largePageSize = 5_000

    // MARK: State

    /// Whether a view showing history is visible; history loads only then.
    public private(set) var isActive = false
    public private(set) var mode: HistoryMode = .history
    /// The branch whose history shows instead of HEAD's (another branch's
    /// place), by its full ref; nil for HEAD's (`showBranch(ref:)`).
    public private(set) var shownBranchRef: String?
    /// How history mode shows commits: the current branch simply (the
    /// default) or the scope's branches as a graph; the app-wide
    /// `history-style` preference (`setStyle(_:)`). Compare mode always
    /// shows its list.
    public internal(set) var style = HistoryStyle.simple
    /// Which commits the graph shows; remembered per repository.
    public private(set) var scope = HistoryScope.defaultScope
    /// The loaded commits, newest first: the history's (the simple list's
    /// in the simple style), or in compare mode those of the comparison's
    /// direction.
    public private(set) var commitSHAs: [String] = []
    /// The graph of the loaded commits. In history mode, row 0 is the
    /// uncommitted-work node.
    public private(set) var graph = CommitGraphLayout()
    /// How the last change touched the graph's rows.
    public private(set) var graphChange = HistoryGraphChange(
        kind: .reload, generation: 0, reloadGeneration: 0, relaidRows: 0..<0, insertedRows: 0..<0
    )
    /// The commit whose first-parent line is the graph's trunk.
    public private(set) var trunkTip: String?
    /// Whether every commit of the list is loaded.
    public private(set) var isComplete = false
    /// Whether the list is loading for the first time, or for a new scope.
    public private(set) var isLoading = false
    /// Whether older commits are loading (a page, or the rest).
    public private(set) var isLoadingMore = false
    /// Why the history couldn't load.
    public internal(set) var loadError: OperationError?
    /// The number of commits in the history, when it's known: once it's all
    /// loaded, or counted when that's cheap (the repository has a
    /// commit-graph file).
    public private(set) var totalCommitCount: Int?
    /// Whether the uncommitted-work row is selected rather than commits.
    public private(set) var isWorkingCopySelected = false
    /// The search, while there is a query.
    public internal(set) var search: HistorySearch?
    /// The simple list's lines for the commits loaded: its rows, with each
    /// expanded merge's commits; empty until it loads
    /// (HistoryModel+SimpleMode.swift).
    public internal(set) var simpleOutline = SimpleHistoryOutline()
    /// For the notice above the simple list: the base branch has commits
    /// the current branch doesn't (Update from <base>).
    public internal(set) var simpleBaseStatus: SimpleHistoryBaseStatus?
    /// Where the current branch began on the simple list's line: the base
    /// and the row of the commit the branch started from.
    public internal(set) var simpleStart: SimpleHistoryStart?

    /// The selected commits, their changed files, and the selected file's
    /// diff.
    public var selection: CommitSelection {
        selectionLoader.selection
    }

    /// The comparison with another branch, in compare mode.
    public let comparison = CompareModel()
    /// The pull request preview: the current branch into a base.
    public let pullRequestPreview = PullRequestPreviewModel()
    /// An open pull request's changes (the pull request place).
    public let pullRequestChanges = PullRequestPreviewModel()

    /// The branches pointing at each commit.
    private var branchRefsByCommit: [String: [HistoryRef]] = [:] {
        didSet { decorationsGeneration &+= 1 }
    }
    /// The tags pointing at each commit (from the refresh's tags).
    private var tagRefsByCommit: [String: [HistoryRef]] = [:] {
        didSet { decorationsGeneration &+= 1 }
    }
    /// Current-branch commits not on its upstream: the refresh's first 100,
    /// and more loaded as the history pages past them.
    private var localCommitSHASet: Set<String> = [] {
        didSet { decorationsGeneration &+= 1 }
    }
    /// Counts changes to what rows show besides their commits (`refs(at:)`,
    /// `isLocalCommit(_:)`, the simple list's unpushed marks and merges'
    /// commits), so a table that reads them outside SwiftUI draws its rows
    /// again: the refs, local commits, and unpushed counts often land after
    /// the commits do.
    public private(set) var decorationsGeneration: UInt64 = 0
    @ObservationIgnored private var moreLocalCommitSHAs: Set<String> = []
    /// The refresh's tags and local commits the maps above were made from.
    @ObservationIgnored private var tagsSeen: [String: String]?
    @ObservationIgnored private var localCommitsSeen: [String] = []

    // MARK: Internals

    @ObservationIgnored weak var repository: RepositoryModel?
    @ObservationIgnored private let selectionLoader = CommitSelectionLoader()

    /// The history mode's list, kept while comparing.
    @ObservationIgnored private var historyList: CommitList?
    @ObservationIgnored private var historySource: HistorySource?
    @ObservationIgnored private var historyTrunkTip: String?
    /// The compare mode's list.
    @ObservationIgnored private var compareList: CommitList?
    @ObservationIgnored private var listCounter: UInt64 = 0
    /// The graph's commit count (`totalCommitCount` while the graph shows).
    @ObservationIgnored private var graphCommitCount: Int?

    /// The simple style's list, its frame (unpushed rows, the base's new
    /// commits), and its expanded merges (by SHA).
    @ObservationIgnored var simpleList: SimpleHistoryList?
    @ObservationIgnored var simpleFrame: SimpleHistoryFrame? {
        didSet { decorationsGeneration &+= 1 }
    }
    @ObservationIgnored var mergeExpansions: [String: MergedCommitsExpansion] = [:] {
        didSet { decorationsGeneration &+= 1 }
    }
    @ObservationIgnored var mergeLoads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored let simpleCheckSlot = LatestTask<UInt64>()
    @ObservationIgnored let simpleFrameSlot = LatestTask<UInt64>()
    @ObservationIgnored var simpleChecks: UInt64 = 0
    /// The sources of the simple list and of its frame loading.
    @ObservationIgnored var pendingSimpleSource: SimpleHistorySource?
    @ObservationIgnored var pendingFrameSource: SimpleHistorySource?
    @ObservationIgnored var mergeLoadCounter: UInt64 = 0

    @ObservationIgnored private let historyCheckSlot = LatestTask<UInt64>()
    @ObservationIgnored private var historyChecks: UInt64 = 0
    @ObservationIgnored private var pageLoad: (listID: UInt64, task: Task<Bool, Never>)?
    @ObservationIgnored private var pagingLoop: UInt64 = 0
    @ObservationIgnored private var runningPagingLoops = 0
    @ObservationIgnored private let compareRequest = LatestRequest()
    @ObservationIgnored private var comparisonRefresh: Task<Void, Never>?
    @ObservationIgnored private var comparisonRefreshes: UInt64 = 0
    @ObservationIgnored let goToCommitRequest = LatestRequest()
    @ObservationIgnored private let searchSlot = LatestTask<SearchKey>()
    /// The number of the active list's commits the search has looked at.
    @ObservationIgnored private var searchCoveredCount = 0
    /// Whether the search hasn't looked at all the active list's commits.
    @ObservationIgnored private var isListSearchPending = false
    /// The commits the simple list's merges brought in, scanned for the
    /// search, and how many of them the search has looked at
    /// (HistoryModel+SimpleSearch.swift).
    @ObservationIgnored var mergedSearchIndex: MergedSearchIndex?
    @ObservationIgnored var mergedSearchCoveredCount = 0
    @ObservationIgnored let mergedScanSlot = LatestTask<MergedScanKey>()
    @ObservationIgnored let mergedMatchSlot = LatestTask<MergedMatchKey>()
    /// Whether the search hasn't looked at all the commits the simple
    /// list's merges brought in.
    @ObservationIgnored var isMergedSearchPending = false
    /// A match inside a merge moved to, selected once the merge's commits
    /// load if the selection hasn't changed meanwhile.
    @ObservationIgnored var pendingMergedReveal: PendingMergedReveal?
    @ObservationIgnored private let countSlot = LatestTask<UInt64>()
    @ObservationIgnored private let localCommitsSlot = LatestTask<Int>()
    @ObservationIgnored private var localCommitsExhausted = false

    private struct SearchKey: Hashable, Sendable {
        let query: String
        let listID: UInt64
        let start: Int
    }

    init() {
        selectionLoader.context = { [weak self] in self?.loadContext() }
        selectionLoader.hideWhitespace = { [weak self] in
            self?.repository?.app?.preferences.hideWhitespaceInHistoryDiff ?? false
        }
        comparison.context = { [weak self] in self?.loadContext() }
    }

    func attach(to repository: RepositoryModel) {
        self.repository = repository
        pullRequestPreview.repository = repository
        pullRequestChanges.repository = repository
        scope = repository.record.historyScope ?? .defaultScope
        style = repository.app?.preferences.historyStyle ?? .simple
    }

    // MARK: Activation

    /// A view showing history appeared: loads it, or reloads it if its
    /// commits changed.
    public func activate() {
        if !isActive {
            isActive = true
        }
        updateRefreshedRefs()
        switch mode {
        case .history:
            checkShownHistory()
        case .compare:
            refreshComparison()
            comparison.resumeLoads()
        }
        // Loads stopped when the repository was deselected.
        selectionLoader.resumeLoads()
        resumeMergeLoads()
        if search?.isSearching == true {
            extendSearch()
            extendMergedSearch()
        }
        // Without git's commit-graph file, every page in topological order
        // walks the whole history.
        repository?.writeCommitGraphIfMissing()
    }

    /// The view showing history disappeared. What's loaded stays.
    public func deactivate() {
        if isActive {
            isActive = false
        }
    }

    /// Shows the commits of `scope`, and remembers it for the repository.
    public func setScope(_ scope: HistoryScope) {
        guard scope != self.scope else {
            return
        }
        self.scope = scope
        if let repository {
            repository.app?.updateRecord(repository.id) { $0.historyScope = scope }
        }
        if isActive, mode == .history, style == .graph {
            checkHistory()
        }
    }

    /// Shows the history in `style`, already the app's preference: loads
    /// its list when History shows, or reloads it if its commits changed
    /// (`setStyle(_:)` calls it for every repository).
    func applyStyle(_ style: HistoryStyle) {
        guard style != self.style else {
            return
        }
        self.style = style
        cancelPageLoad()
        pagingLoop &+= 1
        goToCommitRequest.cancel()
        guard mode == .history else {
            return
        }
        publishActiveList(searchRows: nil)
        updateTotalCommitCount()
        // A list loading for the first time keeps the selection until it
        // lands.
        if activeList != nil {
            maintainSelection()
        }
        if isActive {
            checkShownHistory()
        }
    }

    // MARK: Rows and commits

    /// The ID of the repository whose history this is.
    public var repositoryID: RepositoryID? {
        repository?.id
    }

    /// The commit in `row` of the graph; nil for the uncommitted-work row.
    public func commit(atRow row: Int) -> Commit? {
        activeList?.commit(atRow: row)
    }

    /// The graph row of the loaded commit `sha`.
    public func row(of sha: String) -> Int? {
        activeList?.row(of: sha)
    }

    /// The loaded commit `sha`: in the list, the other history lists, an
    /// expanded merge of the simple list, or a pull request preview.
    public func commit(_ sha: String) -> Commit? {
        activeList?.commit(sha) ?? historyList?.commit(sha) ?? simpleList?.commits.commit(sha)
            ?? compareList?.commit(sha) ?? mergedCommit(sha)
            ?? pullRequestPreview.commits.first { $0.sha == sha }
            ?? pullRequestChanges.commits.first { $0.sha == sha }
    }

    /// The loaded commits for `shas`, in order.
    public func commits(for shas: [String]) -> [Commit] {
        shas.compactMap(commit)
    }

    /// The row of the `parentIndex`th parent of the node in `row`, if it's
    /// loaded (for going to a parent, across stubs). The uncommitted-work
    /// node's only parent is HEAD's commit.
    public func parentRow(ofRow row: Int, parentIndex: Int = 0) -> Int? {
        guard let list = activeList else {
            return nil
        }
        if row == 0, list.layout.hasUncommittedWorkRow {
            return parentIndex == 0 ? historySource?.head.flatMap(list.row(of:)) : nil
        }
        guard let commit = list.commit(atRow: row), commit.parentSHAs.indices.contains(parentIndex) else {
            return nil
        }
        return list.row(of: commit.parentSHAs[parentIndex])
    }

    /// The rows of the loaded children of the node in `row` (for going back
    /// up a line, across stubs): those whose first parent it is, then the
    /// rest, each top to bottom. HEAD's commit's children include the
    /// uncommitted-work node. Children are always above their parent, so
    /// this looks at the rows above only.
    public func childRows(ofRow row: Int) -> [Int] {
        guard let list = activeList, let commit = list.commit(atRow: row) else {
            return []
        }
        var firstParentChildren: [Int] = []
        var otherChildren: [Int] = []
        if list.layout.hasUncommittedWorkRow, let head = historySource?.head, head == commit.sha {
            firstParentChildren.append(0)
        }
        let end = min(row - list.rowOffset, list.commits.count)
        for index in 0..<max(end, 0) {
            let parents = list.commits[index].parentSHAs
            if parents.first == commit.sha {
                firstParentChildren.append(index + list.rowOffset)
            } else if parents.contains(commit.sha) {
                otherChildren.append(index + list.rowOffset)
            }
        }
        return firstParentChildren + otherChildren
    }

    /// The branches and tags pointing at `sha` (ref capsules): local
    /// branches, then remote branches, then tags, each by name.
    public func refs(at sha: String) -> [HistoryRef] {
        (branchRefsByCommit[sha] ?? []) + (tagRefsByCommit[sha] ?? [])
    }

    /// Whether `sha` is a commit of the current branch that isn't on its
    /// upstream (or on any remote, without one): an unpushed commit.
    public func isLocalCommit(_ sha: String) -> Bool {
        localCommitSHASet.contains(sha)
    }

    // MARK: The branch shown

    /// The branch whose history shows instead of HEAD's: `shownBranchRef`'s
    /// branch, unless it's the current branch or is gone.
    public var shownBranch: Branch? {
        guard let ref = shownBranchRef, let repository else {
            return nil
        }
        if let current = repository.gitState.tip.branch, sameRef(current.ref, ref) {
            return nil
        }
        return repository.gitState.branches.all.first { sameRef($0.ref, ref) }
    }

    /// Whether the list is the current branch's history: history mode, and
    /// not another branch's. Only there do commits rewrite (squash,
    /// reorder, Reset to Commit, Undo Commit, amend); cherry-picking works
    /// anywhere.
    public var showsCurrentBranchHistory: Bool {
        mode == .history && shownBranch == nil
    }

    /// Shows the history of the branch `ref` names instead of HEAD's (nil:
    /// HEAD's). The simple style lists that branch's first-parent line,
    /// loaded again from its tip; the graph shows its scope either way.
    public func showBranch(ref: String?) {
        guard ref != shownBranchRef else {
            return
        }
        let before = simpleSource()
        shownBranchRef = ref
        let after = simpleSource()
        if before?.head != after?.head {
            // Another line: none of the list's commits may be on it.
            forgetSimpleList()
        }
        if isActive, isSimpleListShown {
            checkSimpleHistory()
        }
    }

    /// Forgets the simple list and stops its loads, publishing the empty
    /// list while it shows.
    private func forgetSimpleList() {
        simpleCheckSlot.cancel()
        simpleFrameSlot.cancel()
        pendingSimpleSource = nil
        pendingFrameSource = nil
        if let pageLoad, pageLoad.listID == simpleList?.commits.id {
            pageLoad.task.cancel()
        }
        cancelMergeLoads()
        mergeExpansions = [:]
        forgetMergedSearchIndex()
        simpleList = nil
        simpleFrame = nil
        setSimpleLoading(false)
        guard isSimpleListShown else {
            return
        }
        publishActiveList(searchRows: nil)
        updateTotalCommitCount()
    }

    // MARK: Paging

    /// Loads the next page of history (1,000 commits after the first 100),
    /// of whichever list shows.
    public func loadNextPage() async {
        await loadPage(size: Self.pageSize)
    }

    /// Loads the rest of the history in pages of 5,000 commits, until it's
    /// all loaded or `cancelLoading()`.
    public func loadRemainingPages() async {
        let loop = beginPagingLoop()
        defer { endPagingLoop() }
        while isCurrentPagingLoop(loop) {
            guard await loadPage(size: Self.largePageSize) else {
                return
            }
        }
    }

    /// Stops loading the rest of the history, searching older commits, and
    /// going to a commit (a page in flight still lands).
    public func cancelLoading() {
        pagingLoop &+= 1
        goToCommitRequest.cancel()
    }

    // MARK: Selection

    /// Selects commits, and loads their changed files and the first file's
    /// diff. `contiguous` says whether they're adjacent rows; only one commit
    /// or a contiguous range has changes to show (`shasInDiff`,
    /// `unreachableSHAs`).
    public func select(shas: [String], contiguous: Bool) {
        if isWorkingCopySelected {
            isWorkingCopySelected = false
        }
        let ordered = orderShasByHistory(shas) { [activeList] sha in activeList?.indexBySHA[sha] }
        selectionLoader.select(shas: shas, contiguous: contiguous, orderedShas: ordered) { [weak self] sha in
            self?.commit(sha)?.parentSHAs
        }
    }

    /// Selects the uncommitted-work row.
    public func selectWorkingCopy() {
        selectionLoader.clear()
        if !isWorkingCopySelected {
            isWorkingCopySelected = true
        }
    }

    /// Selects a changed file of the selected commits and loads its diff.
    public func selectFile(_ file: CommittedFileChange?) {
        selectionLoader.selectFile(file)
    }

    /// Hides or shows whitespace changes in history diffs (the
    /// `hide-whitespace-in-diff` preference) and reloads the selected file's
    /// diff.
    public func setHideWhitespaceInDiff(_ hide: Bool) {
        if let preferences = repository?.app?.preferences, preferences.hideWhitespaceInHistoryDiff != hide {
            preferences.hideWhitespaceInHistoryDiff = hide
        }
        selectionLoader.reloadDiff()
    }

    // MARK: Search

    /// Searches the loaded commits for `query` (summary, body, author name or
    /// email, SHA prefix). A blank query ends the search.
    public func setSearchQuery(_ query: String) {
        guard SearchQuery(query) != nil else {
            searchSlot.cancel()
            mergedMatchSlot.cancel()
            pendingMergedReveal = nil
            if search != nil {
                search = nil
            }
            return
        }
        if search?.query == query {
            return
        }
        search = HistorySearch(query: query)
        searchCoveredCount = 0
        restartMergedSearch()
        extendSearch()
    }

    /// Moves to the next match (after the selection when no match was moved
    /// to yet), wrapping around, and selects it: a commit inside a merge of
    /// the simple list once the merge, expanded to show it, has loaded its
    /// commits. Returns its row (for a commit inside a merge, the merge's).
    @discardableResult
    public func selectNextSearchMatch() -> Int? {
        moveSearchMatch(forward: true)
    }

    /// Moves to the previous match, wrapping around, and selects it, as
    /// `selectNextSearchMatch()` does. Returns its row.
    @discardableResult
    public func selectPreviousSearchMatch() -> Int? {
        moveSearchMatch(forward: false)
    }

    /// Loads older commits until one matches the search (or the history
    /// ends, or `cancelLoading()`), then moves to and selects the first new
    /// match.
    public func searchOlderCommits() async {
        guard let query = search?.query, mode == .history else {
            return
        }
        let loop = beginPagingLoop()
        defer { endPagingLoop() }
        await searchIdle()
        let before = search?.matchCount ?? 0
        while isCurrentPagingLoop(loop), search?.query == query, (search?.matchCount ?? 0) == before {
            guard await loadPage(size: Self.largePageSize) else {
                break
            }
            await searchIdle()
        }
        guard var current = search, current.query == query, current.matchCount > before else {
            return
        }
        let match = current.match(at: before)
        current.current = match
        search = current
        revealSearchMatch(match)
    }

    /// Goes to the commit whose SHA starts with `sha` (4 to 64 hexadecimal
    /// digits): loads pages until it's loaded, unless it isn't in the
    /// history, and selects it. `cancelLoading()` stops it.
    @discardableResult
    public func loadUntil(sha: String) async -> GoToCommitResult {
        let prefix = sha.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (SearchQuery.minimumSHAPrefixLength...64).contains(prefix.utf8.count), isHexadecimal(prefix) else {
            return .notFound
        }
        if let row = loadedRow(withSHAPrefix: prefix) {
            selectRow(row)
            return .found(row: row)
        }
        if mode == .history, style == .simple {
            return await loadUntilInSimpleList(prefix: prefix)
        }
        guard mode == .history, let context = loadContext(), let revisions = historySource?.revisions else {
            return .notFound
        }
        let loop = beginPagingLoop()
        defer { endPagingLoop() }
        let resolution = await goToCommitRequest.perform { () async -> CommitResolution in
            await context.environment.withRuntimes { () async -> CommitResolution in
                guard let sha = await resolveHistoryCommit(context.repository, prefix) else {
                    return .notFound
                }
                return await isReachable(context, sha, from: revisions) ? .inHistory(sha) : .notInHistory(sha)
            }
        }
        guard let resolution, isCurrentPagingLoop(loop) else {
            return .cancelled
        }
        let target: String
        switch resolution {
        case .notFound:
            return .notFound
        case .notInHistory(let sha):
            return .notInHistory(sha: sha)
        case .inHistory(let sha):
            target = sha
        }
        while isCurrentPagingLoop(loop), mode == .history {
            if let row = historyList?.row(of: target) {
                selectRow(row)
                return .found(row: row)
            }
            guard await loadPage(size: Self.largePageSize) else {
                break
            }
        }
        if mode == .history, let row = historyList?.row(of: target) {
            selectRow(row)
            return .found(row: row)
        }
        return isCurrentPagingLoop(loop) ? .notInHistory(sha: target) : .cancelled
    }

    // MARK: Compare

    /// Compares the current branch with `branch`: how far apart they are, the
    /// commits of `direction`, whether merging would conflict. Shows the
    /// commits in compare mode and selects the first. Returns without changes
    /// when a newer comparison replaced this one.
    ///
    /// - Throws: `OperationError` when HEAD isn't on a branch with commits,
    ///   when git can't compare the two, or when git fails.
    public func compare(with branch: Branch, direction: ComparisonDirection) async throws(OperationError) {
        guard let repository, let context = loadContext() else {
            return
        }
        guard case .valid(let current) = repository.gitState.tip else {
            throw OperationError(
                .precondition("There is no current branch to compare with."),
                operation: .loadHistory,
                repositoryID: repository.id
            )
        }
        let branch = repository.gitState.branches.all.first { sameRef($0.ref, branch.ref) } ?? branch
        comparison.begin(branch: branch, currentBranch: current, direction: direction)
        let result = await compareRequest.perform {
            await loadComparison(context, current: current, branch: branch, direction: direction)
        }
        guard let result else {
            return
        }
        switch result {
        case .failure(let error):
            comparison.didFail()
            throw error
        case .success(nil):
            comparison.didFail()
            throw OperationError(
                .precondition("Unable to compare \(branch.name) with \(current.name)."),
                operation: .loadHistory,
                repositoryID: repository.id
            )
        case .success(let loaded?):
            var list = loaded.list
            listCounter &+= 1
            list.id = listCounter
            compareList = list
            if mode != .compare(branch, direction) {
                mode = .compare(branch, direction)
            }
            comparison.didLoad(loaded.aheadBehind)
            publishActiveList(shas: loaded.shas, searchRows: nil)
            maintainSelection()
        }
    }

    /// The branches the current branch can be compared with: every branch
    /// except the current one and the branches of Espalier's fork remotes
    /// (`isForkRemoteBranch`).
    public var comparableBranches: [Branch] {
        guard let repository else {
            return []
        }
        let current = repository.gitState.tip.branch?.name
        let forkRemoteNames = repository.gitState.remotes.forkRemoteNames
        return repository.gitState.branches.all.filter { branch in
            branch.name != current && !branch.isForkRemoteBranch(forkRemoteNames)
        }
    }

    /// The recent branches, without the current one.
    public var recentComparableBranches: [Branch] {
        guard let repository else {
            return []
        }
        let current = repository.gitState.tip.branch?.name
        return repository.gitState.branches.recent.filter { $0.name != current }
    }

    /// The default branch, unless it's the current branch or there's no
    /// current branch.
    public var defaultComparableBranch: Branch? {
        guard let repository, let current = repository.gitState.tip.branch,
              let defaultBranch = repository.gitState.branches.defaultBranch, current.name != defaultBranch.name
        else {
            return nil
        }
        return defaultBranch
    }

    /// Returns to the history list, as after a checkout.
    public func resetToHistoryMode() {
        compareRequest.cancel()
        comparisonRefresh?.cancel()
        comparisonRefresh = nil
        guard mode != .history else {
            if comparison.isLoading {
                comparison.reset()
            }
            return
        }
        mode = .history
        comparison.reset()
        compareList = nil
        publishActiveList(searchRows: nil)
        updateTotalCommitCount()
        maintainSelection()
        if isActive {
            checkShownHistory()
        }
    }

    // MARK: Pull requests

    /// Previews a pull request from the current branch into `base`, or the
    /// default branch when nil: `pullRequestPreview` shows it.
    public func previewPullRequest(base: Branch? = nil) async {
        await pullRequestPreview.preview(base: base ?? repository?.gitState.branches.defaultBranch)
    }

    // MARK: Waiting

    /// Waits until no history load is in flight: the list, pages, search,
    /// the selection's changes, comparisons, and previews.
    public func idle() async {
        await repository?.commitGraphIdle()
        while true {
            await historyCheckSlot.idle()
            if let pageLoad {
                _ = await pageLoad.task.value
            }
            await compareRequest.idle()
            if let comparisonRefresh {
                await comparisonRefresh.value
            }
            await goToCommitRequest.idle()
            await searchSlot.idle()
            await mergedScanSlot.idle()
            await mergedMatchSlot.idle()
            await selectionLoader.idle()
            await comparison.idle()
            await pullRequestPreview.idle()
            await pullRequestChanges.idle()
            await countSlot.idle()
            await localCommitsSlot.idle()
            await simpleCheckSlot.idle()
            await simpleFrameSlot.idle()
            for load in mergeLoads.values {
                await load.value
            }
            if !historyCheckSlot.isRunning, pageLoad == nil, !compareRequest.isRunning, comparisonRefresh == nil,
               !goToCommitRequest.isRunning, !searchSlot.isRunning, !mergedScanSlot.isRunning, !mergedMatchSlot.isRunning,
               !countSlot.isRunning, !localCommitsSlot.isRunning,
               !selectionLoader.isRunning, !comparison.isRunning, !pullRequestPreview.isRunning,
               !pullRequestChanges.isRunning, !simpleCheckSlot.isRunning, !simpleFrameSlot.isRunning, mergeLoads.isEmpty {
                return
            }
        }
    }

    // MARK: Repository events

    func repositoryDidRefresh(_ update: RefreshUpdate) {
        guard let repository, isActive else {
            return
        }
        updateRefreshedRefs()
        let tip = repository.gitState.tip
        let tipChanged = update.previousTip.sha != tip.sha || update.previousTip.branch?.name != tip.branch?.name
        switch mode {
        case .history where style == .simple:
            // Its sources come from the refresh's state: cheap to compare.
            checkSimpleHistory()
        case .history:
            if update.applied.contains(.refs) || historyList == nil || tipChanged {
                checkHistory()
            }
        case .compare:
            if update.applied.contains(.refs) || tipChanged {
                refreshComparison()
            }
        }
    }

    func repositoryDidBecomeInactive() {
        if isActive {
            isActive = false
        }
        cancelLoads()
    }

    func repositoryPathDidChange(keepingSharedState: Bool) {
        cancelLoads()
        historyList = nil
        historySource = nil
        historyTrunkTip = nil
        graphCommitCount = nil
        simpleList = nil
        simpleFrame = nil
        mergeExpansions = [:]
        simpleOutline = SimpleHistoryOutline()
        simpleBaseStatus = nil
        simpleStart = nil
        compareList = nil
        mode = .history
        shownBranchRef = nil
        comparison.reset()
        pullRequestPreview.close()
        pullRequestChanges.close()
        selectionLoader.clear()
        isWorkingCopySelected = false
        branchRefsByCommit = [:]
        moreLocalCommitSHAs = []
        updateLocalCommits()
        localCommitsExhausted = false
        totalCommitCount = nil
        loadError = nil
        publishActiveList(searchRows: nil)
    }

    // MARK: Loading the history

    /// The list in view: the history's (the graph's or the simple list's),
    /// or the comparison's.
    var activeList: CommitList? {
        switch mode {
        case .history: style == .simple ? simpleList?.commits : historyList
        case .compare: compareList
        }
    }

    /// Whether the simple list shows (history mode in the simple style).
    var isSimpleListShown: Bool {
        mode == .history && style == .simple
    }

    /// Checks the list of the history's style.
    private func checkShownHistory() {
        if style == .simple {
            checkSimpleHistory()
        } else {
            checkHistory()
        }
    }

    func loadContext() -> HistoryLoadContext? {
        guard let repository else {
            return nil
        }
        return HistoryLoadContext(repository: repository.gitRepository, environment: repository.environment, record: repository.record)
    }

    /// Lists the refs and reloads the history if the commits it starts from,
    /// HEAD, or the trunk changed, keeping as many commits as were loaded.
    private func checkHistory() {
        guard let repository, let context = loadContext() else {
            return
        }
        let tip = repository.gitState.tip
        if case .unknown = tip {
            // Wait for the first status.
            return
        }
        let current = historyList == nil ? nil : historySource
        let sameScope = current?.scope == scope
        let count = max(Self.firstPageSize, sameScope ? historyList?.commits.count ?? 0 : 0)
        let defaultBranch = repository.gitState.branches.defaultBranch
        let request = HistoryCheckRequest(
            scope: scope,
            head: tip.sha,
            defaultBranchRef: defaultBranch?.ref,
            defaultBranchSHA: defaultBranch?.tip.sha,
            current: current,
            loadedCommits: historyList?.indexBySHA ?? [:],
            count: count,
            search: search.flatMap { SearchQuery($0.query) }
        )
        if mode == .history, !sameScope {
            setGraphLoading(true)
        }
        historyChecks &+= 1
        historyCheckSlot.run(
            historyChecks,
            operation: { await loadHistoryIfChanged(context, request) },
            apply: { [weak self] result in
                guard let self, case .success(let outcome) = result else { return }
                self.applyHistoryCheck(outcome, request: request)
            }
        )
    }

    private func applyHistoryCheck(_ outcome: HistoryCheckOutcome, request: HistoryCheckRequest) {
        switch outcome {
        case .unchanged(let refs):
            updateBranchRefs(refs)
            setGraphLoading(false)
        case .loaded(let loaded):
            updateBranchRefs(loaded.refs)
            installHistory(loaded, request: request)
        case .failed(let error):
            setGraphLoading(false)
            logger.error("Could not load the history: \(error.message, privacy: .public)")
            if historyList == nil, style == .graph, loadError != error {
                loadError = error
            }
        }
    }

    private func installHistory(_ loaded: LoadedHistory, request: HistoryCheckRequest) {
        cancelPageLoad()
        var list = loaded.list
        listCounter &+= 1
        list.id = listCounter
        historyList = list
        historySource = loaded.source
        historyTrunkTip = loaded.trunkTip
        moreLocalCommitSHAs = []
        updateLocalCommits()
        localCommitsSlot.cancel()
        localCommitsExhausted = false
        setGraphLoading(false)
        if style == .graph, loadError != nil {
            loadError = nil
        }
        countHistory(list)
        guard mode == .history, style == .graph else {
            return
        }
        let searchRows = request.search.flatMap { query in search.flatMap { SearchQuery($0.query) } == query ? loaded.searchRows : nil }
        publishActiveList(shas: loaded.shas, searchRows: searchRows)
        maintainSelection()
    }

    /// Installs a simple list as loaded (HistoryModel+SimpleMode.swift) and,
    /// while it shows, publishes it.
    func installSimpleHistory(_ loaded: LoadedSimpleHistory, search query: SearchQuery?) {
        if let pageLoad, pageLoad.listID == simpleList?.commits.id {
            pageLoad.task.cancel()
        }
        var list = loaded.list
        listCounter &+= 1
        list.commits.id = listCounter
        simpleList = list
        simpleFrame = loaded.frame
        forgetExpansionsNotInList()
        refreshExpansionsIfNeeded()
        setSimpleLoading(false)
        if style == .simple, loadError != nil {
            loadError = nil
        }
        guard isSimpleListShown else {
            return
        }
        let searchRows = query.flatMap { query in search.flatMap { SearchQuery($0.query) } == query ? loaded.searchRows : nil }
        publishActiveList(shas: loaded.shas, searchRows: searchRows)
        updateTotalCommitCount()
        maintainSelection()
    }

    /// Publishes the list in view as a whole: a reload. `shas` are its SHAs
    /// when they're at hand (computed off the main actor).
    func publishActiveList(shas: [String]? = nil, searchRows: [Int]?) {
        let list = activeList
        commitSHAs = shas ?? list?.commits.map(\.sha) ?? []
        graph = list?.layout ?? CommitGraphLayout()
        let complete = list?.isComplete ?? false
        if isComplete != complete {
            isComplete = complete
        }
        let trunk = switch mode {
        case .history: style == .simple ? simpleFrame?.source.head : historyTrunkTip
        case .compare: list?.commits.first?.sha
        }
        if trunkTip != trunk {
            trunkTip = trunk
        }
        rebuildSimpleOutline()
        updateLoading()
        graphChange = HistoryGraphChange(
            kind: .reload,
            generation: graphChange.generation &+ 1,
            reloadGeneration: graphChange.reloadGeneration &+ 1,
            relaidRows: 0..<0,
            insertedRows: 0..<graph.count
        )
        restartSearch(rows: searchRows, coveredCount: list?.commits.count ?? 0)
    }

    /// Keeps the selection if its first commit is in the list (or, in the
    /// simple list, an expanded merge's), else selects HEAD's commit in
    /// history mode, or the first commit.
    func maintainSelection() {
        if mode == .history, isWorkingCopySelected {
            return
        }
        let list = activeList
        if let first = selection.shas.first,
           list?.indexBySHA[first] != nil || (isSimpleListShown && mergedCommit(first) != nil) {
            return
        }
        var preferred = list?.commits.first?.sha
        let head = style == .simple ? simpleFrame?.source.head : historySource?.head
        if mode == .history, let head, list?.indexBySHA[head] != nil {
            preferred = head
        }
        if let preferred {
            select(shas: [preferred], contiguous: true)
        } else {
            selectionLoader.clear()
        }
    }

    /// Loads the next `size` commits of the history and appends them.
    /// Returns whether a page landed. A page already loading is waited for
    /// instead.
    @discardableResult
    func loadPage(size: Int) async -> Bool {
        if isSimpleListShown {
            return await loadNextSimplePage(size: size)
        }
        guard mode == .history, let context = loadContext(), let revisions = historySource?.revisions,
              let listID = historyList?.id
        else {
            return false
        }
        if let pageLoad, pageLoad.listID == listID {
            return await pageLoad.task.value
        }
        guard historyList?.isComplete == false, let builder = historyList?.builder else {
            return false
        }
        historyList?.builder = nil
        let skip = historyList?.commits.count ?? 0
        let rowOffset = historyList?.rowOffset ?? 0
        let lastLoaded = historyList?.commits.last?.sha
        let search = search.flatMap { SearchQuery($0.query) }
        let task = Task { [weak self] () -> Bool in
            let outcome = await loadCommitPage(
                context,
                revisions: revisions,
                skip: skip,
                limit: size,
                builder: builder,
                search: search,
                rowOffset: rowOffset
            )
            return self?.finishPage(outcome, listID: listID, search: search, lastLoaded: lastLoaded) ?? false
        }
        pageLoad = (listID, task)
        updateLoadingMore()
        return await task.value
    }

    private func finishPage(_ outcome: PageOutcome, listID: UInt64, search query: SearchQuery?, lastLoaded: String?) -> Bool {
        if pageLoad?.listID == listID {
            pageLoad = nil
            updateLoadingMore()
        }
        guard historyList?.id == listID else {
            return false
        }
        switch outcome.result {
        case .failure(let error):
            historyList?.builder = outcome.builder
            if !(error is CancellationError) {
                logger.error("Could not load older commits: \(error.localizedDescription, privacy: .public)")
            }
            return false
        case .success(let page):
            let oldCount = historyList?.layout.count ?? 0
            let oldStable = historyList?.layout.stableRowCount ?? 0
            let oldCommitCount = historyList?.commits.count ?? 0
            historyList?.append(page.commits, builder: outcome.builder, isComplete: page.isLastPage)
            guard let list = historyList else {
                return false
            }
            if list.isComplete {
                graphCommitCount = list.commits.count
                updateTotalCommitCount()
            }
            extendLocalCommitsIfNeeded(after: lastLoaded, pageSize: page.commits.count)
            guard mode == .history, style == .graph else {
                return true
            }
            commitSHAs.append(contentsOf: page.shas)
            graph = list.layout
            if isComplete != list.isComplete {
                isComplete = list.isComplete
            }
            graphChange = HistoryGraphChange(
                kind: .append,
                generation: graphChange.generation &+ 1,
                reloadGeneration: graphChange.reloadGeneration,
                relaidRows: oldStable..<oldCount,
                insertedRows: oldCount..<list.layout.count
            )
            appendSearchRows(page.searchRows, query: query, from: oldCommitCount, to: list.commits.count)
            return true
        }
    }

    /// Loads the next `size` commits of the simple list, from the last
    /// loaded commit's first parent, and appends them. Returns whether a
    /// page landed; a page already loading is waited for instead.
    private func loadNextSimplePage(size: Int) async -> Bool {
        guard let context = loadContext(), let list = simpleList else {
            return false
        }
        let listID = list.commits.id
        if let pageLoad, pageLoad.listID == listID {
            return await pageLoad.task.value
        }
        guard let start = list.nextStart, let builder = list.commits.builder else {
            return false
        }
        simpleList?.commits.builder = nil
        let firstRow = list.commits.commits.count
        let search = search.flatMap { SearchQuery($0.query) }
        let task = Task { [weak self] () -> Bool in
            let result: Result<SimplePage, any Error>
            do {
                result = .success(try await loadSimplePage(context, from: start, limit: size, firstRow: firstRow, search: search))
            } catch {
                result = .failure(error)
            }
            return self?.finishSimplePage(result, builder: builder, listID: listID, search: search) ?? false
        }
        pageLoad = (listID, task)
        updateLoadingMore()
        return await task.value
    }

    private func finishSimplePage(
        _ result: Result<SimplePage, any Error>,
        builder: consuming CommitGraphBuilder,
        listID: UInt64,
        search query: SearchQuery?
    ) -> Bool {
        if pageLoad?.listID == listID {
            pageLoad = nil
            updateLoadingMore()
        }
        guard simpleList?.commits.id == listID else {
            return false
        }
        switch result {
        case .failure(let error):
            simpleList?.commits.builder = builder
            if !(error is CancellationError) {
                logger.error("Could not load older commits: \(error.localizedDescription, privacy: .public)")
            }
            return false
        case .success(let page):
            let oldCommitCount = simpleList?.commits.commits.count ?? 0
            let oldStable = simpleList?.commits.layout.stableRowCount ?? 0
            builder.append(simpleGraphCommits(page.commits))
            if page.isLastPage {
                builder.finish()
            }
            simpleList?.commits.append(page.commits, builder: builder, isComplete: page.isLastPage)
            simpleList?.details.append(contentsOf: page.details)
            guard let list = simpleList else {
                return false
            }
            guard isSimpleListShown else {
                rebuildSimpleOutline()
                return true
            }
            commitSHAs.append(contentsOf: page.commits.map(\.sha))
            graph = list.commits.layout
            if isComplete != list.commits.isComplete {
                isComplete = list.commits.isComplete
            }
            graphChange = HistoryGraphChange(
                kind: .append,
                generation: graphChange.generation &+ 1,
                reloadGeneration: graphChange.reloadGeneration,
                relaidRows: oldStable..<oldCommitCount,
                insertedRows: oldCommitCount..<list.commits.layout.count
            )
            updateTotalCommitCount()
            rebuildSimpleOutline()
            appendSearchRows(page.searchRows, query: query, from: oldCommitCount, to: list.commits.commits.count)
            return true
        }
    }

    /// Cancels the page in flight; its builder goes back to its list.
    private func cancelPageLoad() {
        pageLoad?.task.cancel()
    }

    private func cancelLoads() {
        historyCheckSlot.cancel()
        simpleCheckSlot.cancel()
        simpleFrameSlot.cancel()
        setGraphLoading(false)
        setSimpleLoading(false)
        cancelMergeLoads()
        cancelPageLoad()
        pagingLoop &+= 1
        goToCommitRequest.cancel()
        searchSlot.cancel()
        mergedScanSlot.cancel()
        mergedMatchSlot.cancel()
        compareRequest.cancel()
        comparisonRefresh?.cancel()
        comparison.cancelLoads()
        selectionLoader.cancelLoads()
        pullRequestPreview.cancelLoads()
        pullRequestChanges.cancelLoads()
        countSlot.cancel()
        localCommitsSlot.cancel()
    }

    func beginPagingLoop() -> UInt64 {
        pagingLoop &+= 1
        runningPagingLoops += 1
        updateLoadingMore()
        return pagingLoop
    }

    func isCurrentPagingLoop(_ loop: UInt64) -> Bool {
        loop == pagingLoop
    }

    func endPagingLoop() {
        runningPagingLoops -= 1
        updateLoadingMore()
    }

    private func updateLoadingMore() {
        let loading = pageLoad != nil || (runningPagingLoops > 0 && activeList?.isComplete == false)
        if isLoadingMore != loading {
            isLoadingMore = loading
        }
    }

    /// Whether the graph's list is loading for the first time, or for a new
    /// scope.
    @ObservationIgnored private var isGraphLoading = false
    /// Whether the simple list is loading for the first time.
    @ObservationIgnored private var isSimpleLoading = false

    private func setGraphLoading(_ loading: Bool) {
        isGraphLoading = loading
        updateLoading()
    }

    func setSimpleLoading(_ loading: Bool) {
        isSimpleLoading = loading
        updateLoading()
    }

    /// `isLoading` for the list that shows.
    private func updateLoading() {
        let loading = mode == .history && (style == .simple ? isSimpleLoading : isGraphLoading)
        if isLoading != loading {
            isLoading = loading
        }
    }

    // MARK: Counting

    /// Counts the history's commits, when the list isn't all loaded and the
    /// repository has a commit-graph file (counting is then about as fast as
    /// a page).
    private func countHistory(_ list: CommitList) {
        countSlot.cancel()
        graphCommitCount = list.isComplete ? list.commits.count : nil
        updateTotalCommitCount()
        if list.isComplete {
            return
        }
        guard let context = loadContext(), let revisions = historySource?.revisions,
              let commonDirectory = repository?.watchedPaths?.commonDirectory
        else {
            return
        }
        let listID = list.id
        countSlot.run(
            listID,
            operation: { () async -> Int? in
                guard await hasCommitGraph(commonDirectory) else {
                    return nil
                }
                return await countCommits(context, revisions: revisions)
            },
            apply: { [weak self] result in
                guard let self, self.historyList?.id == listID, case .success(let count?) = result else { return }
                self.graphCommitCount = count
                self.updateTotalCommitCount()
            }
        )
    }

    /// `totalCommitCount` for the list that shows: the graph's, or the
    /// simple list's once it's all loaded.
    func updateTotalCommitCount() {
        let count = isSimpleListShown
            ? simpleList.flatMap { $0.commits.isComplete ? $0.commits.commits.count : nil }
            : graphCommitCount
        if totalCommitCount != count {
            totalCommitCount = count
        }
    }

    // MARK: Refs

    private func updateBranchRefs(_ refs: RefListing) {
        let branches = refs.branchesByCommit
        if branches != branchRefsByCommit {
            branchRefsByCommit = branches
        }
    }

    /// Takes the refresh's tags and local commits, when they changed.
    private func updateRefreshedRefs() {
        guard let repository else {
            return
        }
        let tags = repository.gitState.tags
        if tags != tagsSeen {
            tagsSeen = tags
            var result: [String: [HistoryRef]] = [:]
            for (name, sha) in tags ?? [:] {
                result[sha, default: []].append(HistoryRef(kind: .tag, fullName: "refs/tags/\(name)", name: name))
            }
            for (sha, refs) in result where refs.count > 1 {
                result[sha] = refs.sorted { $0.name < $1.name }
            }
            if result != tagRefsByCommit {
                tagRefsByCommit = result
            }
        }
        updateLocalCommits()
    }

    private func updateLocalCommits() {
        let local = repository?.gitState.localCommitSHAs ?? []
        if local != localCommitsSeen || localCommitSHASet.count != local.count + moreLocalCommitSHAs.count {
            localCommitsSeen = local
            let set = Set(local).union(moreLocalCommitSHAs)
            if set != localCommitSHASet {
                localCommitSHASet = set
            }
        }
    }

    /// Loads more of the current branch's local commits when the history
    /// paged past the ones known.
    private func extendLocalCommitsIfNeeded(after lastLoaded: String?, pageSize: Int) {
        guard let repository, let context = loadContext(), !localCommitsExhausted, !localCommitsSlot.isRunning,
              let lastLoaded, isLocalCommit(lastLoaded)
        else {
            return
        }
        let known = localCommitsSeen.count + moreLocalCommitSHAs.count
        guard known >= commitBatchSize else {
            // The refresh loaded all of them.
            localCommitsExhausted = true
            return
        }
        let tip = repository.gitState.tip
        let limit = max(pageSize, commitBatchSize)
        localCommitsSlot.run(
            known,
            operation: { () async -> [String]? in
                await context.environment.withRuntimes { () async -> [String]? in
                    switch tip {
                    case .valid(let branch):
                        if let upstream = branch.upstream, !upstream.isEmpty,
                           let commits = try? await getCommits(context.repository, revRange(upstream, branch.name), limit: limit, skip: known) {
                            return commits.map(\.sha)
                        }
                    case .detached:
                        break
                    case .unborn, .unknown:
                        return []
                    }
                    return try? await getCommits(
                        context.repository, "HEAD", limit: limit, skip: known, additionalArgs: ["--not", "--remotes"]
                    ).map(\.sha)
                }
            },
            apply: { [weak self] result in
                guard let self, case .success(let loaded) = result else { return }
                guard let shas = loaded else {
                    // git failed: don't try again for this history.
                    self.localCommitsExhausted = true
                    return
                }
                self.moreLocalCommitSHAs.formUnion(shas)
                self.updateLocalCommits()
                if shas.count < limit {
                    self.localCommitsExhausted = true
                }
            }
        )
    }

    // MARK: Comparing

    /// Compares again when the current branch's or the compared branch's
    /// commit changed; back to the history when the compared branch is gone
    /// or HEAD left the branch.
    private func refreshComparison() {
        guard case .compare(let branch, let direction) = mode, let repository else {
            return
        }
        guard case .valid(let current) = repository.gitState.tip,
              let fresh = repository.gitState.branches.all.first(where: { sameRef($0.ref, branch.ref) })
        else {
            resetToHistoryMode()
            return
        }
        guard fresh.tip.sha != comparison.branch?.tip.sha || current.tip.sha != comparison.currentBranch?.tip.sha
            || current.name != comparison.currentBranch?.name
        else {
            return
        }
        comparisonRefresh?.cancel()
        comparisonRefreshes &+= 1
        let refresh = comparisonRefreshes
        comparisonRefresh = Task { [weak self] in
            guard let self else { return }
            do throws(OperationError) {
                try await self.compare(with: fresh, direction: direction)
            } catch {
                if !error.isCancellation, refresh == self.comparisonRefreshes {
                    self.resetToHistoryMode()
                }
            }
            if refresh == self.comparisonRefreshes {
                self.comparisonRefresh = nil
            }
        }
    }

    // MARK: Searching

    /// Starts the search over on the list in view: with `rows` already found
    /// for the whole list, or from its start. The simple list's merges'
    /// commits are searched again from the start.
    private func restartSearch(rows: [Int]?, coveredCount: Int) {
        guard let current = search else {
            return
        }
        searchSlot.cancel()
        var restarted = HistorySearch(query: current.query)
        if let rows {
            restarted.matchingRows = rows
            searchCoveredCount = coveredCount
            isListSearchPending = false
        } else {
            searchCoveredCount = 0
        }
        search = restarted
        restartMergedSearch()
        if rows == nil {
            extendSearch()
        } else {
            publishSearchProgress()
        }
    }

    /// Searches the commits of the list in view the search hasn't looked at
    /// yet, off the main actor.
    private func extendSearch() {
        guard let current = search, let query = SearchQuery(current.query) else {
            return
        }
        guard let list = activeList, searchCoveredCount < list.commits.count else {
            isListSearchPending = false
            publishSearchProgress()
            return
        }
        let start = searchCoveredCount
        let end = list.commits.count
        let commits = list.commits[start..<end]
        let rowOffset = list.rowOffset
        let key = SearchKey(query: current.query, listID: list.id, start: start)
        isListSearchPending = true
        publishSearchProgress()
        searchSlot.run(
            key,
            operation: { await searchMatchingRows(commits, query: query, rowOffset: rowOffset) },
            apply: { [weak self] result in
                guard let self, case .success(let rows) = result, self.search?.query == key.query,
                      self.activeList?.id == key.listID, self.searchCoveredCount == key.start
                else { return }
                self.search?.matchingRows.append(contentsOf: rows)
                self.searchCoveredCount = end
                self.extendSearch()
            }
        )
    }

    /// Adds the matches found with a page, if the search was up to date,
    /// and searches the commits the page's merges brought in.
    private func appendSearchRows(_ rows: [Int]?, query: SearchQuery?, from start: Int, to end: Int) {
        guard let current = search else {
            return
        }
        if let rows, !isListSearchPending, searchCoveredCount == start, SearchQuery(current.query) == query {
            if !rows.isEmpty {
                search?.matchingRows.append(contentsOf: rows)
            }
            searchCoveredCount = end
        } else if !isListSearchPending {
            extendSearch()
        }
        extendMergedSearch()
    }

    /// Sets the search's `isSearching`: whether the list's commits, or the
    /// commits the simple list's merges brought in, are still being
    /// searched.
    func publishSearchProgress() {
        let isSearching = isListSearchPending || isMergedSearchPending
        if let current = search, current.isSearching != isSearching {
            search?.isSearching = isSearching
        }
    }

    /// Waits until the search has looked at every loaded commit.
    private func searchIdle() async {
        while true {
            await searchSlot.idle()
            await mergedScanSlot.idle()
            await mergedMatchSlot.idle()
            if !searchSlot.isRunning, !mergedScanSlot.isRunning, !mergedMatchSlot.isRunning {
                return
            }
        }
    }

    private func moveSearchMatch(forward: Bool) -> Int? {
        guard var current = search, current.matchCount > 0 else {
            return nil
        }
        let count = current.matchCount
        let next: Int
        if let index = current.currentMatch {
            next = forward ? (index + 1) % count : (index + count - 1) % count
        } else if let selected = selection.shas.first, let counts = searchMatchCounts(around: selected, in: current) {
            next = forward ? counts.through % count : (counts.before + count - 1) % count
        } else {
            next = forward ? 0 : count - 1
        }
        let match = current.match(at: next)
        current.current = match
        search = current
        revealSearchMatch(match)
        return switch match {
        case .row(let row): row
        case .merged(let mergeRow, _): mergeRow
        }
    }

    /// How many matches come before the loaded commit `sha`, and how many
    /// before or at it: a commit of the list, or one an expanded merge of
    /// the simple list shows.
    private func searchMatchCounts(around sha: String, in search: HistorySearch) -> (before: Int, through: Int)? {
        if let row = row(of: sha) {
            return search.matchCounts(aroundRow: row)
        }
        return isSimpleListShown ? mergedSearchMatchCounts(around: sha, in: search) : nil
    }

    /// Selects a match: a commit of the list, or one a merge of the simple
    /// list brought in, expanding the merge to show it.
    private func revealSearchMatch(_ match: HistorySearchMatch) {
        pendingMergedReveal = nil
        switch match {
        case .row(let row):
            selectRow(row)
        case .merged(let mergeRow, let sha):
            revealMergedMatch(mergeRow: mergeRow, sha: sha)
        }
    }

    private func selectRow(_ row: Int) {
        if let commit = commit(atRow: row) {
            select(shas: [commit.sha], contiguous: true)
        }
    }

    /// The first loaded row whose commit's SHA starts with `prefix`.
    private func loadedRow(withSHAPrefix prefix: String) -> Int? {
        guard let list = activeList else {
            return nil
        }
        if let row = list.row(of: prefix) {
            return row
        }
        return list.commits.firstIndex { $0.sha.hasPrefix(prefix) }.map { $0 + list.rowOffset }
    }
}

/// What going to a commit found before loading pages.
private enum CommitResolution: Sendable {
    case notFound
    case notInHistory(String)
    case inHistory(String)
}

/// Whether two ref names are the same (by code units, as git's are).
private func sameRef(_ x: String, _ y: String) -> Bool {
    x.utf8.elementsEqual(y.utf8)
}

/// Whether the repository whose common directory is `commonDirectory` has a
/// commit-graph file, which makes topological order and counting fast.
@concurrent
func hasCommitGraph(_ commonDirectory: String) async -> Bool {
    let info = POSIXPath.join(commonDirectory, "objects", "info")
    return FileManager.default.fileExists(atPath: POSIXPath.join(info, "commit-graph"))
        || FileManager.default.fileExists(atPath: POSIXPath.join(info, "commit-graphs", "commit-graph-chain"))
}
