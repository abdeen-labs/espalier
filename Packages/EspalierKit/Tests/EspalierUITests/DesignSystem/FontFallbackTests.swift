// A font AppKit returns as nil, despite its declaration, is stood in for:
// at its size, in its design, so a ref tag's text that held it lays out
// instead of crashing Core Text.

import AppKit
import Testing
@testable import EspalierUI

@Suite("Font fallback")
struct FontFallbackTests {
    /// A font reference that's nil, as AppKit's makers return one when the
    /// font server doesn't answer.
    nonisolated(unsafe) private static let missing = unsafeBitCast(NSFont?.none, to: NSFont.self)

    @Test("a nil font is stood in for at its size, and a ref tag's text in it lays out", arguments: [FontFallback.Design.sans, .mono])
    func standIn(_ design: FontFallback.Design) throws {
        #expect(FontFallback.present(Self.missing) == nil)
        let font = FontFallback.checked(Self.missing, size: 10, design: design)
        #expect(FontFallback.present(font) != nil)
        #expect(font.pointSize == 10)
        let title = NSAttributedString(string: "feature/hourly-forecast", attributes: [.font: font, .foregroundColor: NSColor.white])
        #expect(title.size().width > 0)
    }

    @Test("a font AppKit made passes through")
    func madeFont() {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        #expect(FontFallback.checked(font, size: 10, design: .mono) === font)
    }
}
