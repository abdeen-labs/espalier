// Help ▸ Keyboard Shortcuts, in light and dark: the sheet as it opens, and
// scrolled to its end, where the lists' Show Context Menu (⇧F10) is.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Keyboard Shortcuts sheet") @MainActor
struct KeyboardShortcutsSheetTests {
    private let area = "Commands"

    @Test("the sheet as it opens, and scrolled to its end")
    func snapshots() throws {
        assertSnapshot(KeyboardShortcutsSheet(), named: "keyboardShortcuts", area: area)
        for appearance in SnapshotAppearance.allCases {
            assertSnapshot(try scrolledToEnd(appearance), named: "keyboardShortcuts-end", area: area, appearance: appearance)
        }
    }

    /// The sheet at its size, its list scrolled to the last shortcut.
    private func scrolledToEnd(_ appearance: SnapshotAppearance) throws -> NSBitmapImageRep {
        let root = Snapshot.deterministic(KeyboardShortcutsSheet())
            .background(Color(nsColor: Palette.background))
        let host = NSHostingView(rootView: root)
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        window.contentView = host
        defer { window.contentView = nil }
        let size = host.fittingSize
        let bounds = CGRect(origin: .zero, size: CGSize(width: ceil(size.width), height: ceil(size.height)))
        window.setContentSize(bounds.size)
        host.frame = bounds
        host.layoutSubtreeIfNeeded()

        let table = try #require(firstView(NSTableView.self, in: host))
        let scrollView = try #require(table.enclosingScrollView)
        let clip = scrollView.contentView
        // Twice: the rows that come into view take their heights, which
        // moves the end.
        for _ in 0..<2 {
            clip.scroll(to: CGPoint(x: 0, y: max(table.bounds.height - clip.bounds.height, 0)))
            scrollView.reflectScrolledClipView(clip)
            host.layoutSubtreeIfNeeded()
        }
        #expect(table.rows(in: table.visibleRect).upperBound == table.numberOfRows)
        return Snapshot.image(of: host)
    }
}
