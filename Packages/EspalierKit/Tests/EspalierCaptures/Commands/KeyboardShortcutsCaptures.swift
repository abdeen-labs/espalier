// Help ▸ Keyboard Shortcuts, in light and dark: the sheet as it opens, and
// scrolled to its end, where the lists' Show Context Menu (⇧F10) is.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Keyboard Shortcuts sheet", .captures) @MainActor
struct KeyboardShortcutsCaptures {
    private let area = "Commands"

    @Test("the sheet as it opens")
    func opened() {
        capture(KeyboardShortcutsSheet(), named: "keyboardShortcuts", area: area)
    }

    @Test("the sheet scrolled to its end")
    func scrolledToEnd() {
        capture(KeyboardShortcutsSheet(), named: "keyboardShortcuts-end", area: area) { host in
            guard let table = host.captureDescendants(NSTableView.self).first,
                  let scrollView = table.enclosingScrollView else {
                Issue.record("The sheet has no scrolling table")
                return
            }
            let clip = scrollView.contentView
            // Twice: the rows that come into view take their heights, which
            // moves the end.
            for _ in 0..<2 {
                clip.scroll(to: CGPoint(x: 0, y: max(table.bounds.height - clip.bounds.height, 0)))
                scrollView.reflectScrolledClipView(clip)
                host.layoutSubtreeIfNeeded()
            }
        }
    }
}
