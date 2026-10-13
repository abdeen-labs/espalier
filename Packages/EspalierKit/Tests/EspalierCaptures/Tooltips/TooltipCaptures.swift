// Espalier's tooltip card, light and dark: a short tooltip on one line, a
// long one wrapping at the card's width, and one of several lines.

import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Tooltips", .captures) @MainActor
struct TooltipCaptures {
    private let area = "Tooltips"

    @Test("a short tooltip on one line")
    func short() {
        capture(TooltipCard(text: "Fetch origin"), named: "short", area: area)
    }

    @Test("a long tooltip wraps at the card's width")
    func wrapping() {
        capture(
            TooltipCard(text: "The commit message fails repository rules you can bypass. Committing anyway bypasses them for this commit."),
            named: "wrapping",
            area: area
        )
    }

    @Test("a tooltip of several lines")
    func multiLine() {
        capture(
            TooltipCard(text: "octo-org/website\n/Users/joe/Developer/website\nThis worktree is locked."),
            named: "multiLine",
            area: area
        )
    }
}
