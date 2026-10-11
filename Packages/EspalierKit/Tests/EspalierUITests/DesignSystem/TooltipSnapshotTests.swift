// Espalier's tooltip card, light and dark: a short tooltip on one line, a
// long one wrapping at the card's width, and one of several lines.

import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Tooltip snapshots") @MainActor
struct TooltipSnapshotTests {
    private let area = "Tooltips"

    @Test("a short tooltip on one line")
    func short() {
        assertSnapshot(TooltipCard(text: "Fetch origin"), named: "short", area: area)
    }

    @Test("a long tooltip wraps at the card's width")
    func wrapping() {
        assertSnapshot(
            TooltipCard(text: "The commit message fails repository rules you can bypass. Committing anyway bypasses them for this commit."),
            named: "wrapping",
            area: area
        )
    }

    @Test("a tooltip of several lines")
    func multiLine() {
        assertSnapshot(
            TooltipCard(text: "octo-org/website\n/Users/joe/Developer/website\nThis worktree is locked."),
            named: "multiLine",
            area: area
        )
    }
}
