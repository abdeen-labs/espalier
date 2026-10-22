// History's simple list: one branch's commits one after another, newest
// first (the current branch's, or another branch's in its place), with a
// notice above the current branch's when its base has moved on. Its rows are the history's (`HistoryModel.simpleOutline`); selection,
// the commit menus, drags, drops, search, and Go to Commit work as in the
// graph.

import AppKit
import EspalierCore
import GitHubKit
import GitKit
import SwiftUI

/// The simple list, with the base's notice above it.
struct SimpleHistoryList: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        let history = repository.history
        VStack(spacing: 0) {
            if let status = history.simpleBaseStatus {
                // Grows in over 0.22 s and leaves over 0.15 s, the list
                // moving with it.
                SimpleListBanner(status: status)
                    .padding(.horizontal, Metrics.CommitRow.selectionInset)
                    .padding(.top, Metrics.insetSmall)
                    .padding(.bottom, Metrics.grid)
                    .barTransition()
            }
            list(history)
        }
        .barMotion(history.simpleBaseStatus != nil)
        .background(Color(espalier: Palette.background))
    }

    @ViewBuilder
    private func list(_ history: HistoryModel) -> some View {
        if history.commitSHAs.isEmpty, history.isLoading {
            PlaceholderRows()
        } else if history.commitSHAs.isEmpty {
            // An unborn branch.
            PlaceholderNote("No commits yet")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SimpleListTableView(
                history: history,
                presentation: SimpleListPresentation(repository: repository),
                selection: history.selection.shas,
                reorderInsertionRow: context.state.history.reorder?.insertionRow,
                actions: SimpleListActions.make(repository: repository, context: context)
            )
        }
    }
}

/// "main has 5 new commits since this branch started." with Update, which
/// merges the base into the branch (Update from <base>).
struct SimpleListBanner: View {
    let status: SimpleHistoryBaseStatus
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        HistoryBanner(systemImage: "arrow.down", message: Self.message(status, numberFormat: numberFormat)) {
            ActionButton(.updateFromDefaultBranch, title: "Update")
        }
    }

    /// "**main** has 5 new commits since this branch started.", the count
    /// in `numberFormat`.
    static func message(_ status: SimpleHistoryBaseStatus, numberFormat: NumberFormat) -> AttributedString {
        var name = AttributedString(status.name)
        name.font = Typography.secondary.weight(.semibold)
        name.foregroundColor = .text
        let count = status.newCommitCount
        let commits = count == 1 ? "1 new commit" : "\(formatCount(count, numberFormat)) new commits"
        return name + AttributedString(" has \(commits) since this branch started.")
    }
}

extension SimpleListPresentation {
    /// What the simple list's rows show of `repository`'s state.
    @MainActor
    init(repository: RepositoryModel) {
        self.init()
        hasRemote = !repository.gitState.remotes.all.isEmpty
        search = repository.history.search
        headSHA = repository.gitState.tip.sha
        avatarEndpoint = repository.record.gitHubRepository?.endpoint
        allowsDragging = repository.operations.current == nil && repository.operations.conflictState == nil
        decorations = repository.history.decorationsGeneration
        railColors = SimpleRailColors(
            branchColors: BranchColors.of(repository),
            start: repository.history.simpleStart,
            branch: repository.history.shownBranch
        )
    }
}

extension SimpleListActions {
    /// The simple list's actions for a repository's history in a window:
    /// the graph's, by commit rather than by row where a merge's commits
    /// show.
    @MainActor
    static func make(repository: RepositoryModel, context: WindowContext) -> SimpleListActions {
        let history = repository.history
        let state = context.state.history
        let graph = HistoryTableActions.make(repository: repository, context: context)
        var actions = SimpleListActions()
        actions.select = graph.select
        actions.activate = {
            state.fileListFocusRequest += 1
        }
        actions.setExpanded = { row, expanded in
            history.setMergeExpanded(expanded, row: row)
        }
        actions.menu = { [weak context] shas, clicked in
            guard let context, let commit = history.commit(clicked) else {
                return nil
            }
            return CommitContextMenus.menu(shas: shas, clicked: commit, repository: repository, context: context)
        }
        actions.dragPayload = graph.dragPayload
        actions.dragBegan = graph.dragBegan
        actions.dragEnded = graph.dragEnded
        actions.validateDrop = graph.validateDrop
        actions.acceptDrop = graph.acceptDrop
        actions.moveReorderInsertion = graph.moveReorderInsertion
        actions.confirmReorder = graph.confirmReorder
        actions.cancelReorder = graph.cancelReorder
        actions.cancel = graph.cancel
        actions.copy = graph.copy
        actions.moveSearchMatch = graph.moveSearchMatch
        actions.showFind = graph.showFind
        actions.accessibilityActions = { [weak context] sha, row in
            guard let context else {
                return []
            }
            return CommitContextMenus.accessibilityActions(sha: sha, navigates: row != nil, repository: repository, context: context)
        }
        return actions
    }
}
