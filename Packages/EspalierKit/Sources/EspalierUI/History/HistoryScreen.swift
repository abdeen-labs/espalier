// History, a branch's Compare, and a tag: the graph and its header on the
// left, the selected commit's detail on the right, in the place's inner
// split.

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// History's state in one window: going back and forward, keyboard
/// reorder, compare's error, and the graph's table.
@MainActor @Observable
final class HistoryWindowState {
    /// Follows stubs, parents, and children, and remembers the jumps.
    let navigator = StubNavigator()
    /// The commits being moved with the keyboard, while reordering.
    var reorder: KeyboardReorderState?
    /// Why the last comparison couldn't load.
    var compareError: OperationError?
    /// Asks the commit's file list to take focus (Return in the graph).
    var fileListFocusRequest = 0

    /// The graph's table, while History shows.
    @ObservationIgnored weak var controller: GraphTableController? {
        didSet {
            navigator.controller = controller
        }
    }

    init() {}
}

extension WindowState {
    /// History's state in this window.
    var history: HistoryWindowState {
        featureState(HistoryWindowState.self) { HistoryWindowState() }
    }
}

/// History (`.history`), a branch (`.branch`: the current one focused on
/// HEAD, another as Compare), or a tag (`.tag`).
public struct HistoryScreen: View {
    private let repository: RepositoryModel
    private let place: SidebarPlace
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel, place: SidebarPlace) {
        self.repository = repository
        self.place = place
    }

    public var body: some View {
        let kind = place.kind(currentBranchRef: repository.gitState.tip.branch?.ref)
        SplitView(kind) {
            HistoryListPane(repository: repository, place: place)
        } trailing: {
            HistoryDetailPane(repository: repository)
        }
        .onAppear {
            repository.history.activate()
        }
        .onDisappear {
            repository.history.setSearchQuery("")
            repository.history.deactivate()
            context.state.history.reorder = nil
        }
        .onSubmit(of: .search) {
            repository.history.selectNextSearchMatch()
        }
        .task(id: PlaceKey(repository: repository.id, place: place, kind: kind)) {
            await HistoryPlaces.enter(place, kind: kind, repository: repository, context: context)
        }
        // Choosing another repository shows its History at once.
        .motionScope(AnyHashable(ObjectIdentifier(repository)))
    }

    private struct PlaceKey: Hashable {
        let repository: RepositoryID
        let place: SidebarPlace
        let kind: PlaceKind
    }
}

/// Entering History's places: the history, focused on a commit for the
/// current branch and tags, or a comparison for another branch.
@MainActor
enum HistoryPlaces {
    static func enter(_ place: SidebarPlace, kind: PlaceKind, repository: RepositoryModel, context: WindowContext) async {
        let history = repository.history
        let state = context.state.history
        switch (place, kind) {
        case (.branch(let ref), .compare):
            guard let branch = repository.gitState.branches.all.first(where: { $0.ref == ref }) else {
                return
            }
            // Coming back to the comparison shown keeps it (and its
            // direction); the model compares again when a tip moves.
            if case .compare(let shown, _) = history.mode, shown.ref == branch.ref, shown.tip.sha == branch.tip.sha {
                return
            }
            await compare(branch, direction: .behind, repository: repository, state: state)
        case (.branch, _):
            history.resetToHistoryMode()
            await waitForHistory(history)
            if let head = repository.gitState.tip.sha {
                await reveal(head, in: history, state: state)
            }
        case (.tag(let name), _):
            history.resetToHistoryMode()
            await waitForHistory(history)
            if let sha = repository.gitState.tags?[name] {
                await reveal(sha, in: history, state: state)
            }
        default:
            history.resetToHistoryMode()
        }
    }

    /// Compares the current branch with `branch` in `direction`; a failure
    /// shows in the list rather than as an alert.
    static func compare(_ branch: Branch, direction: ComparisonDirection, repository: RepositoryModel, state: HistoryWindowState) async {
        state.compareError = nil
        do throws(OperationError) {
            try await repository.history.compare(with: branch, direction: direction)
        } catch {
            if !error.isCancellation {
                state.compareError = error
            }
        }
    }

    /// Selects `sha` and brings it into view, loading pages until it's
    /// loaded.
    static func reveal(_ sha: String, in history: HistoryModel, state: HistoryWindowState) async {
        if case .found(let row) = await history.loadUntil(sha: sha) {
            state.controller?.reveal(row: row, pulse: false)
        }
    }

    /// Waits for the history's first load.
    private static func waitForHistory(_ history: HistoryModel) async {
        if history.graph.isEmpty || history.isLoading {
            await history.idle()
        }
    }
}

// MARK: - The list

/// The graph and its header: History's scope and count, or Compare's
/// branch, direction, and call to action.
struct HistoryListPane: View {
    let repository: RepositoryModel
    let place: SidebarPlace
    @Environment(WindowContext.self) private var context

    var body: some View {
        let history = repository.history
        let state = context.state.history
        let isCompare = place.kind(currentBranchRef: repository.gitState.tip.branch?.ref) == .compare
        VStack(spacing: 0) {
            if isCompare {
                CompareHeaderContainer(repository: repository, place: place)
            } else {
                HistoryHeaderContainer(repository: repository)
            }
            Hairline()
            // Simple ↔ Graph crossfades over 0.15 s.
            list(history: history, state: state, isCompare: isCompare)
                .motion(Motion.leave, value: history.style)
                .overlay(alignment: .top) {
                    if let reorder = state.reorder {
                        KeyboardReorderHint(count: reorder.shas.count)
                            .padding(.top, Metrics.insetSmall)
                    }
                }
        }
        .background {
            SearchQueryBridge(history: history)
        }
    }

    @ViewBuilder
    private func list(history: HistoryModel, state: HistoryWindowState, isCompare: Bool) -> some View {
        if isCompare, let error = state.compareError {
            CenteredMessage(error.title, systemImage: "exclamationmark.triangle", description: error.message, tint: Color(espalier: Palette.warningMark))
                .fillingSpace()
        } else if isCompare, !isComparisonShown(history) {
            DelayedProgressView()
        } else if isCompare, history.commitSHAs.isEmpty {
            PlaceholderNote(history.comparison.emptyListMessage ?? "No commits")
        } else if !isCompare, let error = history.loadError, history.commitSHAs.isEmpty {
            CenteredMessage(error.title, systemImage: "exclamationmark.triangle", description: error.message, tint: Color(espalier: Palette.warningMark))
                .fillingSpace()
        } else if !isCompare, history.style == .simple {
            // History's simple mode: the current branch, one commit after
            // another (History/Simple/).
            SimpleHistoryList(repository: repository)
                .transition(.opacity)
        } else if !isCompare, history.graph.isEmpty {
            PlaceholderRows()
                .transition(.opacity)
        } else {
            GraphTableView(
                source: history,
                presentation: GraphPresentation(repository: repository, place: place),
                selection: GraphSelection(shas: history.selection.shas, isWorkingCopy: history.isWorkingCopySelected),
                reorderInsertionRow: state.reorder?.insertionRow,
                actions: HistoryTableActions.make(repository: repository, context: context),
                onController: { controller in
                    state.controller = controller
                }
            )
            .overlay {
                if !isCompare, history.commitSHAs.isEmpty, !history.isLoading {
                    // An unborn branch: the working copy, and nothing below.
                    PlaceholderNote("No history")
                        .padding(.top, Metrics.Graph.rowHeight * 2)
                }
            }
            .transition(.opacity)
        }
    }

    /// Whether the list shows the comparison of this place's branch (not
    /// still the history, or another branch's comparison).
    private func isComparisonShown(_ history: HistoryModel) -> Bool {
        guard case .compare(let branch, _) = history.mode, case .branch(let ref) = place else {
            return false
        }
        return branch.ref == ref
    }
}

/// Passes the toolbar search's text to the history: a small view of its
/// own, so typing redraws only it.
private struct SearchQueryBridge: View {
    let history: HistoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        Color.clear
            .onChange(of: context.state.searchText, initial: true) {
                history.setSearchQuery(context.state.searchText)
            }
    }
}

extension GraphPresentation {
    /// What the graph's rows show of `repository`'s state in `place`.
    init(repository: RepositoryModel, place: SidebarPlace) {
        self.init()
        let gitState = repository.gitState
        decorations = repository.history.decorationsGeneration
        headSHA = gitState.tip.sha
        currentBranch = gitState.tip.branch?.name
        if case .detached = gitState.tip {
            isDetached = true
        }
        let files = repository.changes.workingDirectory.files
        let conflicted = files.count { if case .conflicted = $0.status { true } else { false } }
        workingCopy = WorkingCopySummary(changedFiles: files.count, conflictedFiles: conflicted)
        tagsToPush = Set(repository.branches.tagsToPush)
        hasRemote = !gitState.remotes.all.isEmpty
        remoteNames = gitState.remotes.all.map(\.name).sorted { $0.count > $1.count }
        search = repository.history.search
        switch place {
        case .branch(let ref) where ref == gitState.tip.branch?.ref:
            focusedSHA = gitState.tip.sha
        case .tag(let name):
            focusedSHA = gitState.tags?[name]
        default:
            focusedSHA = nil
        }
        avatarEndpoint = repository.record.gitHubRepository?.endpoint
        allowsDragging = repository.operations.current == nil && repository.operations.conflictState == nil
        setBranches(of: repository)
    }
}

// MARK: - The detail

/// The selected commit's detail, the range's, the working copy's, or why
/// there's none.
struct HistoryDetailPane: View {
    let repository: RepositoryModel

    var body: some View {
        let history = repository.history
        let selection = history.selection
        if history.isWorkingCopySelected {
            WorkingCopyDetail(repository: repository)
        } else if selection.shas.isEmpty {
            PlaceholderNote("No commit selected")
        } else if selection.shas.count > 1, !selection.isContiguous {
            NonContiguousView()
        } else {
            CommitDetailView(repository: repository)
        }
    }
}
