// Committing with AI in the composer, one capture each: Assisted ready to
// commit, no provider set up, planning (with Cancel), making the second of
// three commits with a hook running, a failure, an undo that needs
// retrying, and a push that failed after the commits.

import AppKit
import EspalierCore
import Foundation
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Changes assisted commits", .captures) @MainActor
struct ChangesAssistedCommitCaptures {
    private let area = "Changes"
    private let values = ComposerCaptureValues.self

    /// The composer in Assisted with `status`.
    private func assisted(
        _ status: AssistedCommitContent.Status,
        button: CommitButtonContent,
        hook: HookActivityContent? = nil,
        pushes: Bool = false
    ) -> ComposerContent {
        let isRunning = if case .running = status { true } else { false }
        return ComposerContent(
            author: values.author,
            sparkle: isRunning ? .unavailable(model: "GPT-5") : .ready(model: "GPT-5"),
            showsCoAuthorsToggle: true,
            isCoAuthorsToggleEnabled: !isRunning,
            options: CommitOptionsContent(isEnabled: !isRunning, isAssisted: true, pushesAfterCommitting: pushes),
            hook: hook,
            button: button,
            isReadOnly: isRunning,
            mode: .assisted,
            showsModeSwitch: true,
            isModeSwitchEnabled: !isRunning,
            assisted: AssistedCommitContent(status: status)
        )
    }

    private func button(enabled: Bool = true, committing: Bool = false, reason: String? = nil) -> CommitButtonContent {
        CommitButtonContent(isAssisted: true, fileCount: 3, branch: "main", isCommitting: committing, isEnabled: enabled, disabledReason: reason)
    }

    @Test("Manual with the switch")
    func manual() {
        let content = ComposerContent(
            author: values.author,
            sparkle: .ready(model: "GPT-5"),
            button: values.button(enabled: false),
            mode: .manual,
            showsModeSwitch: true
        )
        capture(values.composer(content), named: "composer-manual-switch", area: area)
    }

    @Test("Assisted, ready, and without a provider")
    func ready() {
        capture(values.composer(assisted(.ready(model: "GPT-5"), button: button(), pushes: true)), named: "composer-assisted-ready", area: area)
        capture(
            values.composer(assisted(.needsProvider, button: button(enabled: false, reason: "Set up a model in Settings ▸ AI to commit with AI"))),
            named: "composer-assisted-needs-provider",
            area: area
        )
    }

    @Test("Assisted, planning and committing")
    func running() {
        capture(
            values.composer(assisted(.running(.planning(changes: 7), canCancel: true), button: button(enabled: false, committing: true))),
            named: "composer-assisted-planning",
            area: area
        )
        capture(
            values.composer(assisted(
                .running(.committing(index: 1, total: 3, title: "Add the sign-in screen's tests"), canCancel: true),
                button: button(enabled: false, committing: true),
                hook: HookActivityContent(hookName: "pre-commit", status: .running)
            )),
            named: "composer-assisted-committing",
            area: area
        )
    }

    @Test("Assisted, after a failure")
    func failures() {
        capture(
            values.composer(assisted(
                .failed(message: "The model's plan leaves out some of the selected changes.", recovery: .dismiss),
                button: button()
            )),
            named: "composer-assisted-failed",
            area: area
        )
        capture(
            values.composer(assisted(
                .failed(message: "Something else changed the index, so the assisted commit left it as it is.", recovery: .retryUndo),
                button: button(enabled: false, reason: "Retry undoing the last assisted commit first.")
            )),
            named: "composer-assisted-undo-needed",
            area: area
        )
        capture(
            values.composer(assisted(
                .failed(message: "The remote has commits you don't have yet. Pull, then push again.", recovery: .retryPush),
                button: button(),
                pushes: true
            )),
            named: "composer-assisted-push-failed",
            area: area
        )
    }
}
