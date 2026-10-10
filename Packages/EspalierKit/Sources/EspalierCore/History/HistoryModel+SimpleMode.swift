// History's simple mode in the history model (SimpleHistory.swift describes the
// list). The simple list loads from the refresh's state: HEAD, the base branch
// (`findContributionTargetDefaultBranch`, which Update from <branch> merges),
// the upstream, and the remotes. It reloads when HEAD moves, keeping as many
// commits as were loaded, and counts its unpushed rows and the base's new
// commits again when only the base, the upstream, or the remotes moved.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "history")

extension HistoryModel {
    /// How many commits an expanded merge shows at most; the graph shows
    /// the rest.
    static let mergedCommitsLimit = 1_000

    // MARK: Style

    /// Shows history in `style` and remembers it app-wide: every
    /// repository's history switches.
    public func setStyle(_ style: HistoryStyle) {
        guard let app = repository?.app else {
            applyStyle(style)
            return
        }
        app.preferences.historyStyle = style
        for model in app.models.values {
            model.history.applyStyle(style)
        }
    }

    // MARK: Rows

    /// What the simple list's row `row` shows, if it's loaded.
    public func simpleRow(atRow row: Int) -> SimpleHistoryRow? {
        guard let list = simpleList, list.commits.commits.indices.contains(row) else {
            return nil
        }
        let commit = list.commits.commits[row]
        return makeSimpleRow(
            commit,
            details: list.details[row],
            isUnpushed: simpleFrame?.isUnpushed(row: row) ?? false,
            isExpanded: mergeExpansions[commit.sha]?.isExpanded == true
        )
    }

    /// What the `index`th commit the merge in `mergeRow` brought in shows,
    /// if it's loaded.
    public func simpleMergedRow(mergeRow: Int, index: Int) -> SimpleHistoryRow? {
        guard let merge = simpleList?.commits.commit(atRow: mergeRow),
              let loaded = mergeExpansions[merge.sha]?.load.value, loaded.commits.indices.contains(index)
        else {
            return nil
        }
        let commit = loaded.commits[index]
        let isMergeUnpushed = simpleFrame?.isUnpushed(row: mergeRow) ?? false
        return makeSimpleRow(
            commit,
            details: loaded.details[index],
            isUnpushed: isMergeUnpushed && loaded.unpushed.contains(commit.sha),
            isExpanded: false
        )
    }

    /// The commits the merge in `row` brought in, while it's expanded.
    public func mergedCommits(ofRow row: Int) -> SimpleMergedCommits? {
        guard let merge = simpleList?.commits.commit(atRow: row), let expansion = mergeExpansions[merge.sha],
              expansion.isExpanded
        else {
            return nil
        }
        return switch expansion.load {
        case .loaded(let loaded):
            SimpleMergedCommits(state: .loaded, count: loaded.commits.count, hasMore: loaded.hasMore)
        case .loading(let previous):
            SimpleMergedCommits(state: .loading, count: previous?.commits.count ?? 0, hasMore: previous?.hasMore ?? false)
        case .failed(let error):
            SimpleMergedCommits(state: .failed(error), count: 0, hasMore: false)
        case .idle:
            SimpleMergedCommits(state: .loading, count: 0, hasMore: false)
        }
    }

    /// Expands the merge in `row` to show the commits it brought in
    /// (loading them the first time), or collapses it.
    public func setMergeExpanded(_ expanded: Bool, row: Int) {
        guard let merge = simpleList?.commits.commit(atRow: row), merge.isMergeCommit else {
            return
        }
        if expanded {
            expandMerge(merge, row: row, limit: Self.mergedCommitsLimit)
        } else if mergeExpansions[merge.sha]?.isExpanded == true {
            mergeExpansions[merge.sha]?.isExpanded = false
            rebuildSimpleOutline()
        }
    }

    // MARK: Internals

    private func makeSimpleRow(_ commit: Commit, details: SimpleCommitDetails, isUnpushed: Bool, isExpanded: Bool) -> SimpleHistoryRow {
        SimpleHistoryRow(
            commit: commit,
            tags: refs(at: commit.sha).filter { $0.kind == .tag }.map(\.name),
            isUnpushed: isUnpushed,
            changedFileCount: details.changedFileCount,
            merge: commit.isMergeCommit
                ? SimpleHistoryMerge(
                    branchName: details.merge?.branchName,
                    pullRequestNumber: details.merge?.pullRequestNumber,
                    isExpanded: isExpanded
                )
                : nil
        )
    }

    /// A commit loaded for an expanded (or once expanded) merge.
    func mergedCommit(_ sha: String) -> Commit? {
        for expansion in mergeExpansions.values {
            if let commit = expansion.load.value?.commits.first(where: { $0.sha == sha }) {
                return commit
            }
        }
        return nil
    }

    /// Builds the outline again, and takes the base's notice and where the
    /// branch started from the frame, while the simple list shows.
    func rebuildSimpleOutline() {
        guard isSimpleListShown else {
            return
        }
        let baseStatus = simpleFrame?.baseStatus
        if simpleBaseStatus != baseStatus {
            simpleBaseStatus = baseStatus
        }
        let start = simpleFrame?.start
        if simpleStart != start {
            simpleStart = start
        }
        guard let list = simpleList else {
            if simpleOutline != SimpleHistoryOutline() {
                simpleOutline = SimpleHistoryOutline()
            }
            return
        }
        simpleOutline = makeSimpleHistoryOutline(list: list, expansions: mergeExpansions)
    }

    // MARK: Loading

    /// What the simple list loads from, from the refresh's state; nil until
    /// the first status.
    private func simpleSource() -> SimpleHistorySource? {
        guard let repository else {
            return nil
        }
        let state = repository.gitState
        switch state.tip {
        case .unknown:
            return nil
        case .unborn:
            return SimpleHistorySource()
        case .detached(let sha):
            return SimpleHistorySource(head: sha)
        case .valid(let branch):
            var source = SimpleHistorySource(head: branch.tip.sha)
            if let base = findContributionTargetDefaultBranch(repository.record, state.branches),
               !JSCompat.strictEquals(base.name, branch.name) {
                source.base = base
            }
            if !state.remotes.all.isEmpty {
                if let upstream = state.branches.upstreams[ExactString(branch.ref)] {
                    source.unpushedReference = .upstream(sha: upstream.tip.sha)
                } else {
                    source.unpushedReference = .remotes
                }
            }
            return source
        }
    }

    /// Loads the simple list when HEAD moved (or it isn't loaded), keeping
    /// as many commits as were loaded; counts its frame again when only the
    /// base, the upstream, or the remotes moved.
    func checkSimpleHistory() {
        guard let source = simpleSource() else {
            return
        }
        if simpleList != nil, let frame = simpleFrame, frame.source.head == source.head {
            // The list is HEAD's: a load for another HEAD is stale.
            simpleCheckSlot.cancel()
            if frame.source == source {
                simpleFrameSlot.cancel()
                return
            }
            reloadSimpleFrame(source)
            return
        }
        loadSimpleList(source)
    }

    private func loadSimpleList(_ source: SimpleHistorySource) {
        guard let context = loadContext() else {
            return
        }
        // The refresh tells features twice per pass; one load is enough.
        if simpleCheckSlot.isRunning, pendingSimpleSource == source {
            return
        }
        simpleFrameSlot.cancel()
        if simpleList == nil {
            setSimpleLoading(true)
        }
        let count = max(Self.firstPageSize, simpleList?.commits.commits.count ?? 0)
        let query = search.flatMap { SearchQuery($0.query) }
        simpleChecks &+= 1
        pendingSimpleSource = source
        simpleCheckSlot.run(
            simpleChecks,
            operation: { await loadSimpleHistory(context, source, count: count, search: query) },
            apply: { [weak self] result in
                guard let self else { return }
                self.pendingSimpleSource = nil
                switch result {
                case .success(.success(let loaded)):
                    self.installSimpleHistory(loaded, search: query)
                case .success(.failure(let error)):
                    self.setSimpleLoading(false)
                    logger.error("Could not load the history: \(error.message, privacy: .public)")
                    if self.simpleList == nil, self.isSimpleListShown, self.loadError != error {
                        self.loadError = error
                    }
                case .failure:
                    self.setSimpleLoading(false)
                }
            }
        )
    }

    /// Counts the frame again for `source`, whose HEAD is the list's.
    private func reloadSimpleFrame(_ source: SimpleHistorySource) {
        guard let context = loadContext() else {
            return
        }
        if simpleFrameSlot.isRunning, pendingFrameSource == source {
            return
        }
        simpleChecks &+= 1
        pendingFrameSource = source
        simpleFrameSlot.run(
            simpleChecks,
            operation: { await loadSimpleFrame(context, source) },
            apply: { [weak self] result in
                guard let self else { return }
                self.pendingFrameSource = nil
                guard case .success(let frame) = result, self.simpleList != nil,
                      self.simpleFrame?.source.head == frame.source.head
                else { return }
                self.simpleFrame = frame
                self.refreshExpansionsIfNeeded()
                self.rebuildSimpleOutline()
            }
        )
    }

    // MARK: Merges

    /// Expands `merge` (in `row`), loading up to `limit` of its commits (nil:
    /// all) unless they're loaded for the current unpushed reference.
    @discardableResult
    func expandMerge(_ merge: Commit, row: Int, limit: Int?) -> Task<Void, Never>? {
        let reference = simpleFrame?.source.unpushedReference
        if var expansion = mergeExpansions[merge.sha], expansion.unpushedReference == reference {
            // Loaded (or loading) enough: a limit is always met, and all
            // the commits only when none are left out.
            let isEnough = switch expansion.load {
            case .loaded(let loaded): limit != nil || !loaded.hasMore
            case .loading: limit != nil
            case .failed, .idle: false
            }
            if isEnough {
                if !expansion.isExpanded {
                    expansion.isExpanded = true
                    mergeExpansions[merge.sha] = expansion
                    rebuildSimpleOutline()
                }
                return mergeLoads[merge.sha]
            }
        }
        guard let context = loadContext() else {
            return nil
        }
        let isMergeUnpushed = simpleFrame?.isUnpushed(row: row) ?? false
        mergeLoadCounter &+= 1
        let loadID = mergeLoadCounter
        mergeLoads[merge.sha]?.cancel()
        mergeExpansions[merge.sha] = MergedCommitsExpansion(
            load: .loading(previous: mergeExpansions[merge.sha]?.load.value),
            unpushedReference: reference,
            isExpanded: true,
            loadID: loadID
        )
        let sha = merge.sha
        let task = Task { [weak self] in
            let result = await loadMergedCommits(
                context,
                merge: merge,
                isMergeUnpushed: isMergeUnpushed,
                unpushedReference: reference,
                limit: limit
            )
            self?.finishMergeLoad(sha, loadID: loadID, result: result)
        }
        mergeLoads[sha] = task
        rebuildSimpleOutline()
        return task
    }

    private func finishMergeLoad(_ sha: String, loadID: UInt64, result: Result<LoadedMergedCommits, OperationError>) {
        guard var expansion = mergeExpansions[sha], expansion.loadID == loadID else {
            return
        }
        mergeLoads[sha] = nil
        switch result {
        case .success(let loaded):
            expansion.load = .loaded(loaded)
        case .failure(let error) where error.isCancellation:
            expansion.load = .idle
        case .failure(let error):
            logger.error("Could not load a merge's commits: \(error.message, privacy: .public)")
            expansion.load = .failed(error)
        }
        mergeExpansions[sha] = expansion
        rebuildSimpleOutline()
    }

    /// Loads the expanded merges' commits again where a load was stopped
    /// (the repository was deselected).
    func resumeMergeLoads() {
        guard let list = simpleList else {
            return
        }
        for (sha, expansion) in mergeExpansions where expansion.isExpanded && mergeLoads[sha] == nil {
            guard case .idle = expansion.load, let row = list.commits.row(of: sha),
                  let merge = list.commits.commit(atRow: row)
            else {
                continue
            }
            expandMerge(merge, row: row, limit: Self.mergedCommitsLimit)
        }
    }

    /// Forgets the merges that aren't in the simple list anymore.
    func forgetExpansionsNotInList() {
        guard let list = simpleList else {
            return
        }
        for sha in mergeExpansions.keys where list.commits.indexBySHA[sha] == nil {
            mergeLoads[sha]?.cancel()
            mergeLoads[sha] = nil
            mergeExpansions[sha] = nil
        }
    }

    /// Stops the merges' loads; what's loaded stays.
    func cancelMergeLoads() {
        for (sha, task) in mergeLoads {
            task.cancel()
            if case .loading(let previous) = mergeExpansions[sha]?.load {
                mergeExpansions[sha]?.load = previous.map { .loaded($0) } ?? .idle
            }
            mergeExpansions[sha]?.loadID = 0
        }
        mergeLoads = [:]
    }

    /// Loads the expanded merges again whose commits' unpushed state was
    /// read for another upstream; forgets the collapsed ones.
    func refreshExpansionsIfNeeded() {
        let reference = simpleFrame?.source.unpushedReference
        for (sha, expansion) in mergeExpansions where expansion.unpushedReference != reference {
            guard expansion.isExpanded, let row = simpleList?.commits.row(of: sha),
                  let merge = simpleList?.commits.commit(atRow: row)
            else {
                mergeLoads[sha]?.cancel()
                mergeLoads[sha] = nil
                mergeExpansions[sha] = nil
                continue
            }
            expandMerge(merge, row: row, limit: expansion.load.value.map { $0.hasMore ? Self.mergedCommitsLimit : nil } ?? Self.mergedCommitsLimit)
        }
    }

    // MARK: Going to a commit

    /// Goes to the commit whose SHA starts with `prefix` in the simple list:
    /// on the first-parent line, or inside the merge that brought it in
    /// (expanded to show it). Loads pages until it's loaded, and selects it.
    func loadUntilInSimpleList(prefix: String) async -> GoToCommitResult {
        if let (row, sha) = loadedMergedCommit(withPrefix: prefix) {
            if let merge = simpleList?.commits.commit(atRow: row) {
                expandMerge(merge, row: row, limit: nil)
            }
            select(shas: [sha], contiguous: true)
            return .foundInMerge(mergeRow: row, sha: sha)
        }
        guard let context = loadContext(), let head = simpleFrame?.source.head else {
            return .notFound
        }
        let loop = beginPagingLoop()
        defer { endPagingLoop() }
        let resolution = await goToCommitRequest.perform { () async -> SimpleCommitResolution in
            await context.environment.withRuntimes { () async -> SimpleCommitResolution in
                guard let sha = await resolveHistoryCommit(context.repository, prefix) else {
                    return .notFound
                }
                return .found(sha, await findOnFirstParentLine(context.repository, sha, head: head))
            }
        }
        guard let resolution, isCurrentPagingLoop(loop) else {
            return .cancelled
        }
        guard case .found(let sha, let position) = resolution else {
            return .notFound
        }
        let target: String
        switch position {
        case .notInHistory:
            return .notInHistory(sha: sha)
        case .onLine:
            target = sha
        case .inMerge(_, let merge):
            target = merge
        }
        guard let row = await loadSimpleRows(until: target, loop: loop) else {
            return isCurrentPagingLoop(loop) ? .notInHistory(sha: sha) : .cancelled
        }
        guard case .inMerge = position else {
            select(shas: [sha], contiguous: true)
            return .found(row: row)
        }
        guard let merge = simpleList?.commits.commit(atRow: row) else {
            return .cancelled
        }
        await expandMerge(merge, row: row, limit: nil)?.value
        guard isCurrentPagingLoop(loop), mergedCommit(sha) != nil else {
            return isCurrentPagingLoop(loop) ? .notInHistory(sha: sha) : .cancelled
        }
        select(shas: [sha], contiguous: true)
        return .foundInMerge(mergeRow: row, sha: sha)
    }

    /// Loads pages of the simple list until `sha` is loaded; its row, or nil
    /// when the list ended first or the loop was stopped.
    private func loadSimpleRows(until sha: String, loop: UInt64) async -> Int? {
        while isCurrentPagingLoop(loop), isSimpleListShown {
            if let row = simpleList?.commits.row(of: sha) {
                return row
            }
            guard await loadPage(size: Self.largePageSize) else {
                break
            }
        }
        return isSimpleListShown ? simpleList?.commits.row(of: sha) : nil
    }

    /// The row of the merge and the SHA of a loaded merged commit whose SHA
    /// starts with `prefix`.
    private func loadedMergedCommit(withPrefix prefix: String) -> (row: Int, sha: String)? {
        for (mergeSHA, expansion) in mergeExpansions {
            guard let commit = expansion.load.value?.commits.first(where: { $0.sha.hasPrefix(prefix) }),
                  let row = simpleList?.commits.row(of: mergeSHA)
            else {
                continue
            }
            return (row, commit.sha)
        }
        return nil
    }
}

/// What going to a commit in the simple list found before loading pages.
enum SimpleCommitResolution: Sendable {
    case notFound
    case found(String, FirstParentPosition)
}
