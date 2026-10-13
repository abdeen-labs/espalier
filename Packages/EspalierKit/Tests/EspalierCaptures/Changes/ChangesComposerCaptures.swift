// The composer's layouts, one capture each: idle, a long branch in the
// commit button at the narrowest column, a merge's message and Continue for
// a rebase, the summary's and the description's focus tint, the last
// commit, committing, a hook running and its output, a warning that stops
// the commit and one that can be bypassed, the model's failure, co-authors
// with the author's warning and message rules. Then the sparkle's states,
// its setup popover, the consent sheet, the author's popover, and the
// Suggestions shown when there are no changes.

import AIKit
import AppKit
import EspalierCore
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Changes composer", .captures) @MainActor
struct ChangesComposerCaptures {
    private let area = "Changes"
    private let values = ComposerCaptureValues.self

    @Test("idle")
    func idle() {
        let base = ComposerContent(author: values.author, sparkle: .ready(model: "GPT-5"), button: values.button(enabled: false))
        capture(values.composer(base), named: "composer-idle", area: area)
    }

    @Test("a long branch gives way in the middle, at the narrowest column")
    func longBranch() {
        let button = CommitButtonContent(fileCount: 12, branch: "feature/sign-in-with-device-flow-and-enterprise-servers", isEnabled: true)
        let view = CommitButton(button)
            .frame(width: Metrics.Column.changesFileList.min - 2 * Metrics.Composer.horizontalPadding)
            .padding(Metrics.Composer.horizontalPadding)
        capture(view, named: "commit-button-long-branch", area: area)
    }

    @Test("a merge's message with Commit Merge, and Continue for a rebase")
    func operations() {
        let merge = ComposerContent(
            author: values.author,
            showsCommitOptions: false,
            button: CommitButtonContent(kind: .merge, fileCount: 0, branch: nil, isEnabled: true)
        )
        capture(
            values.composer(merge, draft: CommitDraft(summary: "Merge branch 'feature/login'", description: "* feature/login:\n  Add the login screen")),
            named: "composer-merge",
            area: area
        )
        let rebase = OperationSlotContent(
            kind: .continueOperation,
            button: CommitButtonContent(
                kind: .continueOperation(name: "Rebase"),
                fileCount: 0,
                branch: nil,
                isEnabled: false,
                disabledReason: OperationPanelContent.continueDisabledHelp
            ),
            notesUntrackedFiles: true
        )
        capture(
            ContinueOperationView(content: rebase).frame(width: Metrics.Column.changesFileList.ideal),
            named: "composer-continue",
            area: area
        )
    }

    @Test("the tint behind the summary or the description while it has focus")
    func focus() throws {
        let base = ComposerContent(author: values.author, sparkle: .ready(model: "GPT-5"), button: values.button(enabled: false))
        let fields: [(name: String, find: (NSView) -> NSView?)] = [
            ("summary", { $0.captureDescendants(SummaryNSTextField.self).first }),
            ("description", { $0.captureDescendants(ComposerTextView.self).first }),
        ]
        for field in fields {
            capture(values.composer(base), named: "composer-\(field.name)-focused", area: area) { host in
                if let view = field.find(host) {
                    host.window?.makeFirstResponder(view)
                } else {
                    Issue.record("No \(field.name) field")
                }
            }
        }
    }

    @Test("the last commit, and committing")
    func commit() {
        var lastCommit = ComposerContent(author: values.author, sparkle: .ready(model: "GPT-5"), button: values.button(enabled: false))
        lastCommit.lastCommit = LastCommitContent(summary: "Fix crash on open", date: Date().addingTimeInterval(-2 * 60))
        capture(values.composer(lastCommit), named: "composer-last-commit", area: area)

        let committing = ComposerContent(
            author: values.author,
            sparkle: .unavailable(model: "GPT-5"),
            options: CommitOptionsContent(options: CommitOptions(skipHooks: true, signOff: true), isEnabled: false),
            button: CommitButtonContent(fileCount: 2, branch: "main", isCommitting: true, isEnabled: false, disabledReason: "Committing changes…"),
            isReadOnly: true
        )
        capture(values.composer(committing, draft: CommitDraft(summary: "Fix crash on open")), named: "composer-committing", area: area)
    }

    @Test("a hook running, and its output")
    func hooks() {
        let content = ComposerContent(
            author: values.author,
            sparkle: .unavailable(model: "GPT-5"),
            hook: HookActivityContent(hookName: "pre-commit", status: .running),
            button: CommitButtonContent(fileCount: 2, branch: "main", isCommitting: true, isEnabled: false),
            isReadOnly: true
        )
        capture(values.composer(content, draft: CommitDraft(summary: "Fix crash on open")), named: "composer-hook-running", area: area)
        capture(
            HookOutputView(text: "Running swiftlint…\nSources/App/RepositoryLoader.swift:12:5: error: Force Unwrapping Violation\nDone linting! Found 1 violation, 1 serious in 42 files.\n"),
            named: "hook-output",
            area: area
        )
    }

    @Test("a warning that stops the commit, and one that can be bypassed")
    func warnings() {
        let warnings: [(String, CommitWarning)] = [
            ("protected", CommitWarning(.branchProtected(branch: "main"))),
            ("rules-push-bypass", CommitWarning(.pushRestricted(branch: "main", canBypass: true), rulesURL: values.mainRulesets)),
        ]
        for (name, warning) in warnings {
            let content = ComposerContent(
                author: values.author,
                sparkle: .ready(model: "GPT-5"),
                showsCoAuthorsToggle: true,
                warning: warning,
                button: values.button(enabled: !warning.isError)
            )
            capture(values.composer(content, draft: CommitDraft(summary: "Fix crash on open")), named: "composer-warning-\(name)", area: area)
        }
    }

    @Test("the model's failure, co-authors, the author's warning, message rules")
    func ai() {
        let failed = ComposerContent(
            author: values.author,
            sparkle: .ready(model: "GPT-5"),
            aiFailure: AIFailureContent(message: "The model is overloaded. Try again later.", recovery: .tryAgain),
            button: values.button(enabled: false)
        )
        capture(values.composer(failed), named: "composer-ai-failed-try-again", area: area)

        let coAuthors = ComposerContent(
            author: AuthorIdentityContent(name: "Joe Bloggs", email: "joe@example.com", warning: .misattributed(isEnterprise: false)),
            messageRuleFailures: MessageRuleFailures(failed: [.init("must start with \"JIRA-\"")]),
            sparkle: .ready(model: "GPT-5"),
            showsCoAuthorsToggle: true,
            button: values.button(enabled: false)
        )
        let draft = CommitDraft(
            summary: "Fix crash on open",
            coAuthors: [
                .known(KnownAuthor(name: "Mona Lisa", email: "mona@example.com", username: "octocat")),
                .unknown(UnknownAuthor(username: "hubot", state: .error)),
            ],
            showCoAuthoredBy: true
        )
        capture(values.composer(coAuthors, draft: draft), named: "composer-co-authors", area: area)
    }

    // MARK: The sparkle, the consent sheet, and the author

    @Test("the sparkle's states, and its setup popover")
    func sparkle() {
        let states: [SparkleState] = [
            .ready(model: "GPT-5"), .noFiles(model: "GPT-5"), .noProvider, .chooseModel, .generating, .generated(model: "GPT-5"), .unavailable(model: "GPT-5"),
        ]
        let row = HStack(spacing: Metrics.insetMedium) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                SparkleButton(state)
            }
        }
        .padding(Metrics.insetSmall)
        capture(row, named: "sparkle-states", area: area)
        capture(AISetupPopover(), named: "ai-setup-popover", area: area)
    }

    @Test("the consent sheet")
    func consent() {
        let provider = BYOKProvider(
            id: "p",
            name: "OpenAI",
            type: .openai,
            baseUrl: "https://api.openai.com/v1",
            authKind: .apiKey,
            models: [BYOKModel(id: "gpt-5", name: "GPT-5")]
        )
        let content = AIConsentContent(getAIDataDisclosure(for: .commitMessageGeneration, provider: provider))
        capture(ConsentSheet(content), named: "consent-sheet", area: area)
    }

    @Test("the author's popover with a warning and the account's addresses to use")
    func author() {
        let misattributed = AuthorIdentityContent(
            name: "Joe Bloggs",
            email: "joe@work.example.com",
            warning: .misattributed(isEnterprise: false),
            accountEmails: ["joe@example.com", "1234+joe@users.noreply.github.com"],
            preferredAccountEmail: "joe@example.com"
        )
        capture(AuthorIdentityPopover(misattributed, canOpenRepositorySettings: true), named: "author-misattributed", area: area)
    }

    // MARK: Suggestions

    @Test("Suggestions: each primary card with the editor and GitHub, and none")
    func suggestions() {
        let primaries: [(String, SuggestionsContent.Primary?)] = [
            ("none", nil),
            ("stash", .viewStash),
            ("publish-repository", .publishRepository),
            ("publish-branch", .publishBranch(branch: "ui-audit", isGitHub: true)),
            ("pull", .pull(branch: "ui-audit", remote: "origin", behind: 3, isGitHub: true)),
            ("push", .push(remote: "origin", ahead: 2, tags: 0, isGitHub: true)),
            ("push-tags", .push(remote: "origin", ahead: 2, tags: 1, isGitHub: true)),
            ("preview-pull-request", .pullRequest(branch: "ui-audit", choice: .previewPullRequest)),
            ("create-pull-request", .pullRequest(branch: "ui-audit", choice: .createPullRequest)),
        ]
        for (name, primary) in primaries {
            let content = SuggestionsContent(primary: primary, editorTitle: name == "none" ? nil : "Open in Xcode", isGitHub: true)
            capture(NoChangesSuggestions(content), named: "suggestions-\(name)", area: area, size: CGSize(width: 640, height: 520))
        }
    }
}
