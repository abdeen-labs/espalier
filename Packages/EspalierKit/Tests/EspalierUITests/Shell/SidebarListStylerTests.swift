// The sidebar's list draws no selection of its own from its first frame:
// the sidebar's selected item is a neutral wash its row draws.

import AppKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Sidebar list styler") @MainActor
struct SidebarListStylerTests {
    /// The first table in `view`'s tree.
    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView {
            return table
        }
        for subview in view.subviews {
            if let table = table(in: subview) {
                return table
            }
        }
        return nil
    }

    @Test("a sidebar list with a selected place has no highlight of its own after its first layout")
    func listHasNoHighlightAfterFirstLayout() throws {
        let list = List(selection: Binding<SidebarPlace?>.constant(.history)) {
            PlacesSectionRows(changes: ChangesPlaceRowContent(changedFileCount: 3, hasConflicts: false), selection: .history)
        }
        .sidebarListStyle()
        .environment(\.sidebarSelection, .history)
        .frame(width: Metrics.Column.sidebar.ideal, height: 200)

        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: Metrics.Column.sidebar.ideal, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Snapshot.deterministic(list))
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = CGRect(x: 0, y: 0, width: Metrics.Column.sidebar.ideal, height: 200)
        host.layoutSubtreeIfNeeded()

        let table = try #require(table(in: host))
        #expect(table.selectionHighlightStyle == .none)
    }
}
