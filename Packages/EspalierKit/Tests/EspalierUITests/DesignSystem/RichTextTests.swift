// How commit messages show their tokens (the tokenizer's own tests are
// EspalierCoreTests/Text/TextTokenParserTests.swift): links in a commit's
// header and Commit Info.

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

    @Test("a GitHub repository's messages link issue references, mentions, and URLs, underlined per the setting")
    func gitHubLinks() {
        let text = RichText.attributed(
            "Fix #12 :tada: thanks @octocat, see https://github.com/octo/app/issues/7",
            gitHubRepository: repository,
            underlinesLinks: true
        )
        let parts = runs(text)
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
    }
}
