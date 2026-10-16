// The stash actions, on `StashModel`: Stash All Changes (a new entry for the
// current branch), Show/Hide Stashed Changes (⌃H: the current branch's
// newest stash, or back to Changes), and for any entry Restore, Apply, and
// Discard… with "Discard Stash?". Restoring, applying, or discarding the
// stash being shown goes back to Changes, where restored files are.

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
            await context.presenter.perform { _ throws(OperationError) in
                try await repository.stash.stashAllChanges()
            }
        }

        // Titled "Show Stashed Changes" or "Hide Stashed Changes" by
        // `RepositoryCapabilities`, which follow the stash shown.
        actions.register(.toggleStashedChanges) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            if isShowingStashPlace(context) {
                context.select(.changes)
            } else if let newest = repository.stash.current {
                context.select(.stash(sha: newest.stashSha))
            }
        }

        actions.register(.restoreStash, isEnabled: { [weak context] action in
            guard case .restoreStash(let sha) = action, let context, let repository = context.repository else {
                return false
            }
            return canApply(sha, in: repository)
        }) { [weak context] action in
            guard case .restoreStash(let sha) = action, let context, let repository = context.repository,
                  let stash = entry(sha, in: repository) else {
                return
            }
            let restored: Void? = await context.presenter.perform { _ throws(OperationError) in
                try await repository.stash.restore(stash)
            }
            // The files are in the Changes list now (or conflicted there).
            if restored != nil {
                leaveStashPlace(of: sha, in: context)
            }
        }

        actions.register(.applyStash, isEnabled: { [weak context] action in
            guard case .applyStash(let sha) = action, let context, let repository = context.repository else {
                return false
            }
            return canApply(sha, in: repository)
        }) { [weak context] action in
            guard case .applyStash(let sha) = action, let context, let repository = context.repository,
                  let stash = entry(sha, in: repository) else {
                return
            }
            let applied: Void? = await context.presenter.perform { _ throws(OperationError) in
                try await repository.stash.apply(stash)
            }
            // The files are in the Changes list now (or conflicted there).
            if applied != nil {
                leaveStashPlace(of: sha, in: context)
            }
        }

        actions.register(.discardStash, isEnabled: { [weak context] action in
            guard case .discardStash(let sha) = action, let context, let repository = context.repository else {
                return false
            }
            return canDiscard(sha, in: repository)
        }) { [weak context] action in
            guard case .discardStash(let sha) = action, let context, let repository = context.repository,
                  let stash = entry(sha, in: repository) else {
                return
            }
            let discarded: Void? = await context.presenter.perform { answers throws(OperationError) in
                try await repository.stash.discard(stash, confirmed: answers.confirmed)
            }
            if discarded != nil {
                leaveStashPlace(of: sha, in: context)
            }
        }
    }

    // MARK: Rules

    /// Whether the entry `sha` can be restored or applied: it's listed, the
    /// working directory and the repository have no conflicts (the model
    /// refuses then), and nothing the user started runs.
    static func canApply(_ sha: String, in repository: RepositoryModel) -> Bool {
        guard repository.isUsable, entry(sha, in: repository) != nil, !isBusy(repository) else {
            return false
        }
        let hasConflicts = repository.operations.conflictState != nil
            || repository.changes.workingDirectory.files.contains { $0.status.kind == .conflicted }
        return !hasConflicts
    }

    /// Whether the entry `sha` can be discarded: it's listed, and nothing
    /// the user started runs.
    static func canDiscard(_ sha: String, in repository: RepositoryModel) -> Bool {
        repository.isUsable && entry(sha, in: repository) != nil && !isBusy(repository)
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

    /// The listed entry whose commit is `sha`.
    private static func entry(_ sha: String, in repository: RepositoryModel) -> StashEntry? {
        repository.gitState.stashes.entry(sha)
    }

    /// Whether the window shows a stash.
    private static func isShowingStashPlace(_ context: WindowContext) -> Bool {
        if case .stash? = context.state.place { true } else { false }
    }

    /// Goes to Changes when the window shows the entry `sha`.
    private static func leaveStashPlace(of sha: String, in context: WindowContext) {
        if context.state.place == .stash(sha: sha) {
            context.select(.changes)
        }
    }
}
