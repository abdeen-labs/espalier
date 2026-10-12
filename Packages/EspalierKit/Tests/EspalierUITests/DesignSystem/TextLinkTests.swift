// Espalier's links in text: what the link styling changes in an
// attributed string, and Markdown's links.

import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Links") @MainActor
struct TextLinkTests {
    @Test("links in text take the link color and, while hovered, the underline; the rest of the text is as it was")
    func styling() throws {
        var text = AttributedString("Read the ")
        var link = AttributedString("guide")
        link.link = URL(string: "https://example.com/guide")
        text.append(link)
        text.append(AttributedString(" first."))

        let rest = LinkedText.styled(text, underlined: false)
        let hovered = LinkedText.styled(text, underlined: true)
        #expect(String(rest.characters) == "Read the guide first.")
        let color = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self
        let underline = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self
        for run in rest.runs {
            #expect((run.link != nil) == (rest[run.range][color] != nil))
            #expect(rest[run.range][underline] == nil)
        }
        for run in hovered.runs {
            #expect((run.link != nil) == (hovered[run.range][underline] != nil))
        }
        #expect(hovered.runs.contains { $0.link == URL(string: "https://example.com/guide") })
    }

    @Test("text without links is left as it is")
    func noLinks() {
        let text = AttributedString("No links here.")
        #expect(LinkedText.styled(text, underlined: true) == text)
    }

    @Test("Markdown links become links")
    func markdown() {
        let text = LinkedText(markdown: "See [the docs](https://git-scm.com/docs/gitignore).").text
        #expect(String(text.characters) == "See the docs.")
        #expect(text.runs.contains { $0.link == URL(string: "https://git-scm.com/docs/gitignore") })
    }
}
