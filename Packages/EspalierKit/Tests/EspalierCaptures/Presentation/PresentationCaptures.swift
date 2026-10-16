// What Espalier draws as sheets, through the same mappings the hosts use:
// the compact confirmations (with and without the extra choice), the
// decision with the stash warning, the editor question, the prompts (a secret, a username and
// password, a failed hook's output), git's raw output (one line and a few,
// with a note and a recovery) and output longer than the terminal, the
// toast with Undo and without, the operation capsule running and waiting on
// the user, and a background failure's details.

import AppKit
import EspalierCore
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Presentation", .captures) @MainActor
struct PresentationCaptures {
    @Test("the compact confirmation sheets", arguments: ["removeRepository", "deleteBranch-remote"])
    func confirmation(name: String) throws {
        let confirmation = try #require(UIFixtures.confirmations.first { $0.name == name }?.confirmation)
        guard case .compactSheet(let compact) = confirmation.presentation(Capture.numberFormat) else {
            Issue.record("\(name) is an alert, not a sheet")
            return
        }
        capture(CompactConfirmationSheet(compact) { _ in }, named: name, area: "Confirmations")
    }

    @Test("the decision sheet, with the stash warning")
    func decision() throws {
        let name = "uncommittedChanges-stash"
        let decision = try #require(UIFixtures.decisions.first { $0.name == name }?.decision)
        capture(DecisionSheet(decision) { _ in }, named: name, area: "Decisions")
    }

    @Test("the editor question, before and after one is picked")
    func editorDecision() throws {
        let decision = try #require(UIFixtures.decisions.first { $0.name == "externalEditor" }?.decision)
        guard case .externalEditor(let editors) = decision else {
            Issue.record("Not the editor decision")
            return
        }
        capture(EditorDecisionSheet(decision, editors: editors) { _ in }, named: "externalEditor", area: "Decisions")
        capture(EditorDecisionSheet(decision, editors: editors, selection: "Zed") { _ in }, named: "externalEditor-chosen", area: "Decisions")
    }

    @Test(
        "the prompt sheets: a secret, one it can't remember, a username and password, a failed hook's output",
        arguments: ["sshKeyPassphrase", "sshKeyPassphrase-unidentified", "genericGitAuthentication", "hookFailed"]
    )
    func prompt(name: String) throws {
        let prompt = try #require(UIFixtures.prompts.first { $0.name == name }?.prompt)
        guard case .sheet(let sheet) = PromptPresentation.make(prompt, finish: { _ in }) else {
            Issue.record("\(name) is an alert, not a sheet")
            return
        }
        capture(sheet.view, named: name, area: "Prompts")
    }

    @Test("git's raw output with a note and a recovery, below one line and below a few", arguments: ["clone", "signing-pinentry"])
    func rawOutput(name: String) throws {
        let error = try #require(UIFixtures.errors.first { $0.name == name }?.error)
        guard case .rawOutput(let content, _) = error.presentation(Capture.numberFormat) else {
            Issue.record("\(name) isn't raw output")
            return
        }
        capture(RawOutputSheet(content), named: name, area: "Errors")
    }

    @Test("output longer than the terminal scrolls, scrolled to its end")
    func longOutput() {
        let output = (1...40).map { "remote: Counting objects: \($0)% (\($0)/40)" }.joined(separator: "\n")
        capture(
            TerminalOutputView(output)
                .frame(width: Metrics.Sheet.terminalWidth - 2 * Metrics.Sheet.padding)
                .padding(Metrics.insetLarge),
            named: "terminal-long",
            area: "Errors"
        )
    }

    @Test("the toast, with Undo and its key, and without", arguments: ["cherryPick-undo", "merged", "reset"])
    func toast(name: String) throws {
        let content = try #require(UIFixtures.toasts.first { $0.name == name }?.content)
        capture(ToastView(content).padding(Metrics.insetLarge), named: name, area: "Toasts")
    }

    @Test("the operation capsule: running with its progress, and waiting on the user", arguments: ["rebase-running", "rebase-conflicted"])
    func capsule(name: String) throws {
        let content = try #require(UIFixtures.capsules.first { $0.name == name }?.content)
        capture(OperationCapsule(content).padding(Metrics.insetLarge), named: name, area: "Capsule")
    }

    @Test("a background failure's details")
    func backgroundFailure() {
        let summary = BackgroundFailureSummary(
            title: "Error",
            message: "Authentication failed. Some common reasons:\n\n- You're not signed in to your account. Sign in from Espalier ▸ Settings ▸ Accounts.",
            recoveryTitles: ["Open Settings"]
        )
        capture(BackgroundFailureDetails(summary), named: "details", area: "SyncButton")
    }
}
