// The Changes place's menu actions: Commit Changes (⌘↩, which runs Commit
// Merge or Continue, the operation panel's button, while an operation waits
// on the user, and is titled as they are), Generate Commit
// Message (⌥⌘G, gone while AI is off), Go to Commit Message (⌘J), Amend Last
// Commit, Undo Commit…, Discard All Changes…, Show All Work (⌥⌘A), and All
// Work's Mark Viewed (⌥⌘V), plus the Debug menu's Changes Apply benchmark. Each runs what the composer's controls run,
// through the window's presenter.

import EspalierCore
import GitKit

/// Registers the Changes place's actions.
@MainActor
enum ChangesActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        actions.register(.commitChanges, isEnabled: { [weak context] _ in
            // All Work has no composer to commit from.
            guard let context, context.state.place == .changes, !isShowingAllWork(context), let controller = controller(context) else {
                return false
            }
            // ⌘↩ in Changes: Commit Merge or Continue (the operation
            // panel's button) while an operation waits on the user, else
            // Commit, and nothing while an operation runs.
            if let slot = OperationSlotContent.make(controller.repository) {
                return slot.button.isEnabled
            }
            return OperationCapsuleContent.make(controller.repository) == nil && controller.canCommit
        }, title: { [weak context] _ in
            guard let repository = context?.repository, let slot = OperationSlotContent.make(repository) else {
                return nil
            }
            switch slot.button.kind {
            case .merge: return "Commit Merge"
            case .continueOperation(let name): return "Continue \(name)"
            case .commit: return nil
            }
        }) { [weak context] _ in
            guard let context, let controller = controller(context) else {
                return
            }
            switch OperationSlotContent.make(controller.repository)?.kind {
            case .merge?:
                await controller.commitMerge()
            case .continueOperation?:
                await MultiCommitActions.continueOperation(in: context, repository: controller.repository)
            case nil:
                await controller.commit()
            }
        }

        // Always asks: one file too, and with the confirmation setting off.
        actions.register(.discardAllChanges) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            let files = repository.changes.workingDirectory.files
            await context.presenter.perform { answers throws(OperationError) in
                try await repository.changes.discardAllChanges(files, confirmed: answers.confirmed)
            }
        }

        // The composer is with the uncommitted changes: All Work ends.
        actions.register(.goToCommitMessage) { [weak context] _ in
            context?.select(.changes)
            context?.repository?.allWork.choose(.uncommitted)
            context?.state.requestCommitMessageFocus()
        }

        actions.register(.toggleAmendLastCommit, isEnabled: { [weak context] _ in
            guard let context, let repository = context.repository else {
                return false
            }
            return repository.commit.canStartAmending
                && repository.localOperation?.kind != .commit
                && repository.ai.commitMessageGeneration != .generating
        }, isChecked: { [weak context] _ in
            context?.repository?.commit.amending != nil
        }) { [weak context] _ in
            guard let context, let controller = controller(context) else {
                return
            }
            // The amend banner is the composer's: All Work ends.
            controller.repository.allWork.choose(.uncommitted)
            await controller.toggleAmend()
        }

        actions.register(.generateCommitMessage, isEnabled: { [weak context] _ in
            guard let context, let repository = context.repository else {
                return false
            }
            let content = ComposerContent.make(repository, app: context.app)
            return content.sparkle.isEnabled && content.sparkle != .generating
                && OperationCapsuleContent.make(repository) == nil
        }, isHidden: { [weak context] _ in
            // With AI turned off, the item and ⌥⌘G are gone.
            !(context?.app.preferences.aiFeaturesEnabled ?? true)
        }) { [weak context] _ in
            guard let context, let controller = controller(context) else {
                return
            }
            // The sparkle's popovers anchor in the composer, which is with
            // the uncommitted changes.
            context.select(.changes)
            controller.repository.allWork.choose(.uncommitted)
            await controller.generate()
        }

        actions.register(.undoCommit, isEnabled: { [weak context] _ in
            guard let context, let controller = controller(context) else {
                return false
            }
            return controller.canUndo
        }) { [weak context] _ in
            guard let context, let controller = controller(context) else {
                return
            }
            await controller.undo()
        }

        // Changes with everything on the branch, from any place; "Hide All
        // Work" while it shows, which goes back to the uncommitted changes.
        actions.register(.toggleAllWork, isEnabled: { [weak context] _ in
            context?.repository?.allWork.isAvailable == true
        }, title: { [weak context] _ in
            guard let context, isShowingAllWork(context) else {
                return nil
            }
            return "Hide All Work"
        }) { [weak context] _ in
            guard let context, let allWork = context.repository?.allWork else {
                return
            }
            if isShowingAllWork(context) {
                allWork.choose(.uncommitted)
            } else {
                context.select(.changes)
                allWork.choose(.allWork)
            }
        }

        // All Work's selected file: viewed, then on to the next not viewed;
        // or no longer viewed.
        actions.register(.markViewed, isEnabled: { [weak context] _ in
            guard let context, context.state.place == .changes, let allWork = context.repository?.allWork else {
                return false
            }
            return allWork.scope == .allWork && allWork.selectedFile != nil
        }, title: { [weak context] _ in
            guard let allWork = context?.repository?.allWork, allWork.scope == .allWork,
                  let file = allWork.selectedFile, allWork.isViewed(file)
            else {
                return nil
            }
            return "Mark Not Viewed"
        }) { [weak context] _ in
            context?.repository?.allWork.toggleSelectedViewed()
        }

        Benchmarks.runners[.changesApply] = { context in
            ChangesApplyBenchmark.run(numberFormat: context.app.preferences.numberFormat)
        }
    }

    /// Whether the window shows Changes in its All Work scope.
    private static func isShowingAllWork(_ context: WindowContext) -> Bool {
        !context.isOnHome && context.state.place == .changes && context.repository?.allWork.scope == .allWork
    }

    /// The composer's controller for the window's repository.
    private static func controller(_ context: WindowContext) -> ComposerController? {
        context.repository.map { ComposerController(context: context, repository: $0) }
    }
}
