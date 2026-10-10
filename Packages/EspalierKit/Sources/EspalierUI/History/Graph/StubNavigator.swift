// Following the graph's stubs and lines. A stub's other end is selected and
// brought into view (animated when it's near, at once and pulsed when it's
// far); one that isn't loaded yet loads pages until it is, with a spinner at
// the stub and Esc to stop. Jumps are recorded for Go ▸ Back and Forward,
// and ⌥⌘↓, ⌥⌘⇧↓, and ⌥⌘↑ follow parents and children across stubs.

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

/// Follows stubs, parents, and children in one window's graph, and keeps
/// the places jumped between.
@MainActor @Observable
final class StubNavigator {
    private(set) var stack = HistoryNavigationStack()
    /// The commit being loaded toward, while a stub's other end loads.
    private(set) var pendingSHA: String?

    @ObservationIgnored weak var controller: GraphTableController?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init() {}

    var canGoBack: Bool {
        !stack.back.isEmpty
    }

    var canGoForward: Bool {
        !stack.forward.isEmpty
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
    /// across stubs, loading the parent when it isn't loaded.
    func goToParent(index: Int, in history: HistoryModel) {
        guard let row = selectedRow(in: history) else {
            return
        }
        let origin = history.commit(atRow: row)?.sha
        if let parentRow = history.parentRow(ofRow: row, parentIndex: index) {
            go(toRow: parentRow, from: origin, in: history)
            return
        }
        guard let commit = history.commit(atRow: row), commit.parentSHAs.indices.contains(index), !history.isComplete else {
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
        guard let target = stack.goBack(from: currentSHA(in: history)) else {
            return
        }
        show(target, in: history)
    }

    func goForward(in history: HistoryModel) {
        guard let target = stack.goForward(from: currentSHA(in: history)) else {
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
        if case .found(let row) = result {
            if let origin {
                stack.record(from: origin)
            }
            controller?.reveal(row: row, pulse: true)
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
        if let origin {
            stack.record(from: origin)
        }
        controller?.reveal(row: row, pulse: true)
    }

    private func show(_ sha: String, in history: HistoryModel) {
        if let row = history.row(of: sha) {
            controller?.reveal(row: row, pulse: true)
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
                self.controller?.reveal(row: row, pulse: true)
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
            if case .found(let row) = result {
                if let origin {
                    self.stack.record(from: origin)
                }
                self.controller?.reveal(row: row, pulse: true)
            }
        }
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
    /// commit.
    static func tooltip(for edge: CommitGraphEdge, row: Int, source: any GraphTableSource, isLoading: Bool) -> String {
        func describe(_ commit: Commit?) -> String {
            guard let commit else {
                return ""
            }
            let summary = commit.summary.isEmpty ? CommitRowContent.emptySummary : RichText.emojified(commit.summary)
            return ": \(shortenSHA(commit.sha)) \(summary)"
        }
        func commits(_ count: Int) -> String {
            count == 1 ? "1 commit" : "\(formatCount(count)) commits"
        }
        switch edge.kind {
        case .outgoingStub:
            if let parentRow = edge.parentRow {
                return "Continues \(commits(parentRow - row)) below" + describe(source.commit(atRow: parentRow))
            }
            if source.isGraphComplete {
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
