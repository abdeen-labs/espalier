// The window presenter's loop: confirmations and decisions are asked and
// answered, the intent called again with the answers; cancellations show
// nothing, busy repositories a toast, other errors an error; the
// suppression toggle writes its setting.

import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Observation
import Testing
import TestSupport
@testable import EspalierUI

/// Records an intent's calls and throws the errors given, in order.
@MainActor
private final class ScriptedIntent {
    var errors: [OperationError]
    private(set) var calls: [IntentAnswers] = []

    init(_ errors: [OperationError]) {
        self.errors = errors
    }

    func run(_ answers: IntentAnswers) throws(OperationError) -> String {
        calls.append(answers)
        if !errors.isEmpty {
            throw errors.removeFirst()
        }
        return "done"
    }
}

private func required(_ confirmation: EspalierCore.Confirmation) -> OperationError {
    OperationError(.confirmationRequired(confirmation), operation: .push)
}

/// The toast actions that ran, in order.
@MainActor @Observable
private final class UndoRuns {
    var names: [String] = []
}

/// Whether a lasting Undo is still valid.
@MainActor @Observable
private final class UndoValidity {
    var isValid = true
}

@Suite("Window presenter", .hangGuard(minutes: 5)) @MainActor
struct WindowPresenterTests {
    /// Waits until the presenter shows a confirmation, yielding to the task
    /// that asks.
    private func confirmation(of presenter: WindowPresenter) async -> PendingConfirmation {
        await waitUntil { presenter.confirmation != nil }
        return presenter.confirmation!
    }

    private func decision(of presenter: WindowPresenter) async -> PendingDecision {
        await waitUntil { presenter.decision != nil }
        return presenter.decision!
    }

    @Test("a confirmation is asked, then the intent runs again with it")
    func confirms() async {
        let presenter = WindowPresenter()
        let intent = ScriptedIntent([required(.forcePush(upstreamBranch: "origin/main"))])
        let task = Task { await presenter.perform { answers throws(OperationError) in try intent.run(answers) } }

        let pending = await confirmation(of: presenter)
        #expect(pending.confirmation.kind == .forcePush)
        presenter.respond(to: pending.id, with: ConfirmationResponse(isConfirmed: true))

        #expect(await task.value == "done")
        #expect(intent.calls.map(\.confirmed) == [[], [.forcePush]])
        #expect(presenter.confirmation == nil)
        #expect(presenter.error == nil)
    }

    @Test("chained confirmations are asked in turn")
    func chained() async {
        let presenter = WindowPresenter()
        let intent = ScriptedIntent([
            required(.commitWithUnknownCoAuthors(["octocat"])),
            required(.commitConflictMarkers(["a.txt"])),
        ])
        let task = Task { await presenter.perform { answers throws(OperationError) in try intent.run(answers) } }
        presenter.respond(to: await confirmation(of: presenter).id, with: ConfirmationResponse(isConfirmed: true))
        let second = await confirmation(of: presenter)
        #expect(second.confirmation.kind == .commitConflictMarkers)
        presenter.respond(to: second.id, with: ConfirmationResponse(isConfirmed: true))
        #expect(await task.value == "done")
        #expect(intent.calls.last?.confirmed == [.commitWithUnknownCoAuthors, .commitConflictMarkers])
    }

    @Test("cancelling a confirmation stops without an error")
    func cancels() async {
        let presenter = WindowPresenter()
        let intent = ScriptedIntent([required(.discardStash())])
        let task = Task { await presenter.perform { answers throws(OperationError) in try intent.run(answers) } }
        presenter.respond(to: await confirmation(of: presenter).id, with: .cancelled)
        #expect(await task.value == nil)
        #expect(intent.calls.count == 1)
        #expect(presenter.error == nil)
        #expect(presenter.toasts.isEmpty)
    }

    @Test("the compact sheets' checkboxes reach the intent")
    func options() async {
        let presenter = WindowPresenter()
        let intent = ScriptedIntent([required(.removeRepository(name: "espalier", path: "/p"))])
        let task = Task { await presenter.perform { answers throws(OperationError) in try intent.run(answers) } }
        presenter.respond(to: await confirmation(of: presenter).id, with: ConfirmationResponse(isConfirmed: true, isOptionSelected: true))
        #expect(await task.value == "done")
        #expect(intent.calls.last?.moveToTrash == true)
        #expect(intent.calls.last?.includeRemoteBranch == false)

        let delete = ScriptedIntent([required(.deleteBranch("feature", existsOnRemote: true))])
        let deleteTask = Task { await presenter.perform { answers throws(OperationError) in try delete.run(answers) } }
        presenter.respond(to: await confirmation(of: presenter).id, with: ConfirmationResponse(isConfirmed: true, isOptionSelected: true))
        #expect(await deleteTask.value == "done")
        #expect(delete.calls.last?.includeRemoteBranch == true)
    }

    @Test("a decision is asked, then the intent runs with the strategy")
    func decides() async {
        let presenter = WindowPresenter()
        let decision = Decision.uncommittedChanges(currentBranch: "main", targetBranch: "feature", currentBranchHasStash: false)
        let intent = ScriptedIntent([OperationError(.decisionRequired(decision), operation: .checkoutBranch)])
        let task = Task { await presenter.perform { answers throws(OperationError) in try intent.run(answers) } }
        let pending = await self.decision(of: presenter)
        #expect(pending.decision == decision)
        presenter.respond(to: pending.id, with: .strategy(.moveToNewBranch))
        #expect(await task.value == "done")
        #expect(intent.calls.last?.strategy == .moveToNewBranch)
    }

    @Test("the editor question's answer is saved as the editor, then the intent runs again; cancelling saves nothing")
    func choosesEditor() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let presenter = WindowPresenter(app: app)
        let decision = Decision.externalEditor(editors: ["Visual Studio Code", "Zed"])

        let cancelled = ScriptedIntent([OperationError(.decisionRequired(decision), operation: .openInEditor)])
        let cancelledTask = Task { await presenter.perform { answers throws(OperationError) in try cancelled.run(answers) } }
        presenter.respond(to: await self.decision(of: presenter).id, with: nil)
        #expect(await cancelledTask.value == nil)
        #expect(app.preferences.integrations.selectedExternalEditor == nil)

        let intent = ScriptedIntent([OperationError(.decisionRequired(decision), operation: .openInEditor)])
        let task = Task { await presenter.perform { answers throws(OperationError) in try intent.run(answers) } }
        let pending = await self.decision(of: presenter)
        #expect(pending.decision == decision)
        presenter.respond(to: pending.id, with: .editor("Zed"))
        #expect(await task.value == "done")
        #expect(intent.calls.count == 2)
        #expect(app.preferences.integrations.selectedExternalEditor == "Zed")
    }

    @Test("a busy repository shows a toast; a cancellation shows nothing")
    func busyAndCancelled() async {
        let presenter = WindowPresenter()
        let busy = ScriptedIntent([OperationError(.busy(.commit), operation: .checkoutBranch)])
        #expect(await presenter.perform { answers throws(OperationError) in try busy.run(answers) } == nil)
        #expect(presenter.toasts.count == 1)
        #expect(presenter.error == nil)

        let cancelled = ScriptedIntent([OperationError(.cancelled(.hookAborted("pre-commit")), operation: .commit)])
        #expect(await presenter.perform { answers throws(OperationError) in try cancelled.run(answers) } == nil)
        #expect(presenter.toasts.count == 1)
        #expect(presenter.error == nil)
    }

    @Test("other errors are shown, one at a time")
    func errors() async {
        let presenter = WindowPresenter()
        let first = OperationError(.precondition("The current branch has no commits yet."), operation: .createBranch)
        let second = OperationError(.other("Something went wrong."), operation: .fetch)
        #expect(await presenter.perform { answers throws(OperationError) in try ScriptedIntent([first]).run(answers) } == nil)
        #expect(await presenter.perform { answers throws(OperationError) in try ScriptedIntent([second]).run(answers) } == nil)
        #expect(presenter.error?.error == first)
        presenter.dismissError(presenter.error!.id)
        #expect(presenter.error?.error == second)

        // Missing and unsafe repositories show their view instead.
        presenter.dismissError(presenter.error!.id)
        presenter.present(OperationError(.missingRepository, operation: .fetch))
        #expect(presenter.error == nil)
    }

    @Test("asking again for a given confirmation is shown as an error, not looped on")
    func loopGuard() async {
        let presenter = WindowPresenter()
        let confirmation = EspalierCore.Confirmation.forcePush(upstreamBranch: "origin/main")
        let intent = ScriptedIntent([required(confirmation), required(confirmation)])
        let task = Task { await presenter.perform { answers throws(OperationError) in try intent.run(answers) } }
        presenter.respond(to: await self.confirmation(of: presenter).id, with: ConfirmationResponse(isConfirmed: true))
        #expect(await task.value == nil)
        #expect(intent.calls.count == 2)
        #expect(presenter.error != nil)
    }

    @Test("an outcome becomes a toast")
    func outcomes() async {
        let presenter = WindowPresenter()
        let result = await presenter.perform { _ throws(OperationError) in
            MergeOutcome.merged(ours: "main", theirs: "feature")
        } outcome: { outcome in
            outcome.summary.map { Toast($0) }
        }
        #expect(result == .merged(ours: "main", theirs: "feature"))
        #expect(presenter.toasts.count == 1)
        presenter.dismissToast(presenter.toasts[0].id)
        #expect(presenter.toasts.isEmpty)
    }

    @Test("a toast's Undo runs from Edit ▸ Undo while it shows, once; a closed toast's doesn't")
    func toastUndoByKey() async {
        let presenter = WindowPresenter()
        let toastWithoutKey = Toast("Squashed", undo: ToastAction {})
        presenter.show(toastWithoutKey)
        // Without the window's undo manager, the toast shows no key.
        #expect(!presenter.undoesToastsByKey)
        #expect(TimedToast(toast: toastWithoutKey, presenter: presenter).content.undoShortcut == nil)
        presenter.dismissToast(toastWithoutKey.id)

        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        presenter.undoManager = undoManager
        let runs = UndoRuns()
        /// Shows `toast` as one event would.
        func show(_ toast: Toast) {
            undoManager.beginUndoGrouping()
            presenter.show(toast)
            undoManager.endUndoGrouping()
        }

        let squashed = Toast("Successfully squashed 2 commits.", undo: ToastAction { runs.names.append("squash") })
        show(squashed)
        #expect(TimedToast(toast: squashed, presenter: presenter).content.undoShortcut != nil)
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(presenter.toasts.isEmpty)
        await waitUntil { !runs.names.isEmpty }
        #expect(runs.names == ["squash"])
        #expect(!undoManager.canUndo)

        // A toast that closed runs nothing.
        let reordered = Toast("Successfully reordered 2 commits.", undo: ToastAction { runs.names.append("reorder") })
        show(reordered)
        presenter.dismissToast(reordered.id)
        #expect(!undoManager.canUndo)
        // A toast without Undo registers nothing.
        let merged = Toast("Successfully merged feature into main")
        show(merged)
        #expect(presenter.undoRegistrations.isEmpty)
        #expect(runs.names == ["squash"])
        #expect(presenter.toasts.map(\.id) == [merged.id])
    }

    @Test("an Undo valid for longer stays in Edit ▸ Undo after its toast closes, named, until it's no longer valid; from either place it runs once")
    func lastingUndo() async throws {
        let presenter = WindowPresenter()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        presenter.undoManager = undoManager
        let runs = UndoRuns()
        let validity = UndoValidity()
        /// Shows a toast with an Undo valid while `validity` says so, as one
        /// event would.
        func showSquashed() -> Toast {
            let toast = Toast("Squashed 2 commits.", undo: ToastAction(actionName: "Squash", isValid: { validity.isValid }) {
                runs.names.append("squash")
            })
            undoManager.beginUndoGrouping()
            presenter.show(toast)
            undoManager.endUndoGrouping()
            return toast
        }
        /// Typing in a field, as one event would.
        func type() {
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: runs) { $0.names.append("typing") }
            undoManager.endUndoGrouping()
        }

        // The toast closed: Edit ▸ Undo still offers it, with its name, and
        // typing since is undone first, also after the validity is read
        // again (another toast came and went).
        let first = showSquashed()
        presenter.dismissToast(first.id)
        #expect(undoManager.canUndo)
        #expect(!undoManager.undoActionName.isEmpty)
        type()
        let other = Toast("Merged feature into main")
        presenter.show(other)
        presenter.dismissToast(other.id)
        undoManager.undo()
        #expect(runs.names == ["typing"])
        #expect(undoManager.canUndo)

        // No longer valid: Edit ▸ Undo no longer offers it.
        validity.isValid = false
        await waitUntil { presenter.undoRegistrations[first.id] == nil }
        #expect(!undoManager.canUndo)

        // While the toast shows, the toast loses its Undo too.
        validity.isValid = true
        let second = showSquashed()
        validity.isValid = false
        await waitUntil { presenter.toasts.first?.undo == nil }
        #expect(presenter.toasts.map(\.id) == [second.id])
        #expect(!undoManager.canUndo)
        presenter.dismissToast(second.id)

        // Edit ▸ Undo closes the toast; its button then runs nothing.
        validity.isValid = true
        let third = showSquashed()
        undoManager.undo()
        #expect(presenter.toasts.isEmpty)
        #expect(presenter.takeToastUndo(third.id) == nil)
        await waitUntil { runs.names.count == 2 }

        // The button takes it off Edit ▸ Undo.
        let fourth = showSquashed()
        let undo = try #require(presenter.takeToastUndo(fourth.id))
        #expect(!undoManager.canUndo)
        await undo.perform()

        // After the toast closed, Edit ▸ Undo runs it once.
        let fifth = showSquashed()
        presenter.dismissToast(fifth.id)
        undoManager.undo()
        await waitUntil { runs.names.count == 4 }
        #expect(!undoManager.canUndo)
        #expect(runs.names == ["typing", "squash", "squash", "squash"])
    }

    @Test("a cancelled task's confirmation answers cancelled")
    func taskCancellation() async {
        let presenter = WindowPresenter()
        let intent = ScriptedIntent([required(.discardStash())])
        let task = Task { await presenter.perform { answers throws(OperationError) in try intent.run(answers) } }
        _ = await confirmation(of: presenter)
        task.cancel()
        #expect(await task.value == nil)
        await waitUntil { presenter.confirmation == nil }
    }

    @Test("the confirmation's checkbox turns its setting off", .offline)
    func suppression() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let presenter = WindowPresenter(app: app)
        #expect(app.preferences.confirmForcePush)
        let intent = ScriptedIntent([required(.rewritePublishedCommits(operation: "Rebase"))])
        let task = Task { await presenter.perform { answers throws(OperationError) in try intent.run(answers) } }
        presenter.respond(to: await confirmation(of: presenter).id, with: ConfirmationResponse(isConfirmed: true, suppressesFutureConfirmations: true))
        #expect(await task.value == "done")
        #expect(!app.preferences.confirmForcePush)
    }

    @Test("ticking the toggle on a question that has none changes no setting", .offline)
    func noToggleNoSuppression() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let presenter = WindowPresenter(app: app)
        let intent = ScriptedIntent([required(.discardChanges(["README.md", "notes.txt"]))])
        let task = Task { await presenter.perform { answers throws(OperationError) in try intent.run(answers) } }
        presenter.respond(to: await confirmation(of: presenter).id, with: ConfirmationResponse(isConfirmed: true, suppressesFutureConfirmations: true))
        #expect(await task.value == "done")
        #expect(app.preferences.confirmDiscardChanges)
    }

    @Test("confirmations become alerts or compact sheets with the right roles")
    func confirmationPresentation() throws {
        for (name, confirmation) in UIFixtures.confirmations {
            switch confirmation.presentation(defaultNumberFormat) {
            case .alert(let content):
                #expect(![.removeRepository, .deleteBranch].contains(confirmation.kind), "\(name)")
                #expect(content.buttons.last?.role == .cancel, "\(name)")
                #expect((content.suppressionTitle != nil) == (confirmation.suppressionSetting != nil), "\(name)")
            case .compactSheet(let compact):
                #expect([.removeRepository, .deleteBranch].contains(confirmation.kind), "\(name)")
                #expect(compact.isDestructive, "\(name)")
            }
        }
        // Discarding changes is critical.
        let discard = EspalierCore.Confirmation.discardChanges(UIFixtures.files).alertContent(defaultNumberFormat)
        #expect(discard.severity == .critical)

        // An alert's checkbox counts only when confirmed.
        let stash = EspalierCore.Confirmation.discardStash()
        #expect(stash.response(to: AlertResponse(buttonIndex: 0, isSuppressed: true)) == ConfirmationResponse(isConfirmed: true, suppressesFutureConfirmations: true))
        #expect(stash.response(to: AlertResponse(buttonIndex: 1, isSuppressed: true)) == .cancelled)
    }

    @Test("Delete Branch and Remove Repository are compact sheets with their option as the checkbox")
    func compactSheets() throws {
        guard case .compactSheet(let local) = EspalierCore.Confirmation.deleteBranch("x", existsOnRemote: false).presentation(defaultNumberFormat),
              case .compactSheet(let remote) = EspalierCore.Confirmation.deleteBranch("x", existsOnRemote: true).presentation(defaultNumberFormat),
              case .compactSheet(let repository) = EspalierCore.Confirmation.removeRepository(name: "espalier", path: "/Users/joe/Developer/espalier").presentation(defaultNumberFormat) else {
            Issue.record("Delete Branch or Remove Repository isn't a compact sheet")
            return
        }
        // The remote is offered only when the branch is there.
        #expect(local.optionTitle == nil)
        #expect(remote.optionTitle != nil)
        // The folder that stays is shown on its own.
        #expect(repository.optionTitle != nil)
        #expect(repository.path == "/Users/joe/Developer/espalier")
    }

    @Test("errors map to their presentations and recoveries")
    func errorPresentation() throws {
        for (name, error) in UIFixtures.errors {
            switch (name, error.presentation(defaultNumberFormat)) {
            case ("git-raw", .rawOutput(let content, _)), ("clone", .rawOutput(let content, _)):
                #expect(!content.output.isEmpty)
            case ("signing-pinentry", .rawOutput(let content, _)), ("signing-ssh-agent", .rawOutput(let content, _)):
                // Why signing failed comes before git's output.
                #expect(content.message?.isEmpty == false, "\(name)")
                #expect(content.output == error.gitFailure?.message, "\(name)")
            case ("pushProtectionBlocked", .pushProtection), ("insufficientPermissions", .createFork):
                break
            case (_, .alert(let content, let recoveries)):
                #expect(content.buttons.count == recoveries.count + 1, "\(name)")
            default:
                Issue.record("\(name) has an unexpected presentation")
            }
        }
        let byName = Dictionary(uniqueKeysWithValues: UIFixtures.errors.map { ($0.name, $0.error) })
        guard case .alert(let pushRejected, _) = byName["pushRejectedNonFastForward"]!.presentation(defaultNumberFormat),
              case .alert(let lfs, _) = byName["lfsAttributeMismatch"]!.presentation(defaultNumberFormat),
              case .alert(let overwritten, _) = byName["localChangesOverwritten"]!.presentation(defaultNumberFormat) else {
            Issue.record("errors aren't alerts")
            return
        }
        #expect(pushRejected.buttons.map(\.role) == [.primary, .cancel])
        #expect(lfs.buttons.map(\.role) == [.primary, .secondary, .cancel])
        #expect(overwritten.buttons.map(\.role) == [.primary, .cancel])
        // Only the Trash failure offers the checkbox.
        for (name, error) in UIFixtures.errors {
            guard case .alert(let content, _) = error.presentation(defaultNumberFormat) else {
                continue
            }
            #expect((content.suppressionTitle != nil) == (name == "trashFailed"), "\(name)")
        }
        for silent in [OperationError(.missingRepository, operation: .fetch), OperationError(.cancelled(.userCancelled), operation: .clone)] {
            guard case .none = silent.presentation(defaultNumberFormat) else {
                Issue.record("\(silent.reason) shows something")
                continue
            }
        }
    }
}

@Suite("Error alerts") @MainActor
struct ErrorAlertTests {
    @Test("the Trash failure's checkbox turns off the permanent discard confirmation when the user goes ahead, never on Cancel")
    func trashFailureSuppression() throws {
        let harness = try AppHarness()
        let preferences = harness.makeApp().preferences
        let error = try #require(UIFixtures.errors.first { $0.name == "trashFailed" }?.error)
        guard case .alert(let content, let recoveries) = error.presentation(defaultNumberFormat) else {
            Issue.record("The Trash failure isn't an alert")
            return
        }
        #expect(content.suppressionTitle != nil)
        #expect(content.buttons.map(\.role) == [.primary, .cancel])
        #expect(error.suppressionSetting == \Preferences.confirmDiscardChangesPermanently)
        #expect(preferences.confirmDiscardChangesPermanently)

        // Cancel with the box ticked: nothing changes, nothing runs.
        let cancelled = ErrorHost.respond(
            AlertResponse(buttonIndex: content.cancelIndex, isSuppressed: true), to: error, recoveries: recoveries, preferences: preferences
        )
        #expect(cancelled == nil)
        #expect(preferences.confirmDiscardChangesPermanently)

        // Going ahead without it: the recovery runs, the setting stays.
        let unticked = ErrorHost.respond(AlertResponse(buttonIndex: 0), to: error, recoveries: recoveries, preferences: preferences)
        #expect(Self.isDiscardPermanently(unticked))
        #expect(preferences.confirmDiscardChangesPermanently)

        // Going ahead with it: the setting turns off.
        let ticked = ErrorHost.respond(AlertResponse(buttonIndex: 0, isSuppressed: true), to: error, recoveries: recoveries, preferences: preferences)
        #expect(Self.isDiscardPermanently(ticked))
        #expect(!preferences.confirmDiscardChangesPermanently)

        // Other errors' answers write nothing.
        preferences.confirmDiscardChangesPermanently = true
        let lfs = try #require(UIFixtures.errors.first { $0.name == "lfsAttributeMismatch" }?.error)
        _ = ErrorHost.respond(AlertResponse(buttonIndex: 0, isSuppressed: true), to: lfs, recoveries: lfs.recoveries, preferences: preferences)
        #expect(preferences.confirmDiscardChangesPermanently)
    }

    /// Whether `recovery` is Permanently Discard Changes.
    private static func isDiscardPermanently(_ recovery: Recovery?) -> Bool {
        if case .discardPermanently? = recovery {
            return true
        }
        return false
    }
}
