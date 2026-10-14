// The Changes place's menu actions: Commit Changes (⌘↩), Generate Commit
// Message (⌥⌘G, gone while AI is off), Go to Commit Message (⌘J), Amend Last
// Commit, Undo Commit…, and Discard All Changes…, plus the Debug menu's
// Changes Apply benchmark. Each runs what the composer's controls run,
// through the window's presenter.

import EspalierCore
import GitKit

/// Registers the Changes place's actions.
@MainActor
enum ChangesActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        actions.register(.commitChanges, isEnabled: { [weak context] _ in
            guard let context, let controller = controller(context) else {
                return false
            }
            // ⌘↩ commits from Changes, where the composer is, and not while
            // an operation runs or waits (the commit form then commits a
            // merge, or Continue takes its place).
            return context.state.place == .changes
                && OperationCapsuleContent.make(controller.repository) == nil
                && controller.canCommit
        }) { [weak context] _ in
            guard let context, let controller = controller(context) else {
                return
            }
            await controller.commit()
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

        actions.register(.goToCommitMessage) { [weak context] _ in
            context?.select(.changes)
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
            // The sparkle's popovers anchor in the composer.
            context.select(.changes)
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

        Benchmarks.runners[.changesApply] = { context in
            ChangesApplyBenchmark.run(numberFormat: context.app.preferences.numberFormat)
        }
    }

    /// The composer's controller for the window's repository.
    private static func controller(_ context: WindowContext) -> ComposerController? {
        context.repository.map { ComposerController(context: context, repository: $0) }
    }
}
