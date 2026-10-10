// ⇧F10 in the sidebar: the selected place's menu, at its row; and the
// right-click VoiceOver's Show Menu makes on a place's row.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Sidebar keyboard menus", .offline, .hangGuard(minutes: 5)) @MainActor
struct SidebarKeyboardMenuTests {
    @Test("⇧F10 pops up the menu a right-click on the selected place shows, at its row; Show Menu on another place's row pops up that place's")
    func selectedPlaceMenu() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            app.preferences.hasShownWelcomeFlow = true
            let repository = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
            let context = WindowContext(app: app)
            context.state.select(.history, in: repository.id)

            let (window, host) = hostInWindow(SidebarContainer().windowEnvironment(context), size: CGSize(width: Metrics.Column.sidebar.ideal, height: 400))
            defer { window.contentView = nil }
            let table = try #require(firstView(NSTableView.self, in: host))
            #expect(window.makeFirstResponder(table))
            let row = table.selectedRow
            #expect(row >= 0)

            let popped = PoppedUpMenus()
            #expect(KeyboardContextMenu.handle(try f10KeyDown(in: window), in: window, present: popped.present))
            let popup = try #require(popped.popups.first)
            #expect(popup.view === table)
            #expect(table.row(at: popup.location) == row)
            #expect(popup.titles == ["History Scope"])

            // VoiceOver's Show Menu on a place's row makes its right-click at
            // the row's styler: Changes', unselected, is Changes' menu.
            let changesRow = row - 1
            let changes = try #require(allViews(SidebarListStyler.StylerView.self, in: table).first { $0.enclosingTableRow?.row == changesRow })
            #expect(KeyboardContextMenu.showMenu(of: changes, present: popped.present))
            #expect(popped.popups.count == 2)
            #expect(table.row(at: popped.popups[1].location) == changesRow)
            #expect(popped.popups[1].titles == [context.actions.title(for: .stashAllChanges), context.actions.title(for: .discardAllChanges)])
            await app.idle()
        }
    }
}
