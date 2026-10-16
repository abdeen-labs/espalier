// The sidebar's two styles (Settings ▸ Appearance ▸ Sidebar): hidden, the
// column a window opens without, which View ▸ Show Sidebar shows; and
// icons, the rail, which Hide Sidebar hides while the column stays
// collapsed, with an icon for each section the repository has.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Sidebar styles", .offline, .hangGuard(minutes: 5)) @MainActor
struct SidebarStyleTests {
    @Test("in the hidden style a window opens without the column, and Show Sidebar shows and hides it")
    func hiddenStyle() async throws {
        let fixture = try await makeOperationsFixture()
        let context = fixture.context
        #expect(context.sidebarStyle == .hidden)
        #expect(context.isSidebarHidden)

        context.actions.perform(.toggleSidebar)
        await fixture.settle()
        #expect(context.state.columnVisibility != .detailOnly)
        #expect(!context.isSidebarHidden)

        context.actions.perform(.toggleSidebar)
        await fixture.settle()
        #expect(context.state.columnVisibility == .detailOnly)
        #expect(context.isSidebarHidden)
    }

    @Test("in the icons style Hide Sidebar hides the rail, never showing the column, and Filter Sidebar opens the first section's popover")
    func iconsStyle() async throws {
        let fixture = try await makeOperationsFixture()
        let context = fixture.context
        fixture.app.preferences.sidebarStyle = .icons
        #expect(!context.isSidebarHidden)

        context.actions.perform(.toggleSidebar)
        await fixture.settle()
        #expect(context.state.isRailHidden)
        #expect(context.isSidebarHidden)
        #expect(context.state.columnVisibility == .detailOnly)

        context.actions.perform(.filterSidebar)
        await fixture.settle()
        #expect(!context.state.isRailHidden)
        #expect(context.state.railPopover == .branches)
        #expect(context.state.isSidebarFilterFocused)
        #expect(context.state.columnVisibility == .detailOnly)
    }

    @Test("the rail has Branches, and Tags and Stashes once the repository has them")
    func railSections() async throws {
        let fixture = try await makeOperationsFixture()
        let accounts = fixture.app.accounts
        #expect(RailSection.shown(in: fixture.repository, accounts: accounts) == [.branches])

        try await fixture.git(["tag", "v1.0"])
        try Data("draft\n".utf8).write(to: URL(exactFilePath: fixture.local.path + "/draft.txt"))
        try await fixture.git(["stash", "push", "-q", "--include-untracked"])
        await fixture.refresh()
        #expect(RailSection.shown(in: fixture.repository, accounts: accounts) == [.branches, .tags, .stashes])
    }
}
