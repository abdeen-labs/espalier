// Where the parts of the image a drag of commits shows go: one commit's
// card, and several stacked behind it with their count's badge.

import AppKit
import Testing
@testable import EspalierUI

@Suite("Commit drag image") @MainActor
struct CommitDragImageTests {
    @Test("one commit has one card and no badge; several stack at most three cards, the badge on the front card's corner")
    func layout() {
        let rowSize = CGSize(width: 300, height: 44)
        let one = CommitDragImage.Layout(rowSize: rowSize, count: 1)
        #expect(one.cardsBehind.isEmpty)
        #expect(one.badge == nil)
        #expect(one.card.size == rowSize)

        let several = CommitDragImage.Layout(rowSize: rowSize, count: 5)
        #expect(several.cardsBehind.count == 2)
        #expect(several.badgeText == "5")
        guard let badge = several.badge else {
            Issue.record("No badge for several commits")
            return
        }
        #expect(CGPoint(x: badge.midX, y: badge.midY) == CGPoint(x: several.card.maxX, y: several.card.maxY))
        // Every part is inside the image.
        let bounds = CGRect(origin: .zero, size: several.size)
        #expect(([several.card] + several.cardsBehind).allSatisfy { bounds.contains($0) })
        #expect(bounds.contains(badge))

        let wide = CommitDragImage.Layout(rowSize: CGSize(width: 900, height: 44), count: 2)
        #expect(wide.card.width == Metrics.CommitDragImage.maximumWidth)
        #expect(wide.cardsBehind.count == 1)
    }
}
