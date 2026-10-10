// The sparkle's states, its setup popover and the consent sheet, and the
// author's popover.

import AIKit
import AppKit
@testable import EspalierCore
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Sparkle and author") @MainActor
struct SparkleTests {
    @Test("the consent sheet renders")
    func consentSnapshot() {
        let provider = BYOKProvider(
            id: "p",
            name: "OpenAI",
            type: .openai,
            baseUrl: "https://api.openai.com/v1",
            authKind: .apiKey,
            models: [BYOKModel(id: "gpt-5", name: "GPT-5")]
        )
        let content = AIConsentContent(getAIDataDisclosure(for: .commitMessageGeneration, provider: provider))
        assertSnapshot(ConsentSheet(content), named: "consent-sheet", area: "Changes", appearances: [.light])
    }

    @Test("sparkle snapshots: every state, and the setup popover")
    func snapshots() {
        let states: [SparkleState] = [
            .ready(model: "GPT-5"), .noFiles(model: "GPT-5"), .noProvider, .chooseModel, .generating, .generated(model: "GPT-5"), .unavailable(model: "GPT-5"),
        ]
        let row = HStack(spacing: Metrics.insetMedium) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                SparkleButton(state)
            }
        }
        .padding(Metrics.insetSmall)
        assertSnapshot(row, named: "sparkle-states", area: "Changes")
        assertSnapshot(AISetupPopover(), named: "ai-setup-popover", area: "Changes", appearances: [.light])
    }

    @Test("the author's popover: who commits, and why it may be misattributed")
    func author() {
        #expect(AuthorIdentityContent(name: "Joe Bloggs", email: "joe@example.com").title == "Committing as Joe Bloggs")
        #expect(AuthorIdentityContent(name: "", email: "joe@example.com").title == "Committing with joe@example.com")
        #expect(AuthorIdentityContent(name: nil, email: nil).title == "No Author Set")
        #expect(AuthorIdentityContent(name: "Joe", email: "j@x", warning: .misattributed(isEnterprise: true)).warningText
            == "This email address doesn't match your GitHub Enterprise account. Your commits won't be attributed to you.")
        #expect(AuthorIdentityContent(name: "Joe", email: "j@x", warning: .disallowedEmail(ruleCount: 2, canBypass: true)).warningText
            == "This email address fails 2 rules for commits on this branch, but you can bypass them.")
        #expect(AuthorIdentityContent(name: "Joe", email: "j@x", endpoint: "https://api.github.com").avatarUser?.endpoint == "https://api.github.com")

        // The popover with a warning and the account's addresses to use.
        let misattributed = AuthorIdentityContent(
            name: "Joe Bloggs",
            email: "joe@work.example.com",
            warning: .misattributed(isEnterprise: false),
            accountEmails: ["joe@example.com", "1234+joe@users.noreply.github.com"],
            preferredAccountEmail: "joe@example.com"
        )
        assertSnapshot(AuthorIdentityPopover(misattributed, canOpenRepositorySettings: true), named: "author-misattributed", area: "Changes", appearances: [.light])
    }
}
