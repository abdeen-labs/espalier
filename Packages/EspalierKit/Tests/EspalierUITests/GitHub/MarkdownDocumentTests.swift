// GitHub's Markdown as the pull request place, reviews, and comments show
// it: blocks, lists and task lists, quotes, code, tables, images from
// Markdown and from GitHub's `<img>` tags, `<br>`, comments dropped, other
// tags' text kept, and links underlined per the setting.

import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Markdown documents") @MainActor
struct MarkdownDocumentTests {
    /// The blocks' kinds and text, for comparing.
    private func outline(_ document: MarkdownDocument) -> [String] {
        document.blocks.map { block in
            let prefix = String(repeating: ">", count: block.quoteDepth) + String(repeating: "  ", count: block.indent)
            switch block.content {
            case .text(let text, let level):
                return prefix + (level.map { "h\($0) " } ?? "p ") + String(text.characters)
            case .listItem(let marker, let text):
                let mark = switch marker {
                case .bullet: "•"
                case .number(let number): "\(number)."
                case .task(let done): done ? "[x]" : "[ ]"
                }
                return prefix + "\(mark) " + String(text.characters)
            case .code(let code, let language):
                return prefix + "code(\(language ?? "")) " + code
            case .table(let header, let rows):
                return prefix + "table " + header.map { String($0.characters) }.joined(separator: "|") + " / "
                    + rows.map { $0.map { String($0.characters) }.joined(separator: "|") }.joined(separator: " / ")
            case .image(let image):
                return prefix + "image \(image.url.absoluteString) alt=\(image.alt)" + (image.width.map { " width=\(Int($0))" } ?? "")
            case .rule:
                return prefix + "rule"
            }
        }
    }

    @Test("Markdown becomes blocks", arguments: [
        NamedCase("a pull request's description: headings, lists, tasks, quotes, code, a table, an image, links", (
            markdown: GitHubFixtures.description,
            outline: [
                "p This adds the device-flow sheet for signing in, as in #140.",
                "h2 What changed",
                "• The code step, with Copy Code",
                "• The Enterprise address step",
                "  • with the OAuth app's client ID",
                "[x] Snapshots in light and dark",
                "[ ] Lead's check in the running app",
                ">p Polling honors slow_down.",
                "code(swift) let code = try await deviceFlow.requestDeviceCode()",
                "table Step|Copy / Code|Enter this code / Expired|This code has expired.",
                "image https://github.com/user-attachments/assets/0f2c6c1e-4b1a-4d38-9a51-5b6f7f4a2c11 alt=The code step width=200",
                "p See the design.",
            ]
        )),
        NamedCase("ordered lists number their items; a list item's later paragraphs are indented without a marker", (
            markdown: """
                1. First
                2. Second

                   More about the second.
                3. Third
                """,
            outline: [
                "1. First",
                "2. Second",
                "  p More about the second.",
                "3. Third",
            ]
        )),
        NamedCase("images from Markdown and HTML split a paragraph; <br> breaks a line; comments go", (
            markdown: """
                Before ![shot](https://example.com/a.png) after.

                Line one<br>line two <!-- a note -->

                <!-- A template's comment -->
                <details><summary>More</summary>

                Hidden &amp; shown

                </details>

                <p align="center"><img src='https://github.com/octocat/hello/assets/1/2f3a' alt="Diagram"></p>
                """,
            outline: [
                "p Before",
                "image https://example.com/a.png alt=shot",
                "p after.",
                "p Line one\nline two",
                "p More",
                "p Hidden & shown",
                "image https://github.com/octocat/hello/assets/1/2f3a alt=Diagram",
            ]
        )),
    ])
    func blocks(_ testCase: NamedCase<(markdown: String, outline: [String])>) {
        #expect(outline(MarkdownDocument.parse(testCase.value.markdown)) == testCase.value.outline)
    }

    @Test("a rule, nested quotes, and an empty document")
    func ruleAndQuotes() {
        #expect(outline(MarkdownDocument.parse("Above\n\n---\n\nBelow")) == ["p Above", "rule", "p Below"])
        #expect(outline(MarkdownDocument.parse("> Outer\n>\n> > Inner")) == [">p Outer", ">>p Inner"])
        #expect(MarkdownDocument.parse("").isEmpty)
        #expect(MarkdownDocument.parse("  \n\n").isEmpty)
        #expect(MarkdownDocument.parse("<!-- only a comment -->").isEmpty)
    }

    @Test("links are underlined when the setting is on")
    func underlinedLinks() throws {
        func link(_ underline: Bool) throws -> AttributedString {
            let document = MarkdownDocument.parse("See [the design](https://example.com).", underlineLinks: underline)
            guard case .text(let text, _)? = document.blocks.first?.content else {
                throw MarkdownTestError.unexpected
            }
            return text
        }
        let underlined = try link(true)
        let linkRun = try #require(underlined.runs.first { $0.link != nil })
        #expect(linkRun.link == URL(string: "https://example.com"))
        #expect(linkRun.underlineStyle == .single)
        let plain = try link(false)
        #expect(plain.runs.first { $0.link != nil }?.underlineStyle == nil)
    }

    @Test("HTML: attributes in any quotes, entities, and tags without a source")
    func html() {
        #expect(MarkdownHTML.image(fromTag: "<img src=https://example.com/a.png alt=bare>") == MarkdownImage(url: URL(string: "https://example.com/a.png")!, alt: "bare", width: nil))
        #expect(MarkdownHTML.image(fromTag: #"<IMG WIDTH="320px" SRC="https://example.com/b.png?x=1&amp;y=2">"#) == MarkdownImage(url: URL(string: "https://example.com/b.png?x=1&y=2")!, alt: "", width: 320))
        #expect(MarkdownHTML.image(fromTag: #"<img data-src="https://example.com/lazy.png">"#) == nil)
        #expect(MarkdownHTML.image(fromTag: "<img alt=\"none\">") == nil)
        #expect(MarkdownHTML.decodeEntities("a &lt;b&gt; &quot;c&quot; &#39;d&#39; &amp;amp;") == "a <b> \"c\" 'd' &amp;")
        #expect(MarkdownHTML.parts(of: "<b>Bold</b> text<br/>next") == [.text("Bold text\nnext")])
    }
}

private enum MarkdownTestError: Error {
    case unexpected
}
