// The toasts for merges, rebases, cherry-picks, squashes, reorders, undos,
// resets, and checkouts that switched worktrees, also when a recovery runs
// the operation again. The copy is the state layer's. Undo is offered only
// while the state layer's `operations.undo` is valid: on the toast while it
// shows, from Edit ▸ Undo after it closes too; once the undo expires, the
// toast loses its button and Edit ▸ Undo no longer offers it.

import EspalierCore
import EspalierSupport
import Foundation
import GitKit

/// Builds outcome toasts.
@MainActor
enum OperationOutcomes {
    /// "Merged feature into main", or "main is already up to
    /// date with feature"; nil for conflicts (the capsule and panel say
    /// so).
    static func toast(for outcome: MergeOutcome) -> Toast? {
        outcome.summary.map { Toast($0) }
    }

    /// The toast for a rebase, cherry-pick, squash, or reorder, with Undo
    /// for the last three while the state layer offers it.
    static func toast(for result: MultiCommitResult, repository: RepositoryModel, context: WindowContext) -> Toast? {
        guard let summary = result.summary else {
            return nil
        }
        switch result {
        case .cherryPicked, .squashed, .reordered:
            guard let undo = repository.operations.undo, undoMatches(undo, result) else {
                return Toast(summary)
            }
            return Toast(summary, undo: undoAction(undo, repository: repository, context: context))
        default:
            return Toast(summary)
        }
    }

    /// The toast for continuing an operation after its conflicts.
    static func toast(for outcome: ContinueOutcome, repository: RepositoryModel, context: WindowContext) -> Toast? {
        switch outcome {
        case .merge(let merge):
            toast(for: merge)
        case .multiCommit(let result):
            toast(for: result, repository: repository, context: context)
        }
    }

    /// "Squash of 2 commits undone.", "Reorder of 2 commits undone.",
    /// "Cherry-pick undone. Removed the 2 copied commits from
    /// main."; nil for a cherry-pick to a new branch, whose undo deletes
    /// the branch.
    static func toast(for undo: MultiCommitUndo) -> Toast? {
        undo.undoneMessage.map { Toast($0, systemImage: "arrow.uturn.backward.circle.fill") }
    }

    /// Reports what an operation a recovery ran again did, as its first run
    /// reports it: the same toast, with Undo while it's valid, and what a
    /// push leaves to the window.
    static func report(_ outcome: OperationOutcome, in context: WindowContext) {
        let toast: Toast?
        switch outcome {
        case .nothing:
            toast = nil
        case .checkout(let result, _):
            toast = self.toast(for: result)
        case .merge(let merge, _):
            toast = self.toast(for: merge)
        case .multiCommit(let result, let repositoryID):
            guard let repository = context.app.repository(repositoryID) else {
                return
            }
            toast = self.toast(for: result, repository: repository, context: context)
        case .push(let push, _):
            ShellActions.finish(push, in: context)
            toast = nil
        case .reset(let result, _):
            toast = self.toast(for: result)
        }
        if let toast {
            context.presenter.show(toast)
        }
    }

    /// "Reset main to a1b2c3d", without Undo.
    static func toast(for result: ResetResult) -> Toast {
        Toast(result.summary)
    }

    /// "Switched to worktree <name>" when checking out a branch switched to
    /// the worktree that has it; nothing for a plain checkout.
    static func toast(for result: CheckoutResult) -> Toast? {
        guard case .switchedToWorktree(let worktree) = result else {
            return nil
        }
        return Toast("Switched to worktree \(getWorktreeDisplayName(worktree))")
    }

    /// Undo: undoes the last operation through the presenter, then says so.
    /// Edit ▸ Undo names it ("Undo Squash") and offers it, after the toast
    /// closes too, while the window shows the repository (its ID and its
    /// worktree's path: another repository or worktree ends it for good)
    /// and `undo` is still its state layer's.
    static func undoAction(_ undo: MultiCommitUndo, repository: RepositoryModel, context: WindowContext) -> ToastAction {
        let id = repository.id
        let path = repository.record.path
        let operations = repository.operations
        return ToastAction(actionName: undo.kind.rawValue, isValid: { [weak context, weak operations] in
            guard let shown = context?.repository, shown.id == id, JSCompat.strictEquals(shown.record.path, path) else {
                return false
            }
            return operations?.undo == undo
        }) { [weak context, weak repository] in
            guard let context, let repository else {
                return
            }
            await context.presenter.perform { _ throws(OperationError) in
                try await repository.operations.undoLastOperation()
            } outcome: { undo in
                toast(for: undo)
            }
        }
    }

    /// Whether `undo` undoes the operation that produced `result`.
    private static func undoMatches(_ undo: MultiCommitUndo, _ result: MultiCommitResult) -> Bool {
        switch result {
        case .cherryPicked: undo.kind == .cherryPick
        case .squashed: undo.kind == .squash
        case .reordered: undo.kind == .reorder
        default: false
        }
    }
}
