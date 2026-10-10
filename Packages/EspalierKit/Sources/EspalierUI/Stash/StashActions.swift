// The stash actions, on `StashModel`: Stash All Changes ("Overwrite
// Stash?" when the branch has one), Show/Hide Stashed Changes (⌃H: the
// current branch's stash, or back to Changes), Restore (the current
// branch's stash only), and Discard… with "Discard Stash?". Restoring or
// discarding the stash being shown goes back to Changes, where the restored
// files are.

import EspalierCore
import GitKit

/// Registers the stash actions.
@MainActor
enum StashActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        actions.register(.stashAllChanges) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            // The place stays Changes and nothing confirms it: the entry
            // shows in the sidebar.
            await context.presenter.perform { answers throws(OperationError) in
                try await repository.stash.stashAllChanges(confirmed: answers.confirmed)
            }
        }

        // Titled "Show Stashed Changes" or "Hide Stashed Changes" by
        // `RepositoryCapabilities`, which follow the stash shown.
        actions.register(.toggleStashedChanges) { [weak context] _ in
            guard let context, let branch = context.repository?.gitState.tip.branch?.name else {
                return
            }
            if isShowingStashPlace(context) {
                context.select(.changes)
            } else {
                context.select(.stash(branch: branch))
            }
        }

        actions.register(.restoreStash, isEnabled: { [weak context] action in
            guard case .restoreStash(let branch) = action, let context, let repository = context.repository else {
                return false
            }
            return canRestore(branch, in: repository)
        }) { [weak context] action in
            guard case .restoreStash(let branch) = action, let context, let repository = context.repository,
                  let target = branch ?? repository.gitState.tip.branch?.name,
                  let stash = entry(target, in: repository) else {
                return
            }
            let restored: Void? = await context.presenter.perform { _ throws(OperationError) in
                try await repository.stash.restore(stash)
            }
            // The files are in the Changes list now (or conflicted there).
            if restored != nil {
                leaveStashPlace(of: target, in: context)
            }
        }

        actions.register(.discardStash, isEnabled: { [weak context] action in
            guard case .discardStash(let branch) = action, let context, let repository = context.repository else {
                return false
            }
            return canDiscard(branch, in: repository)
        }) { [weak context] action in
            guard case .discardStash(let branch) = action, let context, let repository = context.repository,
                  let target = branch ?? repository.gitState.tip.branch?.name,
                  let stash = entry(target, in: repository) else {
                return
            }
            let discarded: Void? = await context.presenter.perform { answers throws(OperationError) in
                try await repository.stash.discard(stash, confirmed: answers.confirmed)
            }
            if discarded != nil {
                leaveStashPlace(of: target, in: context)
            }
        }
    }

    // MARK: Rules

    /// Why another branch's stash can't be restored (`StashModel`'s copy).
    nonisolated static func restoreUnavailableReason(branch: String) -> String {
        "Switch to \(branch) to restore these changes."
    }

    /// Whether `branch`'s stash (nil: the current branch's) can be restored:
    /// it's the current branch's, the working directory and the repository
    /// have no conflicts (the model refuses then), and nothing the user
    /// started runs.
    static func canRestore(_ branch: String?, in repository: RepositoryModel) -> Bool {
        guard repository.isUsable, let current = repository.gitState.tip.branch?.name else {
            return false
        }
        let target = branch ?? current
        guard target == current, entry(target, in: repository) != nil, !isBusy(repository) else {
            return false
        }
        let hasConflicts = repository.operations.conflictState != nil
            || repository.changes.workingDirectory.files.contains { $0.status.kind == .conflicted }
        return !hasConflicts
    }

    /// Whether `branch`'s stash (nil: the current branch's) can be
    /// discarded: any branch's can, unless something the user started runs.
    static func canDiscard(_ branch: String?, in repository: RepositoryModel) -> Bool {
        guard repository.isUsable, let target = branch ?? repository.gitState.tip.branch?.name else {
            return false
        }
        return entry(target, in: repository) != nil && !isBusy(repository)
    }

    /// Whether an operation the user started holds the repository (the
    /// stash's buttons wait).
    static func isBusy(_ repository: RepositoryModel) -> Bool {
        guard let operation = repository.localOperation else {
            return false
        }
        return !operation.isBackgroundTask
    }

    // MARK: Helpers

    /// A branch's stash entry.
    private static func entry(_ branch: String, in repository: RepositoryModel) -> StashEntry? {
        repository.gitState.stashes.entriesByBranch[branch]
    }

    /// Whether the window shows a stash.
    private static func isShowingStashPlace(_ context: WindowContext) -> Bool {
        if case .stash? = context.state.place { true } else { false }
    }

    /// Goes to Changes when the window shows `branch`'s stash.
    private static func leaveStashPlace(of branch: String, in context: WindowContext) {
        if context.state.place == .stash(branch: branch) {
            context.select(.changes)
        }
    }
}
