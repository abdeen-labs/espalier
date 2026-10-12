// The sidebar's context menus: ⇧F10 opens the selected place's at its row;
// VoiceOver's Show Menu, or a right-click, opens another place's, and that
// row is the menu's target.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Sidebar keyboard menus", .offline, .hangGuard(minutes: 5)) @MainActor
struct SidebarKeyboardMenuTests {
    @Test("⇧F10 opens the selected place's menu at its row; Show Menu or a right-click on another place's row opens that place's, which it targets")
    func selectedPlaceMenu() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            app.preferences.hasShownWelcomeFlow = true
            let repository = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
            let context = WindowContext(app: app)
            context.state.select(.history, in: repository.id)
            let recorder = MenuRecorder()

            let (window, host) = hostInWindow(
                SidebarContainer()
                    .windowEnvironment(context)
                    .environment(\.menuPresenter, recorder.menuPresenter),
                size: CGSize(width: Metrics.Column.sidebar.ideal, height: 400)
            )
            defer { window.contentView = nil }
            let table = try #require(firstView(NSTableView.self, in: host))
            #expect(window.makeFirstResponder(table))
            let row = table.selectedRow
            #expect(row >= 0)

            #expect(KeyboardContextMenu.handle(try f10KeyDown(in: window), in: window, presenter: recorder.menuPresenter))
            let popup = try #require(recorder.popups.first)
            #expect(table.row(at: table.convert(popup.location, from: popup.view)) == row)

            // VoiceOver's Show Menu on a place's cell: Changes', unselected,
            // opens at its row, and Changes is its target.
            let changesRow = row - 1
            let changes = try #require(allViews(ContextMenuRowView.self, in: table).first { $0.enclosingTableRow?.row == changesRow })
            #expect(KeyboardContextMenu.showMenu(of: changes, presenter: recorder.menuPresenter))
            #expect(recorder.popups.count == 2)
            #expect(table.row(at: table.convert(recorder.popups[1].location, from: recorder.popups[1].view)) == changesRow)
            let region = try #require(ContextMenuRegions.listRegion(for: table))
            #expect(region.listHost?.target.id == AnyHashable(SidebarPlace.changes))

            // A right-click on Changes' row, through the app's events.
            let rowRect = table.convert(table.rect(ofRow: changesRow), to: nil)
            let rightClick = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: CGPoint(x: rowRect.midX, y: rowRect.midY),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            #expect(MenuEventRouter.shared.handle(rightClick) == nil)
            #expect(recorder.popups.count == 3)
            #expect(table.selectedRow == row)
            await app.idle()
        }
    }
}
