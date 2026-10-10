// How commit messages show their tokens (the tokenizer's own tests are
// EspalierCoreTests/Text/TextTokenParserTests.swift): emoji wherever a
// summary shows, and links in a commit's header and Commit Info.

import Foundation
import GitHubKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Rich text")
struct RichTextTests {
    private let repository = gitHubRepoFixture(owner: "octo", name: "app")

    /// The runs of `text`: each run's characters, link, and whether it's
    /// underlined.
    private func runs(_ text: AttributedString) -> [(text: String, link: URL?, underlined: Bool)] {
        text.runs.map { run in
            (String(text[run.range].characters), run.link, run.underlineStyle != nil)
        }
    }

    @Test("summaries show emoji for shortcodes; unknown and custom ones stay text")
    func emojified() {
        #expect(RichText.emojified(":bug: Fix the crash :tada:") == "\u{1F41B} Fix the crash \u{1F389}")
        #expect(RichText.emojified("Plain summary") == "Plain summary")
        #expect(RichText.emojified("Ship it :shipit: :not-an-emoji:") == "Ship it :shipit: :not-an-emoji:")
        #expect(RichText.emojified("Fix #12 for @octocat at https://example.com") == "Fix #12 for @octocat at https://example.com")
        #expect(RichText.emojified("") == "")
    }

    @Test("a GitHub repository's messages link issue references, mentions, and URLs, underlined per the setting")
    func gitHubLinks() {
        let text = RichText.attributed(
            "Fix #12 :tada: thanks @octocat, see https://github.com/octo/app/issues/7",
            gitHubRepository: repository,
            underlinesLinks: true
        )
        let parts = runs(text)
        #expect(parts.map(\.text) == ["Fix ", "#12", " \u{1F389} thanks ", "@octocat", ", see ", "#7"])
        #expect(parts[1].link == URL(string: "https://github.com/octo/app/issues/12"))
        #expect(parts[3].link == URL(string: "https://github.com/octocat"))
        #expect(parts[5].link == URL(string: "https://github.com/octo/app/issues/7"))
        #expect(parts.filter { $0.link != nil }.allSatisfy { $0.underlined })
        #expect(parts.filter { $0.link == nil }.allSatisfy { !$0.underlined })

        let plain = RichText.attributed("Fix #12", gitHubRepository: repository, underlinesLinks: false)
        #expect(runs(plain).map(\.underlined) == [false, false])
        #expect(runs(plain).last?.link != nil)
    }

    @Test("without a GitHub repository only URLs link; other URLs and addresses are still found")
    func otherLinks() {
        let message = "Fix #12 for @octocat (see https://example.com/a), docs at (https://example.com/b) or mail joe@example.com"
        let text = RichText.attributed(message, gitHubRepository: nil, underlinesLinks: true)
        let linked = runs(text).filter { $0.link != nil }
        // The second URL follows "(", which the tokenizer leaves alone.
        #expect(linked.map(\.text) == ["https://example.com/a", "https://example.com/b", "joe@example.com"])
        #expect(linked.first?.link == URL(string: "https://example.com/a"))
        #expect(linked.last?.link?.scheme == "mailto")
        #expect(String(text.characters) == message)
    }
}
