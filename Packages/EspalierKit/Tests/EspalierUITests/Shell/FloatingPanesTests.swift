// A place's split floats or lays its panes flat as the look changes,
// keeping its leading pane's content as wide; a split inside a pane stays
// flat; floating, the whole gap between the cards drags the divider.

import AppKit
@testable import EspalierCore
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Floating panes") @MainActor
struct FloatingPanesTests {
    /// A place's split as `SplitView` makes it, its leading pane `width`
    /// wide, in a split `total` wide.
    private func split(width: CGFloat, total: CGFloat = 1_000) -> (PaneSplitView, PaneCardView, PaneCardView) {
        let splitView = PaneSplitView(frame: CGRect(x: 0, y: 0, width: total, height: 600))
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.holdsPanes = true
        let leading = PaneCardView(content: NSView(frame: CGRect(x: 0, y: 0, width: width, height: 600)))
        let trailing = PaneCardView(content: NSView(frame: CGRect(x: width + 1, y: 0, width: total - width - 1, height: 600)))
        splitView.addArrangedSubview(leading)
        splitView.addArrangedSubview(trailing)
        splitView.adjustSubviews()
        splitView.setPosition(width, ofDividerAt: 0)
        return (splitView, leading, trailing)
    }

    @Test("a place's split floats its panes when the look does, and lays them flat again, the leading pane's content as wide")
    func switchesLive() {
        let (splitView, leading, trailing) = split(width: 320)
        splitView.updateLayout()
        #expect(!splitView.floats)
        #expect(splitView.dividerThickness == 1)
        #expect(leading.content.frame.width == 320)

        Look.with(Look(theme: .islands)) {
            splitView.lookDidChange()
        }
        #expect(splitView.floats)
        #expect(leading.floats && trailing.floats)
        // The gap between the cards is 8: 4 between their frames, and the
        // 2 each keeps for its ring and shadow.
        #expect(splitView.dividerThickness == PaneCards.frameGap)
        #expect(trailing.frame.minX - leading.frame.maxX == PaneCards.frameGap)
        #expect(leading.content.convert(leading.content.bounds, to: splitView).minX == PaneCards.inset)
        #expect(leading.content.frame.width == 320)

        Look.with(Look(theme: .orchard)) {
            splitView.lookDidChange()
        }
        #expect(!splitView.floats)
        #expect(!leading.floats)
        #expect(splitView.dividerThickness == 1)
        #expect(leading.content.frame.width == 320)
        #expect(leading.content.convert(leading.content.bounds, to: splitView).minX == 0)
    }

    @Test("a split inside a pane stays flat in the floating layout")
    func innerSplitStaysFlat() {
        let (splitView, leading, _) = split(width: 200)
        splitView.holdsPanes = false
        Look.with(Look(theme: .islands)) {
            splitView.updateLayout()
        }
        #expect(!splitView.floats)
        #expect(!leading.floats)
        #expect(splitView.dividerThickness == 1)
    }

    @Test("floating, the whole gap between the cards drags the divider")
    func gapDrags() {
        let (splitView, _, _) = split(width: 320)
        let coordinator = SplitView<EmptyView, EmptyView>.Coordinator(column: Metrics.Column.changesFileList)
        Look.with(Look(theme: .islands)) {
            splitView.updateLayout()
        }
        let drawn = CGRect(x: 324, y: 0, width: PaneCards.frameGap, height: 600)
        let effective = coordinator.splitView(splitView, effectiveRect: drawn, forDrawnRect: drawn, ofDividerAt: 0)
        #expect(effective.width == PaneCards.gap)
        #expect(effective.minX == drawn.minX - PaneCards.inset)
    }
}
