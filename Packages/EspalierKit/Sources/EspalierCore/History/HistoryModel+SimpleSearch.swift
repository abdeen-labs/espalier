// Search in History's simple style also matches the commits the line's merges
// brought in, which the list loads only when a merge expands. While a search
// runs, the commits the loaded rows' merges brought in are scanned once per
// stretch of rows, with one `git log` from the stretch's first merge down to
// the line's next commit (`<merge> ^<next>`, which lists the stretch's line
// commits and exactly what its merges brought in), and assigned to the merge
// that brought each in. The scans are kept with the list, so a new query
// searches them in memory; they run only while searching, only over loaded
// rows, off the main actor, and not at all for rows without merges. Moving to
// a match inside a collapsed merge expands it and selects the match once its
// commits load.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "history")

/// A commit a merge on the simple list's line brought in, scanned for the
/// search.
struct MergedCommitEntry: Sendable {
    /// The merge's row.
    let mergeRow: Int
    let commit: Commit
}

/// The commits the simple list's merges brought in, for its rows scanned so
/// far.
struct MergedSearchIndex: Sendable {
    /// The simple list's `CommitList.id`.
    let listID: UInt64
    /// The rows scanned: `0..<coveredRows`.
    var coveredRows = 0
    /// The commits, by merge, top to bottom, each merge's in git's
    /// topological order.
    var entries: [MergedCommitEntry] = []
}

/// A scan of the simple list's rows `start..<end`.
struct MergedScanKey: Hashable, Sendable {
    let listID: UInt64
    let start: Int
    let end: Int
}

/// A search of the scanned commits from `start`.
struct MergedMatchKey: Hashable, Sendable {
    let query: String
    let listID: UInt64
    let start: Int
}

/// A match inside a merge moved to while the merge's commits load.
struct PendingMergedReveal: Sendable {
    /// The merge's SHA.
    let merge: String
    let sha: String
    /// The selection when it was moved to.
    let selection: [String]
}

extension HistoryModel {
    // MARK: Searching

    /// Starts searching the commits the simple list's merges brought in
    /// over, for a new query or list.
    func restartMergedSearch() {
        mergedMatchSlot.cancel()
        mergedSearchCoveredCount = 0
        pendingMergedReveal = nil
        extendMergedSearch()
    }

    /// Searches the scanned commits the search hasn't looked at yet, or
    /// scans the loaded rows not scanned yet, off the main actor; each
    /// continues with the next until every loaded row's merges are
    /// searched.
    func extendMergedSearch() {
        guard let current = search, let query = SearchQuery(current.query), isSimpleListShown, let list = simpleList else {
            isMergedSearchPending = false
            publishSearchProgress()
            return
        }
        let listID = list.commits.id
        if mergedSearchIndex?.listID != listID {
            mergedScanSlot.cancel()
            mergedSearchIndex = MergedSearchIndex(listID: listID)
            mergedSearchCoveredCount = 0
        }
        guard let index = mergedSearchIndex else {
            return
        }
        if mergedSearchCoveredCount < index.entries.count {
            searchScannedMergedCommits(index, query: query, queryText: current.query)
            return
        }
        let rows = list.commits.commits.count
        guard index.coveredRows < rows else {
            isMergedSearchPending = false
            publishSearchProgress()
            return
        }
        guard let context = loadContext() else {
            return
        }
        isMergedSearchPending = true
        publishSearchProgress()
        if mergedScanSlot.isRunning, let running = mergedScanSlot.currentKey, running.listID == listID,
           running.start == index.coveredRows {
            // It continues with the rows loaded since it started.
            return
        }
        let key = MergedScanKey(listID: listID, start: index.coveredRows, end: rows)
        let line = Array(list.commits.commits[key.start..<key.end])
        mergedScanSlot.run(
            key,
            operation: { try await scanMergedCommits(context, line: line, firstRow: key.start) },
            apply: { [weak self] result in
                guard let self, self.mergedSearchIndex?.listID == key.listID, self.mergedSearchIndex?.coveredRows == key.start else {
                    return
                }
                switch result {
                case .success(let entries):
                    self.mergedSearchIndex?.entries.append(contentsOf: entries)
                case .failure(let error):
                    if error is CancellationError {
                        return
                    }
                    // The search goes on without these merges' commits.
                    logger.error("Could not scan the merged commits: \(error.localizedDescription, privacy: .public)")
                }
                self.mergedSearchIndex?.coveredRows = key.end
                self.extendMergedSearch()
            }
        )
    }

    private func searchScannedMergedCommits(_ index: MergedSearchIndex, query: SearchQuery, queryText: String) {
        let start = mergedSearchCoveredCount
        let end = index.entries.count
        let key = MergedMatchKey(query: queryText, listID: index.listID, start: start)
        isMergedSearchPending = true
        publishSearchProgress()
        if mergedMatchSlot.isRunning, mergedMatchSlot.currentKey == key {
            return
        }
        let entries = index.entries[start..<end]
        mergedMatchSlot.run(
            key,
            operation: { await searchMergedCommits(entries, query: query) },
            apply: { [weak self] result in
                guard let self, case .success(let matches) = result, self.search?.query == key.query,
                      self.mergedSearchIndex?.listID == key.listID, self.mergedSearchCoveredCount == key.start
                else { return }
                self.search?.appendMergedMatches(matches, searched: end - start)
                self.mergedSearchCoveredCount = end
                self.orderMergedMatchesByExpansions()
                self.extendMergedSearch()
            }
        )
    }

    /// Forgets the scanned commits and stops the scan (the simple list is
    /// gone).
    func forgetMergedSearchIndex() {
        mergedScanSlot.cancel()
        mergedMatchSlot.cancel()
        mergedSearchIndex = nil
        mergedSearchCoveredCount = 0
        pendingMergedReveal = nil
    }

    /// Orders each loaded merge's matching commits as its expanded rows
    /// show them.
    func orderMergedMatchesByExpansions() {
        guard search?.mergedMatches.isEmpty == false else {
            return
        }
        for (sha, expansion) in mergeExpansions {
            if let loaded = expansion.load.value {
                orderMergedMatches(ofMerge: sha, loaded: loaded)
            }
        }
    }

    /// Orders the merge `sha`'s matching commits as `loaded`, its loaded
    /// commits, shows them.
    func orderMergedMatches(ofMerge sha: String, loaded: LoadedMergedCommits) {
        guard search?.mergedMatches.isEmpty == false, let row = simpleList?.commits.row(of: sha) else {
            return
        }
        var order: [String: Int] = [:]
        for (index, commit) in loaded.commits.enumerated() {
            order[commit.sha] = index
        }
        search?.orderMergedMatches(ofMergeRow: row, by: order)
    }

    // MARK: Moving to a match

    /// How many matches come before `sha`, a commit an expanded merge
    /// shows, and how many before or at it; nil when no loaded merge has
    /// it.
    func mergedSearchMatchCounts(around sha: String, in search: HistorySearch) -> (before: Int, through: Int)? {
        for (mergeSHA, expansion) in mergeExpansions {
            guard let commits = expansion.load.value?.commits,
                  let index = commits.firstIndex(where: { $0.sha == sha }),
                  let mergeRow = simpleList?.commits.row(of: mergeSHA)
            else {
                continue
            }
            var order: [String: Int] = [:]
            for (position, commit) in commits.enumerated() {
                order[commit.sha] = position
            }
            return search.matchCounts(aroundMergedCommit: sha, mergeRow: mergeRow) { match in
                (order[match.sha] ?? Int.max) < index
            }
        }
        return nil
    }

    /// Expands the merge in `mergeRow` and selects `sha`, one of its
    /// commits: at once when they're loaded, else once they load (all of
    /// them, when `sha` is past the first ones shown).
    func revealMergedMatch(mergeRow: Int, sha: String) {
        guard let merge = simpleList?.commits.commit(atRow: mergeRow) else {
            return
        }
        let isLoaded = mergeExpansions[merge.sha]?.load.value?.commits.contains { $0.sha == sha } == true
        expandMerge(merge, row: mergeRow, limit: isLoaded ? Self.mergedCommitsLimit : nil)
        if case .loaded(let loaded)? = mergeExpansions[merge.sha]?.load, loaded.commits.contains(where: { $0.sha == sha }) {
            select(shas: [sha], contiguous: true)
        } else {
            pendingMergedReveal = PendingMergedReveal(merge: merge.sha, sha: sha, selection: selection.shas)
        }
    }

    /// The merge `sha`'s commits loaded: selects the match moved to inside
    /// it, if it's still the one moved to and nothing else was selected
    /// meanwhile, and orders its matching commits as its rows show them.
    func finishMergedSearchLoad(_ sha: String) {
        guard case .loaded(let loaded)? = mergeExpansions[sha]?.load else {
            return
        }
        orderMergedMatches(ofMerge: sha, loaded: loaded)
        guard let pending = pendingMergedReveal, pending.merge == sha else {
            return
        }
        pendingMergedReveal = nil
        guard case .merged(_, let current)? = search?.current, current == pending.sha,
              selection.shas == pending.selection, loaded.commits.contains(where: { $0.sha == pending.sha })
        else {
            return
        }
        select(shas: [pending.sha], contiguous: true)
    }
}

// MARK: - Scanning

/// The commits the merges among `line` (the simple list's commits from
/// `firstRow`, in order) brought in: one `git log` from the first merge down
/// to the line's commit after the last (the last's first parent), which
/// lists `line`'s commits from there and what its merges brought in, and
/// nothing else. Each commit is assigned to its merge
/// (`assignMergedCommits`).
@concurrent
func scanMergedCommits(_ context: HistoryLoadContext, line: [Commit], firstRow: Int) async throws -> [MergedCommitEntry] {
    guard let first = line.firstIndex(where: \.isMergeCommit) else {
        return []
    }
    var revisions = [line[first].sha]
    if let next = line.last?.parentSHAs.first {
        revisions.append("^\(next)")
    }
    let commits = try await context.environment.withRuntimes {
        try await getCommits(context.repository, revisions: revisions, additionalArgs: ["--topo-order"])
    }
    try Task.checkCancellation()
    return assignMergedCommits(commits, line: line, firstRow: firstRow)
}

/// Assigns `commits` (a scan's, in git's order) to the merges among `line`
/// (the simple list's commits from `firstRow`) that brought them in: the
/// oldest merge whose history has the commit, which brought in what its
/// other parents reach and its first parent doesn't. From the oldest merge
/// up, each takes what its other parents reach through `commits` that's
/// neither on the line nor taken by an older merge (which its first
/// parent's history has). Returns them by merge, top to bottom, each
/// merge's in `commits`' order; commits on the line are left out.
func assignMergedCommits(_ commits: [Commit], line: [Commit], firstRow: Int) -> [MergedCommitEntry] {
    var commitsBySHA: [String: Commit] = [:]
    commitsBySHA.reserveCapacity(commits.count)
    for commit in commits {
        commitsBySHA[commit.sha] = commit
    }
    let lineSHAs = Set(line.map(\.sha))
    var mergeRows: [String: Int] = [:]
    for (offset, merge) in line.enumerated().reversed() where merge.isMergeCommit {
        var stack = Array(merge.parentSHAs.dropFirst())
        while let sha = stack.popLast() {
            guard mergeRows[sha] == nil, !lineSHAs.contains(sha), let commit = commitsBySHA[sha] else {
                continue
            }
            mergeRows[sha] = firstRow + offset
            stack.append(contentsOf: commit.parentSHAs)
        }
    }
    var byMerge: [Int: [MergedCommitEntry]] = [:]
    for commit in commits {
        if let row = mergeRows[commit.sha] {
            byMerge[row, default: []].append(MergedCommitEntry(mergeRow: row, commit: commit))
        }
    }
    return byMerge.keys.sorted().flatMap { byMerge[$0] ?? [] }
}

/// The matches among `entries`, in order.
@concurrent
func searchMergedCommits(_ entries: ArraySlice<MergedCommitEntry>, query: SearchQuery) async -> [MergedSearchMatch] {
    entries.filter { query.matches($0.commit) }.map { MergedSearchMatch(mergeRow: $0.mergeRow, sha: $0.commit.sha) }
}
