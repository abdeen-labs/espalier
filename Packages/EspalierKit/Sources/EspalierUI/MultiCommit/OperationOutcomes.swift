// The toasts for merges, rebases, cherry-picks, squashes, reorders, undos,
// and checkouts that switched worktrees, also when a recovery runs the
// operation again. The copy is the state layer's. Undo is offered only
// while the state layer's `operations.undo` is valid: a toast whose undo
// expires loses its button.

import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Observation

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
            let toast = Toast(summary, undo: undoAction(repository: repository, context: context))
            expireUndo(of: toast, undo: undo, repository: repository, context: context)
            return toast
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
        }
        if let toast {
            context.presenter.show(toast)
        }
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
    static func undoAction(repository: RepositoryModel, context: WindowContext) -> ToastAction {
        ToastAction { [weak context] in
            guard let context else {
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

    /// Takes Undo off `toast` once `undo` is no longer the state layer's
    /// (the branch moved, changes appeared, or it was undone).
    private static func expireUndo(of toast: Toast, undo: MultiCommitUndo, repository: RepositoryModel, context: WindowContext) {
        let operations = repository.operations
        let presenter = context.presenter
        // The presenter shows the toast once the outcome returns it: watch
        // from the next turn, when it's there.
        Task { @MainActor [weak operations, weak presenter] in
            guard let operations, let presenter else {
                return
            }
            watchUndo(of: toast, undo: undo, operations: operations, presenter: presenter)
        }
    }

    private static func watchUndo(of toast: Toast, undo: MultiCommitUndo, operations: MultiCommitOperationsModel, presenter: WindowPresenter) {
        observe { [weak operations, weak presenter] in
            guard let operations, let presenter else {
                return false
            }
            guard presenter.toasts.contains(where: { $0.id == toast.id }) else {
                return false
            }
            guard operations.undo == undo else {
                presenter.replaceToast(Toast(id: toast.id, toast.message, systemImage: toast.systemImage))
                return false
            }
            return true
        }
    }

    /// Calls `check` now and again whenever what it reads changes, for as
    /// long as it returns true.
    static func observe(_ check: @escaping @MainActor () -> Bool) {
        let registration = ObservationRegistration()
        let keepsObserving = withObservationTracking {
            check()
        } onChange: {
            Task { @MainActor in
                if registration.isActive {
                    observe(check)
                }
            }
        }
        registration.isActive = keepsObserving
    }
}

/// Whether an observation's change handler should observe again.
@MainActor
private final class ObservationRegistration {
    var isActive = true
}
