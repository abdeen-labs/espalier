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
        presenter.respond(to: pending.id, with: .moveToNewBranch)
        #expect(await task.value == "done")
        #expect(intent.calls.last?.strategy == .moveToNewBranch)
    }

    @Test("a busy repository shows a toast; a cancellation shows nothing")
    func busyAndCancelled() async {
        let presenter = WindowPresenter()
        let busy = ScriptedIntent([OperationError(.busy(.commit), operation: .checkoutBranch)])
        #expect(await presenter.perform { answers throws(OperationError) in try busy.run(answers) } == nil)
        #expect(presenter.toasts.map(\.message) == ["Another operation is in progress"])
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
        #expect(presenter.toasts.map(\.message) == ["Merged feature into main"])
        presenter.dismissToast(presenter.toasts[0].id)
        #expect(presenter.toasts.isEmpty)
    }

    @Test("a toast's Undo runs from Edit ▸ Undo while it shows, once; a closed toast's, or one taken back, doesn't")
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
        #expect(TimedToast(toast: squashed, presenter: presenter).content.undoShortcut == "⌘Z")
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(presenter.toasts.isEmpty)
        await waitUntil { !runs.names.isEmpty }
        #expect(runs.names == ["squash"])
        #expect(!undoManager.canUndo)

        // A toast that closed, or whose Undo was taken back, runs nothing.
        let reordered = Toast("Successfully reordered 2 commits.", undo: ToastAction { runs.names.append("reorder") })
        show(reordered)
        presenter.dismissToast(reordered.id)
        let copied = Toast("Successfully copied 1 commit to main.", undo: ToastAction { runs.names.append("cherry-pick") })
        show(copied)
        presenter.replaceToast(Toast(id: copied.id, copied.message))
        for _ in 0..<5 where undoManager.canUndo {
            undoManager.undo()
        }
        // A toast without Undo registers nothing: undoing runs nothing.
        show(Toast("Successfully merged feature into main"))
        for _ in 0..<5 where undoManager.canUndo {
            undoManager.undo()
        }
        for _ in 0..<5 {
            await Task.yield()
        }
        #expect(runs.names == ["squash"])
        #expect(presenter.toasts.map(\.message) == ["Successfully copied 1 commit to main.", "Successfully merged feature into main"])
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

    @Test("Do not show this message again turns the confirmation's setting off", .offline)
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
            switch confirmation.presentation {
            case .alert(let content):
                #expect(![.removeRepository, .deleteBranch].contains(confirmation.kind), "\(name)")
                #expect(content.buttons.first?.title == confirmation.confirmButton)
                #expect(content.buttons.last == AlertContent.Button("Cancel", role: .cancel))
                #expect((content.suppressionTitle != nil) == (confirmation.suppressionSetting != nil), "\(name)")
            case .compactSheet(let compact):
                #expect([.removeRepository, .deleteBranch].contains(confirmation.kind), "\(name)")
                #expect(compact.confirmButton == confirmation.confirmButton)
            }
        }
        // The discard list is shown up to ten files.
        guard case .alert(let few) = EspalierCore.Confirmation.discardChanges(UIFixtures.files).presentation,
              case .alert(let many) = EspalierCore.Confirmation.discardChanges(UIFixtures.manyFiles).presentation else {
            Issue.record("discards aren't alerts")
            return
        }
        #expect(few.message.contains("• README.md"))
        #expect(!many.message.contains("•"))
        #expect(few.severity == .critical)
        // The delete sheet offers the remote only when the branch is there.
        guard case .compactSheet(let local) = EspalierCore.Confirmation.deleteBranch("x", existsOnRemote: false).presentation,
              case .compactSheet(let remote) = EspalierCore.Confirmation.deleteBranch("x", existsOnRemote: true).presentation else {
            Issue.record("deleting a branch isn't a compact sheet")
            return
        }
        #expect(local.optionTitle == nil)
        #expect(remote.optionTitle == "Delete it on the remote too")
    }

    @Test("errors map to their presentations and recoveries")
    func errorPresentation() throws {
        for (name, error) in UIFixtures.errors {
            switch (name, error.presentation) {
            case ("git-raw", .rawOutput(let content, _)), ("clone", .rawOutput(let content, _)):
                #expect(!content.output.isEmpty)
                if name == "clone" {
                    #expect(content.note == "Would you like to retry cloning joe/missing?")
                    #expect(content.recoveryTitles == ["Retry Clone"])
                    #expect(content.dismissTitle == "Cancel")
                }
            case ("signing-pinentry", .rawOutput(let content, _)), ("signing-ssh-agent", .rawOutput(let content, _)):
                // Why signing failed comes before git's output.
                #expect(content.message == error.signingFailureExplanation, "\(name)")
                #expect(content.message?.isEmpty == false, "\(name)")
                #expect(content.title == (name == "signing-pinentry" ? "Commit Failed" : "Signing Failed"), "\(name)")
                #expect(content.output == error.gitFailure?.message, "\(name)")
            case ("pushProtectionBlocked", .pushProtection), ("insufficientPermissions", .createFork):
                break
            case (_, .alert(let content, let recoveries)):
                #expect(content.buttons.count == recoveries.count + 1, "\(name)")
                #expect(content.buttons.prefix(recoveries.count).map(\.title) == recoveries.map(\.title), "\(name)")
            default:
                Issue.record("\(name) has an unexpected presentation")
            }
        }
        let byName = Dictionary(uniqueKeysWithValues: UIFixtures.errors.map { ($0.name, $0.error) })
        guard case .alert(let pushRejected, _) = byName["pushRejectedNonFastForward"]!.presentation,
              case .alert(let lfs, _) = byName["lfsAttributeMismatch"]!.presentation,
              case .alert(let overwritten, _) = byName["localChangesOverwritten"]!.presentation,
              case .alert(let overwrittenWithStash, _) = byName["localChangesOverwritten-stash"]!.presentation,
              case .alert(let commit, _) = byName["git-commit"]!.presentation else {
            Issue.record("errors aren't alerts")
            return
        }
        #expect(pushRejected.title == "Newer Commits on Remote")
        #expect(pushRejected.buttons.map(\.title) == ["Fetch", "Cancel"])
        #expect(lfs.buttons.map(\.title) == ["Update Existing Filters", "Edit Global Git Config…", "Not Now"])
        #expect(overwritten.buttons.map(\.title) == ["Stash Changes and Continue", "Close"])
        #expect(overwritten.message.hasSuffix("You can stash your changes now and restore them afterward."))
        #expect(!overwrittenWithStash.message.contains("You can stash"))
        #expect(commit.title == "Commit Failed")
        // Only the Trash failure offers "Do not show this message again".
        for (name, error) in UIFixtures.errors {
            guard case .alert(let content, _) = error.presentation else {
                continue
            }
            #expect((content.suppressionTitle != nil) == (name == "trashFailed"), "\(name)")
        }
        for silent in [OperationError(.missingRepository, operation: .fetch), OperationError(.cancelled(.userCancelled), operation: .clone)] {
            guard case .none = silent.presentation else {
                Issue.record("\(silent.reason) shows something")
                continue
            }
        }
    }
}

@Suite("Error alerts") @MainActor
struct ErrorAlertTests {
    @Test("the Trash failure's \"Do not show this message again\" turns off the permanent discard confirmation when the user goes ahead, never on Cancel")
    func trashFailureSuppression() throws {
        let harness = try AppHarness()
        let preferences = harness.makeApp().preferences
        let error = try #require(UIFixtures.errors.first { $0.name == "trashFailed" }?.error)
        guard case .alert(let content, let recoveries) = error.presentation else {
            Issue.record("The Trash failure isn't an alert")
            return
        }
        #expect(content.suppressionTitle == "Do not show this message again")
        #expect(content.buttons.map(\.title) == ["Permanently Discard Changes", "Cancel"])
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
        #expect(unticked?.title == "Permanently Discard Changes")
        #expect(preferences.confirmDiscardChangesPermanently)

        // Going ahead with it: the setting turns off.
        let ticked = ErrorHost.respond(AlertResponse(buttonIndex: 0, isSuppressed: true), to: error, recoveries: recoveries, preferences: preferences)
        #expect(ticked?.title == "Permanently Discard Changes")
        #expect(!preferences.confirmDiscardChangesPermanently)

        // Other errors' answers write nothing.
        preferences.confirmDiscardChangesPermanently = true
        let lfs = try #require(UIFixtures.errors.first { $0.name == "lfsAttributeMismatch" }?.error)
        _ = ErrorHost.respond(AlertResponse(buttonIndex: 0, isSuppressed: true), to: lfs, recoveries: lfs.recoveries, preferences: preferences)
        #expect(preferences.confirmDiscardChangesPermanently)
    }
}
