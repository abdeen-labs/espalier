// Home's actions: Go ▸ Home, and opening a piece of work from Home or the
// shelf, which switches to its repository at its worktree, whichever
// repository is selected.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// Registers Home's actions.
@MainActor
enum HomeActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        // Offered while Home is on (Settings' Home setting).
        actions.register(.showHome, isHidden: { [weak context] _ in
            !(context?.app.preferences.showsHome ?? false)
        }) { [weak context] _ in
            guard let context else {
                return
            }
            context.state.isRepositoryPopoverPresented = false
            context.state.isBranchPopoverPresented = false
            context.state.isShowingHome = true
        }

        actions.register(.openWork) { [weak context] action in
            guard case .openWork(let key, let place) = action, let context else {
                return
            }
            await open(key, place: place, in: context)
        }
    }

    /// Selects the repository of the piece of work `key` at its worktree,
    /// shows `place` there (nil: its last place), and leaves Home.
    ///
    /// - The worktree the record points at: the repository is selected.
    /// - Another listed repository's folder: that repository is selected.
    /// - Another worktree: the record switches to it
    ///   (`WorktreesModel.switchToWorktree`), which selects the repository;
    ///   one whose folder is gone asks to remove it instead, and the window
    ///   stays where it is.
    static func open(_ key: WorktreeKey, place: SidebarPlace?, in context: WindowContext) async {
        let app = context.app
        guard let record = app.record(key.repositoryID) else {
            return
        }
        if WorktreeKey(repositoryID: record.id, path: record.path) == key {
            app.select(.repository(record.id))
            finish(showing: place, in: context)
            return
        }
        guard let status = app.worktreeStatuses[record.id]?.first(where: {
            WorktreeKey(repositoryID: record.id, path: $0.entry.path) == key
        }) else {
            return
        }
        if let other = status.repositoryID {
            app.select(.repository(other))
            finish(showing: place, in: context)
            return
        }
        guard let repository = app.repository(record.id) else {
            return
        }
        let worktree = status.entry
        if repository.worktrees.isMissing(worktree) {
            await context.presenter.perform { answers throws(OperationError) in
                try await repository.worktrees.remove(worktree, confirmed: answers.confirmed)
            }
            return
        }
        let switched: Void? = await context.presenter.perform { _ throws(OperationError) in
            try await repository.worktrees.switchToWorktree(worktree)
        }
        if switched != nil {
            finish(showing: place, in: context)
        }
    }

    /// Leaves Home for the selected repository, at `place` when one is
    /// given.
    private static func finish(showing place: SidebarPlace?, in context: WindowContext) {
        context.leaveHome()
        if let place {
            context.select(place)
        }
    }
}
