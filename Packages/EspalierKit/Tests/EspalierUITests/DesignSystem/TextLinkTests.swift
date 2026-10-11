// Espalier's links: a link button and a link in text, at rest, hovered,
// pressed, focused, and disabled, in light and dark; and what the link
// styling changes in an attributed string.

import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Links") @MainActor
struct TextLinkTests {
    private let area = "Components"

    @Test("links: a button at rest, hovered, pressed, focused, and disabled; links in text at rest and hovered")
    func snapshot() {
        var hoveredText = LinkedText(markdown: "New to GitHub? [Create your free account.](https://github.com/join)")
        hoveredText.isHoveredOverride = true
        let view = VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            HStack(spacing: Metrics.insetLarge) {
                Button("Skip This Step") {}
                    .buttonStyle(.textLink)
                TextLinkBody(label: Text("Hovered"), isPressed: false, isHoveredOverride: true)
                TextLinkBody(label: Text("Pressed"), isPressed: true)
                Button("Disabled") {}
                    .buttonStyle(.textLink)
                    .disabled(true)
            }
            Button("Focused") {}
                .buttonStyle(.textLink)
                .environment(\.showsFocusRings, true)
            LinkedText(markdown: "New to GitHub? [Create your free account.](https://github.com/join)")
                .foregroundStyle(.text2)
            hoveredText
                .foregroundStyle(.text2)
        }
        .font(Typography.secondary)
        .padding(Metrics.insetLarge)
        assertSnapshot(view, named: "links", area: area)
    }

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
