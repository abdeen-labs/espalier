// History, a branch, and a tag: the list and its header on the left, the
// selected commit's detail on the right, in the place's inner split, whose
// widths are the simple list's or the graph's. A branch's place shows its
// history focused on its tip; another branch's place can also compare it with
// the current branch (Behind and Ahead, desktop's Compare).

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// What another branch's place shows: the branch's history, or the commits
/// one side has that the other doesn't.
nonisolated enum BranchView: Hashable, Sendable {
    case history
    case compare(ComparisonDirection)
}

/// The view a branch's place shows, by the branch's ref.
nonisolated struct BranchViewChoice: Equatable, Sendable {
    var ref: String
    var view: BranchView
}

/// Why the commit a place focuses on isn't in the list, and what shows it.
nonisolated struct HistoryPlaceNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The simple list's line doesn't have it (the line's branch, or
        /// nil on a detached HEAD): Show in Graph.
        case notOnLine(branch: String?)
        /// The graph's scope doesn't reach it: Show All Branches.
        case outsideScope(HistoryScope)
    }

    /// The place it's about.
    var place: SidebarPlace
    /// The tag's or branch's name.
    var name: String
    var kind: Kind

    /// "**v1.0** isn't in main's history."
    @MainActor var message: AttributedString {
        var name = AttributedString(self.name)
        name.font = Typography.secondary.weight(.semibold)
        name.foregroundColor = .text
        switch kind {
        case .notOnLine(let branch):
            return name + AttributedString(" isn\u{2019}t in \(branch ?? "HEAD")\u{2019}s history.")
        case .outsideScope(let scope):
            return name + AttributedString(" isn\u{2019}t in the graph, which shows \(scope.title).")
        }
    }

    /// The button that shows it; nil when nothing would.
    var actionTitle: String? {
        switch kind {
        case .notOnLine: "Show in Graph"
        case .outsideScope(let scope): scope == .allBranches ? nil : "Show All Branches"
        }
    }
}

/// History's state in one window: going back and forward, keyboard
/// reorder, the branch places' views, compare's error, and the graph's
/// table.
@MainActor @Observable
final class HistoryWindowState {
    /// Follows stubs, parents, and children, and remembers the jumps.
    let navigator = StubNavigator()
    /// The commits being moved with the keyboard, while reordering.
    var reorder: KeyboardReorderState?
    /// The view of the last branch place shown (or the one Compare to
    /// Branch asked for).
    var branchView: BranchViewChoice?
    /// Why the last comparison couldn't load.
    var compareError: OperationError?
    /// Why the place's commit isn't in the list, while it shows.
    var notice: HistoryPlaceNotice?
    /// Asks the commit's file list to take focus (Return in the graph).
    var fileListFocusRequest = 0

    /// The graph's table, while History shows.
    @ObservationIgnored weak var controller: GraphTableController? {
        didSet {
            navigator.controller = controller
        }
    }

    init() {}

    /// The view the place of the branch `ref` shows: its history unless a
    /// comparison was chosen there last.
    func view(forBranch ref: String) -> BranchView {
        guard let branchView, branchView.ref == ref else {
            return .history
        }
        return branchView.view
    }
}

extension WindowState {
    /// History's state in this window.
    var history: HistoryWindowState {
        featureState(HistoryWindowState.self) { HistoryWindowState() }
    }
}

/// History (`.history`), a branch (`.branch`), or a tag (`.tag`).
public struct HistoryScreen: View {
    private let repository: RepositoryModel
    private let place: SidebarPlace
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel, place: SidebarPlace) {
        self.repository = repository
        self.place = place
    }

    public var body: some View {
        let history = repository.history
        let kind = place.kind(style: history.style)
        // Simple ↔ Graph crossfades over 0.15 s: each has its own widths,
        // so its own split.
        ZStack {
            SplitView(kind) {
                HistoryListPane(repository: repository, place: place)
            } trailing: {
                HistoryDetailPane(repository: repository)
            }
            .id(kind)
            .transition(.opacity)
        }
        .motion(Motion.leave, value: kind)
        .onAppear {
            history.activate()
        }
        .onDisappear {
            history.setSearchQuery("")
            history.deactivate()
            context.state.history.reorder = nil
        }
        .onSubmit(of: .search) {
            history.selectNextSearchMatch()
        }
        .task(id: placeKey) {
            await HistoryPlaces.enter(place, repository: repository, context: context)
        }
        // Choosing another repository shows its History at once.
        .motionScope(AnyHashable(ObjectIdentifier(repository)))
    }

    /// What entering the place depends on.
    private var placeKey: PlaceKey {
        let history = repository.history
        var view = BranchView.history
        if case .branch(let ref) = place {
            view = context.state.history.view(forBranch: ref)
        }
        return PlaceKey(
            repository: repository.id,
            place: place,
            style: history.style,
            scope: history.scope,
            currentBranch: repository.gitState.tip.branch?.ref,
            branchView: view
        )
    }

    private struct PlaceKey: Hashable {
        let repository: RepositoryID
        let place: SidebarPlace
        let style: HistoryStyle
        let scope: HistoryScope
        let currentBranch: String?
        let branchView: BranchView
    }
}

/// Entering History's places: the history focused on HEAD's commit for the
/// current branch, on a tag's commit, or on another branch's tip in its
/// history; or another branch's comparison.
@MainActor
enum HistoryPlaces {
    static func enter(_ place: SidebarPlace, repository: RepositoryModel, context: WindowContext) async {
        let history = repository.history
        let state = context.state.history
        state.notice = nil
        switch place {
        case .branch(let ref):
            guard let branch = otherBranch(of: place, in: repository) else {
                // The current branch: HEAD's history.
                history.showBranch(ref: nil)
                history.resetToHistoryMode()
                await waitForHistory(history)
                if let head = repository.gitState.tip.sha {
                    await reveal(head, in: history, state: state)
                }
                return
            }
            history.showBranch(ref: ref)
            switch state.view(forBranch: ref) {
            case .compare(let direction) where repository.gitState.tip.branch != nil:
                // Coming back to the comparison shown keeps it; the model
                // compares again when a tip moves.
                if case .compare(let shown, let shownDirection) = history.mode, shown.ref == branch.ref,
                   shown.tip.sha == branch.tip.sha, shownDirection == direction {
                    return
                }
                await compare(branch, direction: direction, repository: repository, state: state)
            case .history, .compare:
                history.resetToHistoryMode()
                await waitForHistory(history)
                let result = await reveal(branch.tip.sha, in: history, state: state)
                state.notice = notice(for: result, place: place, name: branch.name, history: history, repository: repository)
            }
        case .tag(let name):
            history.showBranch(ref: nil)
            history.resetToHistoryMode()
            await waitForHistory(history)
            if let sha = repository.gitState.tags?[name] {
                let result = await reveal(sha, in: history, state: state)
                state.notice = notice(for: result, place: place, name: name, history: history, repository: repository)
            }
        case .changes, .history, .pullRequest, .stash:
            history.showBranch(ref: nil)
            history.resetToHistoryMode()
        }
    }

    /// The branch a branch's place shows when it isn't the current one.
    static func otherBranch(of place: SidebarPlace, in repository: RepositoryModel) -> Branch? {
        guard case .branch(let ref) = place, ref != repository.gitState.tip.branch?.ref else {
            return nil
        }
        return repository.gitState.branches.all.first { $0.ref == ref }
    }

    /// Shows `branch`'s place comparing it with the current branch (Behind):
    /// Compare to Branch.
    static func showComparison(of branch: Branch, in context: WindowContext) {
        context.state.history.branchView = BranchViewChoice(ref: branch.ref, view: .compare(.behind))
        context.select(.branch(ref: branch.ref))
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
    /// loaded. The simple list scrolls to a selection itself.
    @discardableResult
    static func reveal(_ sha: String, in history: HistoryModel, state: HistoryWindowState) async -> GoToCommitResult {
        let result = await history.loadUntil(sha: sha)
        if case .found(let row) = result, history.style == .graph || history.mode != .history {
            state.controller?.reveal(row: row, pulse: false)
        }
        return result
    }

    /// What to say when the place's commit isn't in the list.
    private static func notice(
        for result: GoToCommitResult,
        place: SidebarPlace,
        name: String,
        history: HistoryModel,
        repository: RepositoryModel
    ) -> HistoryPlaceNotice? {
        guard case .notInHistory = result else {
            return nil
        }
        switch history.style {
        case .simple:
            return HistoryPlaceNotice(place: place, name: name, kind: .notOnLine(branch: repository.gitState.tip.branch?.name))
        case .graph:
            return HistoryPlaceNotice(place: place, name: name, kind: .outsideScope(history.scope))
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

/// The list and its header: History's style, scope, and count, or a
/// branch's name and views with the merge call to action.
struct HistoryListPane: View {
    let repository: RepositoryModel
    let place: SidebarPlace
    @Environment(WindowContext.self) private var context

    var body: some View {
        let history = repository.history
        let state = context.state.history
        let branch = HistoryPlaces.otherBranch(of: place, in: repository)
        VStack(spacing: 0) {
            if let branch {
                BranchHeaderContainer(repository: repository, branch: branch)
            } else {
                HistoryHeaderContainer(repository: repository)
            }
            Hairline()
            if let notice = state.notice, notice.place == place {
                HistoryNoticeBanner(notice: notice) {
                    switch notice.kind {
                    case .notOnLine:
                        history.setStyle(.graph)
                    case .outsideScope:
                        history.setScope(.allBranches)
                    }
                }
            }
            list(history: history, state: state, branch: branch)
                .overlay(alignment: .top) {
                    if let reorder = state.reorder {
                        KeyboardReorderHint(count: reorder.shas.count)
                            .padding(.top, Metrics.insetSmall)
                    }
                }
        }
        .barMotion(state.notice?.place == place)
        .background {
            SearchQueryBridge(history: history)
        }
    }

    @ViewBuilder
    private func list(history: HistoryModel, state: HistoryWindowState, branch: Branch?) -> some View {
        if let branch, case .compare = state.view(forBranch: branch.ref), repository.gitState.tip.branch != nil {
            comparison(history: history, state: state, branch: branch)
        } else if case .compare = history.mode {
            // Leaving a comparison for the history.
            DelayedProgressView()
        } else if let error = history.loadError, history.commitSHAs.isEmpty {
            CenteredMessage(error.title, systemImage: "exclamationmark.triangle", description: error.message, tint: Color(espalier: Palette.warningMark))
                .fillingSpace()
        } else if history.style == .simple {
            // History's simple mode: one branch's commits one after another
            // (History/Simple/).
            SimpleHistoryList(repository: repository)
        } else if history.graph.isEmpty {
            PlaceholderRows()
        } else {
            graph(history: history, state: state)
                .overlay {
                    if history.commitSHAs.isEmpty, !history.isLoading {
                        // An unborn branch: the working copy, and nothing below.
                        PlaceholderNote("No history")
                            .padding(.top, Metrics.Graph.rowHeight * 2)
                    }
                }
        }
    }

    /// Another branch's Behind or Ahead commits.
    @ViewBuilder
    private func comparison(history: HistoryModel, state: HistoryWindowState, branch: Branch) -> some View {
        if let error = state.compareError {
            CenteredMessage(error.title, systemImage: "exclamationmark.triangle", description: error.message, tint: Color(espalier: Palette.warningMark))
                .fillingSpace()
        } else if !isComparisonShown(of: branch, history: history) {
            DelayedProgressView()
        } else if history.commitSHAs.isEmpty {
            PlaceholderNote(history.comparison.emptyListMessage ?? "No commits")
        } else {
            graph(history: history, state: state)
        }
    }

    private func graph(history: HistoryModel, state: HistoryWindowState) -> some View {
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
    }

    /// Whether the list shows the comparison with `branch` (not still the
    /// history, or another branch's comparison).
    private func isComparisonShown(of branch: Branch, history: HistoryModel) -> Bool {
        guard case .compare(let shown, _) = history.mode else {
            return false
        }
        return shown.ref == branch.ref
    }
}

/// Why the place's commit isn't in the list, with the button that shows
/// it, above the list.
struct HistoryNoticeBanner: View {
    let notice: HistoryPlaceNotice
    var action: () -> Void = {}

    var body: some View {
        HistoryBanner(systemImage: "eye.slash", message: notice.message) {
            if let title = notice.actionTitle {
                Button(title, action: action)
            }
        }
        .padding(.horizontal, Metrics.CommitRow.selectionInset)
        .padding(.top, Metrics.insetSmall)
        .padding(.bottom, Metrics.grid)
        .barTransition()
    }
}

/// A card above History's list: a symbol in a soft circle, a message, and
/// a quiet button.
struct HistoryBanner<Action: View>: View {
    let systemImage: String
    let message: AttributedString
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(spacing: Metrics.insetMedium) {
            IconCircle(systemImage, tint: .accent)
            Text(message)
                .font(Typography.secondary)
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
                .buttonStyle(.quiet)
                .controlSize(.small)
        }
        .padding(.leading, Metrics.insetSmall)
        .padding(.trailing, Metrics.insetMedium)
        .padding(.vertical, Metrics.insetSmall)
        .cardSurface()
        .accessibilityElement(children: .contain)
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
        case .branch(let ref):
            focusedSHA = gitState.branches.all.first { $0.ref == ref }?.tip.sha
        case .tag(let name):
            focusedSHA = gitState.tags?[name]
        case .changes, .history, .pullRequest, .stash:
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
