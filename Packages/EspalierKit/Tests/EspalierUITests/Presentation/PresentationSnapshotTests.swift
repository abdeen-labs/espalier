// One image per layout of the confirmations, decisions, prompts, and errors
// that Espalier draws as sheets, the toast, and the operation capsule,
// through the same mappings the hosts use. The alert card's layouts are
// ModalSnapshotTests'; WindowPresenterTests, PromptPresentationTests,
// StateNoticesTests, and the features' content tests check each alert's
// words. Dark only where the view draws its own colors.

import AppKit
import EspalierCore
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Presentation snapshots") @MainActor
struct PresentationSnapshotTests {
    /// The compact sheets: with and without the extra choice.
    nonisolated static let confirmations: [String: [SnapshotAppearance]] = [
        "removeRepository": SnapshotAppearance.allCases,
        "deleteBranch-remote": [.light],
    ]

    @Test("the compact confirmation sheets render", arguments: PresentationSnapshotTests.confirmations.keys.sorted())
    func confirmation(name: String) throws {
        let confirmation = try #require(UIFixtures.confirmations.first { $0.name == name }?.confirmation)
        let appearances = try #require(Self.confirmations[name])
        guard case .compactSheet(let compact) = confirmation.presentation else {
            Issue.record("\(name) is an alert, not a sheet")
            return
        }
        assertSnapshot(CompactConfirmationSheet(compact) { _ in }, named: name, area: "Confirmations", appearances: appearances)
    }

    @Test("the decision sheet renders, with the stash warning")
    func decision() throws {
        let name = "uncommittedChanges-stash"
        let decision = try #require(UIFixtures.decisions.first { $0.name == name }?.decision)
        assertSnapshot(DecisionSheet(decision) { _ in }, named: name, area: "Decisions", appearances: [.light])
    }

    /// One prompt sheet per layout: a secret, a username and password, and
    /// a failed hook's output.
    @Test("the prompt sheets render", arguments: ["sshKeyPassphrase", "genericGitAuthentication", "hookFailed"])
    func prompt(name: String) throws {
        let prompt = try #require(UIFixtures.prompts.first { $0.name == name }?.prompt)
        guard case .sheet(let sheet) = PromptPresentation.make(prompt, finish: { _ in }) else {
            Issue.record("\(name) is an alert, not a sheet")
            return
        }
        assertSnapshot(sheet.view, named: name, area: "Prompts", appearances: [.light])
    }

    /// Git's raw output with a note and a recovery, and the explanation
    /// above it: one line, and a few, each in a box as tall as it is.
    @Test("the raw output sheets render", arguments: ["clone", "signing-pinentry"])
    func error(name: String) throws {
        let error = try #require(UIFixtures.errors.first { $0.name == name }?.error)
        guard case .rawOutput(let content, _) = error.presentation else {
            Issue.record("\(name) isn't raw output")
            return
        }
        assertSnapshot(RawOutputSheet(content), named: name, area: "Errors", appearances: [.light])
    }

    @Test("output longer than the terminal height scrolls, scrolled to its end")
    func longOutput() {
        let output = (1...40).map { "remote: Counting objects: \($0)% (\($0)/40)" }.joined(separator: "\n")
        assertSnapshot(
            TerminalOutputView(output).frame(width: Metrics.Sheet.terminalWidth - 2 * Metrics.Sheet.padding).padding(Metrics.insetLarge),
            named: "terminal-long",
            area: "Errors",
            appearances: [.light]
        )
    }

    /// With Undo and its key, and without: the close button either way.
    @Test("the toast renders, with its close button", arguments: ["cherryPick-undo", "merged"])
    func toast(name: String) throws {
        let content = try #require(UIFixtures.toasts.first { $0.name == name }?.content)
        assertSnapshot(ToastView(content).padding(Metrics.insetLarge), named: name, area: "Toasts", appearances: name == "merged" ? [.light] : SnapshotAppearance.allCases)
    }

    /// Running, with its progress; waiting on the user, with its button.
    nonisolated static let capsules: [String: [SnapshotAppearance]] = [
        "rebase-running": SnapshotAppearance.allCases,
        "rebase-conflicted": [.light],
    ]

    @Test("the operation capsule renders", arguments: PresentationSnapshotTests.capsules.keys.sorted())
    func capsule(name: String) throws {
        let content = try #require(UIFixtures.capsules.first { $0.name == name }?.content)
        let appearances = try #require(Self.capsules[name])
        assertSnapshot(OperationCapsule(content).padding(Metrics.insetLarge), named: name, area: "Capsule", appearances: appearances)
    }

    @Test("the background failure's details render")
    func backgroundFailure() {
        let summary = BackgroundFailureSummary(
            title: "Error",
            message: "Authentication failed. Some common reasons:\n\n- You're not signed in to your account. Sign in from Espalier ▸ Settings ▸ Accounts.",
            recoveryTitles: ["Open Settings"]
        )
        assertSnapshot(BackgroundFailureDetails(summary), named: "details", area: "SyncButton", appearances: [.light])
    }
}
