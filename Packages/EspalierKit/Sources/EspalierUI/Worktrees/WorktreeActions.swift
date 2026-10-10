// The worktree actions, on `WorktreesModel`: New Worktree… (⇧⌘W, and a
// branch's or pull request's "Check Out in New Worktree…"), Show Worktrees
// (⌥⌘W, which opens the repository popover at its worktrees), switching to
// a worktree, Rename…, and Delete… ("Delete Worktree?" with its suppression
// toggle; when git refuses, "Delete Worktree Failed" offers Delete Anyway,
// the model's retry).

import AppKit
import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import SwiftUI

/// Registers the worktree actions.
@MainActor
enum WorktreeActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        actions.register(.switchToWorktree, isEnabled: { [weak context] action in
            guard case .switchToWorktree(let path) = action, let repository = context?.repository else {
                return false
            }
            return worktree(at: path, in: repository) != nil
        }) { [weak context] action in
            guard case .switchToWorktree(let path) = action, let context, let repository = context.repository,
                  let worktree = worktree(at: path, in: repository) else {
                return
            }
            await context.presenter.perform { _ throws(OperationError) in
                try await repository.worktrees.switchToWorktree(worktree)
            }
        }

        actions.register(.newWorktree) { [weak context] action in
            guard case .newWorktree(let branch, let pullRequest) = action, let context, let repository = context.repository else {
                return
            }
            AddWorktreeSheet.present(branch: branch, pullRequest: pullRequest, repository: repository, context: context)
        }

        actions.register(.showWorktrees) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            reveal(repository, in: context)
        }

        actions.register(.renameWorktree, isEnabled: { [weak context] action in
            guard case .renameWorktree(let path) = action, let repository = context?.repository,
                  let worktree = worktree(at: path, in: repository) else {
                return false
            }
            return repository.worktrees.canRename(worktree)
        }) { [weak context] action in
            guard case .renameWorktree(let path) = action, let context, let repository = context.repository,
                  let worktree = worktree(at: path, in: repository) else {
                return
            }
            RenameWorktreeSheet.present(worktree, repository: repository, context: context)
        }

        actions.register(.deleteWorktree, isEnabled: { [weak context] action in
            guard case .deleteWorktree(let path) = action, let repository = context?.repository,
                  let worktree = worktree(at: path, in: repository) else {
                return false
            }
            return repository.worktrees.canRemove(worktree)
        }) { [weak context] action in
            guard case .deleteWorktree(let path) = action, let context, let repository = context.repository,
                  let worktree = worktree(at: path, in: repository) else {
                return
            }
            // Asks first (with "Do not show this message again"); when git
            // refuses, the error offers Delete Anyway, and Cancel leaves
            // everything as it was (the model deletes before it switches).
            await context.presenter.perform { answers throws(OperationError) in
                try await repository.worktrees.remove(worktree, confirmed: answers.confirmed)
            }
        }
    }

    // MARK: Helpers

    /// The repository's worktree at `path`, as git lists it.
    static func worktree(at path: String, in repository: RepositoryModel) -> WorktreeEntry? {
        repository.worktrees.entries.first { $0.path == path }
    }

    /// Show Worktrees: the repository popover opens, listing the
    /// repository's worktrees above its repositories even when it has only
    /// its main worktree, the window's highlighted.
    static func reveal(_ repository: RepositoryModel, in context: WindowContext) {
        let state = context.state.featureState(WorktreesWindowState.self) { WorktreesWindowState() }
        state.revealedRepository = repository.id
        context.state.isRepositoryPopoverPresented = true
    }

    /// Copy Worktree Name, Copy Worktree Path.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
