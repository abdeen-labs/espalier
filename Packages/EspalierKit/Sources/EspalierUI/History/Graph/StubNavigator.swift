// Following the graph's stubs and lines. A stub's other end is selected and
// brought into view (animated when it's near, at once and pulsed when it's
// far); one that isn't loaded yet loads pages until it is, with a spinner at
// the stub and Esc to stop. Jumps are recorded for Go ▸ Back and Forward,
// one list per repository, and ⌥⌘↓, ⌥⌘⇧↓, and ⌥⌘↑ follow parents and
// children across stubs. In the simple list, going to a commit selects it,
// and the list scrolls to it.

import AppKit
import EspalierCore
import GitKit
import Observation

/// Back and Forward through the commits jumped between.
struct HistoryNavigationStack: Equatable {
    private(set) var back: [String] = []
    private(set) var forward: [String] = []
    /// At most this many places are remembered each way.
    static let limit = 100

    /// A jump from `origin` (the commit shown before it).
    mutating func record(from origin: String) {
        if back.last != origin {
            back.append(origin)
            if back.count > Self.limit {
                back.removeFirst(back.count - Self.limit)
            }
        }
        forward.removeAll()
    }

    /// The place to go back to from `current`, which Forward then returns
    /// to.
    mutating func goBack(from current: String?) -> String? {
        guard let target = back.popLast() else {
            return nil
        }
        if let current {
            forward.append(current)
        }
        return target
    }

    /// The place to go forward to from `current`.
    mutating func goForward(from current: String?) -> String? {
        guard let target = forward.popLast() else {
            return nil
        }
        if let current {
            back.append(current)
        }
        return target
    }
}

/// Follows stubs, parents, and children in one window's history, and keeps
/// the places jumped between in each repository.
@MainActor @Observable
final class StubNavigator {
    /// The places jumped between, by repository.
    private var stacks: [RepositoryID: HistoryNavigationStack] = [:]
    /// The commit being loaded toward, while a stub's other end loads.
    private(set) var pendingSHA: String?

    @ObservationIgnored weak var controller: GraphTableController?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init() {}

    func canGoBack(in history: HistoryModel) -> Bool {
        !stack(of: history).back.isEmpty
    }

    func canGoForward(in history: HistoryModel) -> Bool {
        !stack(of: history).forward.isEmpty
    }

    // MARK: Following

    /// Follows the stub (or `unrouted` edge) `edge` of `row`: selects its
    /// other end, loading pages until it's there when it isn't loaded.
    func follow(row: Int, edge: CommitGraphEdge, in history: HistoryModel) {
        let origin = history.commit(atRow: row)?.sha
        switch edge.kind {
        case .incomingStub:
            guard let childRow = edge.childRow else {
                return
            }
            go(toRow: childRow, from: origin, in: history)
        case .outgoingStub, .unrouted:
            if let parentRow = edge.parentRow {
                go(toRow: parentRow, from: origin, in: history)
                return
            }
            // Not loaded yet: load until the parent's commit is.
            guard !history.isComplete, let commit = history.commit(atRow: row),
                  let parentIndex = edge.parentIndex, commit.parentSHAs.indices.contains(parentIndex) else {
                return
            }
            load(commit.parentSHAs[parentIndex], from: origin, stubRow: row, in: history)
        case .passing, .incoming, .outgoing:
            return
        }
    }

    /// Goes to the selected row's parent (`index` 0 for the first) or child,
    /// across stubs, loading the parent when it isn't loaded. In the simple
    /// list, a merge's other parents show inside the merge.
    func goToParent(index: Int, in history: HistoryModel) {
        guard let row = selectedRow(in: history) else {
            return
        }
        let origin = history.commit(atRow: row)?.sha
        if let parentRow = history.parentRow(ofRow: row, parentIndex: index) {
            go(toRow: parentRow, from: origin, in: history)
            return
        }
        guard let commit = history.commit(atRow: row), commit.parentSHAs.indices.contains(index),
              !history.isComplete || Self.showsSimpleList(history) else {
            NSSound.beep()
            return
        }
        load(commit.parentSHAs[index], from: origin, stubRow: nil, in: history)
    }

    /// Goes to the child that leads to the selected row: the one on the
    /// row's own line (so ⌥⌘↑ walks back up what ⌥⌘↓ walks down), else the
    /// topmost child whose first parent it is, else the topmost merge.
    func goToChild(in history: HistoryModel) {
        guard let row = selectedRow(in: history), let child = Self.childLeading(to: row, in: history) else {
            NSSound.beep()
            return
        }
        go(toRow: child, from: history.commit(atRow: row)?.sha, in: history)
    }

    /// The child `goToChild` goes to from `row`.
    static func childLeading(to row: Int, in history: HistoryModel) -> Int? {
        let children = history.childRows(ofRow: row)
        let track = history.graph[row].track
        return children.first { history.graph[$0].track == track } ?? children.first
    }

    /// Whether the selected row has a parent `index` to go to.
    func canGoToParent(index: Int, in history: HistoryModel) -> Bool {
        guard let row = selectedRow(in: history) else {
            return false
        }
        if row == 0, history.graph.hasUncommittedWorkRow {
            return index == 0 && history.parentRow(ofRow: 0) != nil
        }
        return (history.commit(atRow: row)?.parentSHAs.count ?? 0) > index
    }

    /// Whether the selected row has a child to go to.
    func canGoToChild(in history: HistoryModel) -> Bool {
        guard let row = selectedRow(in: history) else {
            return false
        }
        return !history.childRows(ofRow: row).isEmpty
    }

    // MARK: Back and Forward

    func goBack(in history: HistoryModel) {
        guard let id = history.repositoryID, let target = stacks[id]?.goBack(from: currentSHA(in: history)) else {
            return
        }
        show(target, in: history)
    }

    func goForward(in history: HistoryModel) {
        guard let id = history.repositoryID, let target = stacks[id]?.goForward(from: currentSHA(in: history)) else {
            return
        }
        show(target, in: history)
    }

    /// Goes to the commit `sha` (Go to Commit, a search match), recording
    /// the jump. Returns what loading it found.
    @discardableResult
    func goToCommit(_ sha: String, in history: HistoryModel) async -> GoToCommitResult {
        let origin = currentSHA(in: history)
        cancel()
        pendingSHA = sha
        let result = await history.loadUntil(sha: sha)
        if pendingSHA == sha {
            pendingSHA = nil
        }
        switch result {
        case .found(let row):
            record(from: origin, in: history)
            reveal(row: row, pulse: true, in: history)
        case .foundInMerge:
            // Selected inside its merge, which the simple list expanded.
            record(from: origin, in: history)
        case .notFound, .notInHistory, .cancelled:
            break
        }
        return result
    }

    /// Stops loading toward a stub's other end.
    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        if pendingSHA != nil {
            pendingSHA = nil
            controller?.setLoadingStub(row: nil)
        }
    }

    // MARK: Moving

    private func go(toRow row: Int, from origin: String?, in history: HistoryModel) {
        record(from: origin, in: history)
        reveal(row: row, pulse: true, in: history)
    }

    private func show(_ sha: String, in history: HistoryModel) {
        if let row = history.row(of: sha) {
            reveal(row: row, pulse: true, in: history)
            return
        }
        loadTask?.cancel()
        pendingSHA = sha
        loadTask = Task { [weak self, weak history] in
            guard let history else { return }
            let result = await history.loadUntil(sha: sha)
            guard let self, !Task.isCancelled, self.pendingSHA == sha else { return }
            self.pendingSHA = nil
            if case .found(let row) = result {
                self.reveal(row: row, pulse: true, in: history)
            }
        }
    }

    /// Loads pages until `sha` is loaded, with a spinner at the stub, then
    /// goes there.
    private func load(_ sha: String, from origin: String?, stubRow: Int?, in history: HistoryModel) {
        loadTask?.cancel()
        pendingSHA = sha
        controller?.setLoadingStub(row: stubRow)
        loadTask = Task { [weak self, weak history] in
            guard let history else { return }
            let result = await history.loadUntil(sha: sha)
            guard let self, !Task.isCancelled, self.pendingSHA == sha else { return }
            self.pendingSHA = nil
            self.controller?.setLoadingStub(row: nil)
            switch result {
            case .found(let row):
                self.record(from: origin, in: history)
                self.reveal(row: row, pulse: true, in: history)
            case .foundInMerge:
                // Selected inside its merge, which the simple list expanded.
                self.record(from: origin, in: history)
            case .notFound, .notInHistory, .cancelled:
                break
            }
        }
    }

    /// Selects `row`'s commit and brings it into view: the graph's table
    /// reveals it, pulsed when `pulse`; the simple list scrolls to a new
    /// selection itself.
    private func reveal(row: Int, pulse: Bool, in history: HistoryModel) {
        guard Self.showsSimpleList(history) else {
            if let controller, controller.source === history {
                controller.reveal(row: row, pulse: pulse)
            }
            return
        }
        if let sha = history.commit(atRow: row)?.sha {
            history.select(shas: [sha], contiguous: true)
        } else if row == 0, history.graph.hasUncommittedWorkRow {
            history.selectWorkingCopy()
        }
    }

    /// Whether `history` shows the simple list (its history in the simple
    /// style), not the graph's table.
    private static func showsSimpleList(_ history: HistoryModel) -> Bool {
        history.style == .simple && history.mode == .history
    }

    /// The places jumped between in `history`'s repository.
    private func stack(of history: HistoryModel) -> HistoryNavigationStack {
        history.repositoryID.flatMap { stacks[$0] } ?? HistoryNavigationStack()
    }

    /// Records a jump from `origin` in `history`'s repository.
    private func record(from origin: String?, in history: HistoryModel) {
        guard let origin, let id = history.repositoryID else {
            return
        }
        stacks[id, default: HistoryNavigationStack()].record(from: origin)
    }

    private func selectedRow(in history: HistoryModel) -> Int? {
        if history.isWorkingCopySelected {
            return history.graph.hasUncommittedWorkRow ? 0 : nil
        }
        return history.selection.shas.first.flatMap(history.row(of:))
    }

    private func currentSHA(in history: HistoryModel) -> String? {
        history.selection.shas.first
    }

    // MARK: Tooltips

    /// What a stub's tooltip says: where it continues, with the other end's
    /// commit; counts in `numberFormat`.
    static func tooltip(for edge: CommitGraphEdge, row: Int, source: HistoryModel, isLoading: Bool, numberFormat: NumberFormat) -> String {
        func describe(_ commit: Commit?) -> String {
            guard let commit else {
                return ""
            }
            let summary = commit.summary.isEmpty ? CommitRowContent.emptySummary : RichText.emojified(commit.summary)
            return ": \(shortenSHA(commit.sha)) \(summary)"
        }
        func commits(_ count: Int) -> String {
            count == 1 ? "1 commit" : "\(formatCount(count, numberFormat)) commits"
        }
        switch edge.kind {
        case .outgoingStub:
            if let parentRow = edge.parentRow {
                return "Continues \(commits(parentRow - row)) below" + describe(source.commit(atRow: parentRow))
            }
            if source.isComplete {
                return "This commit's parent isn't in the history shown."
            }
            let parent = source.commit(atRow: row).flatMap { commit in
                edge.parentIndex.flatMap { commit.parentSHAs.indices.contains($0) ? commit.parentSHAs[$0] : nil }
            }
            let name = parent.map { " (\(shortenSHA($0)))" } ?? ""
            return "Continues below the loaded commits\(name). " + (isLoading ? "Loading…" : "Click to load them.")
        case .incomingStub:
            guard let childRow = edge.childRow else {
                return ""
            }
            return "Comes from \(commits(row - childRow)) above" + describe(source.commit(atRow: childRow))
        case .unrouted:
            guard let parentRow = edge.parentRow else {
                return "This commit's parent isn't in the history shown."
            }
            return "Its parent is shown above" + describe(source.commit(atRow: parentRow))
        case .passing, .incoming, .outgoing:
            return ""
        }
    }
}
