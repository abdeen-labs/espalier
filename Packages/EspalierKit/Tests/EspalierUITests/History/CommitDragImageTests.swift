// The image a drag of commits shows: one commit's row on a card, several
// stacked with their count, in light and dark; and where its parts go.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Commit drag image") @MainActor
struct CommitDragImageTests {
    private let area = "History"

    @Test("one commit's row on a card; several stacked behind it, with their count")
    func snapshot() {
        for (name, count) in [("dragImage-one", 1), ("dragImage-several", 12)] {
            for appearance in SnapshotAppearance.allCases {
                let rowSize = CGSize(width: 300, height: Metrics.Graph.rowHeight)
                let layout = CommitDragImage.Layout(rowSize: rowSize, count: count)
                let image = CommitDragImage.image(rowImage: Self.row(size: rowSize, appearance: appearance), layout: layout, appearance: appearance.appearance, scale: 1)
                let view = NSImageView(frame: CGRect(origin: .zero, size: layout.size))
                view.image = image
                view.imageScaling = .scaleNone
                let rendered = Snapshot.render(view, size: layout.size, appearance: appearance)
                assertSnapshot(rendered, named: name, area: area, appearance: appearance)
            }
        }
    }

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

    /// A selected commit row, as a bitmap.
    private static func row(size: CGSize, appearance: SnapshotAppearance) -> NSBitmapImageRep {
        let row = HStack(spacing: Metrics.insetSmall) {
            Circle()
                .fill(Color(espalier: Palette.accent))
                .frame(width: 10, height: 10)
            Text("Fetch hourly data from the forecast API")
                .font(Typography.row.weight(.medium))
                .foregroundStyle(.text)
            Spacer(minLength: 0)
            Text("18h")
                .font(Typography.secondary)
                .foregroundStyle(.text3)
        }
        .padding(.horizontal, Metrics.insetMedium)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous).fill(.accentSoft).padding(.horizontal, Metrics.grid))
        return Snapshot.render(row, size: size, appearance: appearance)
    }
}
