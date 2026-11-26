// The shelf's content from a shelf of work: the tabs' order under each
// arrangement, which are compact, which is selected, the marks they carry,
// a linked worktree's menu, and when the shelf shows; and what the toolbar
// offers on Home, off it, and with Home off.

import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Work shelf")
struct WorkShelfTests {
    private let format = NumberFormat(thousandsSeparator: .comma, decimalSeparator: .period)

    private func content(_ builder: WorkSampleBuilder, _ arrangement: RepositoryArrangement) -> ShelfContent {
        ShelfContent.make(builder.shelf(arrangement), arrangement: arrangement, format: format)
    }

    @Test("under Needs You, the work in progress follows the rest as compact tabs, each group in the shelf's order")
    func needsYou() {
        let content = content(.sample(), .needsYou)

        #expect(content.tabs.map(\.branch) == ["feature/charts", "fix/tide-zone", "agent/rate-limits", "agent/onboarding", "cache-keys", "agent/nav"])
        #expect(content.compactTabs.map(\.branch) == ["feature/widget", "agent/units", "agent/cache"])
        #expect(content.compactTabs.map(\.mark) == [.changingNow, .changingNow, .waitingOnChecks])
        #expect(content.quietRepositoryCount == 23)
    }

    @Test("under Recent Activity, every piece of work is a full tab in the shelf's order, the work in progress marked with what it's doing")
    func recentActivity() {
        let builder = WorkSampleBuilder.sample()
        let content = content(builder, .recentActivity)

        #expect(content.compactTabs.isEmpty)
        #expect(content.tabs.map(\.id) == builder.shelf(.recentActivity).work.map(\.id))
        #expect(content.tabs.map(\.mark) == [nil, nil, .checksFailing, .operationStopped, .changesRequested, .merged, .changingNow, .changingNow, .waitingOnChecks])
    }

    @Test("the open work's tab is the selected one, and stays a full tab under Needs You while it's in progress")
    func openWork() throws {
        var builder = WorkSampleBuilder.sample()
        let widget = try #require(builder.work().first { $0.entry?.branch == "refs/heads/feature/widget" })
        builder.open = widget.id

        let content = content(builder, .needsYou)

        #expect(content.tabs.filter(\.isOpen).map(\.id) == [widget.id])
        #expect(content.openTabID == widget.id)
        #expect(content.tabs.last?.id == widget.id)
        #expect(!content.compactTabs.contains { $0.id == widget.id })
        #expect(content.compactTabs.map(\.branch) == ["agent/units", "agent/cache"])
    }

    @Test("a linked worktree's tab has its worktree's menu; the worktree a record points at has none")
    func linkedWorktrees() {
        let content = content(.sample(), .recentActivity)
        let linked = content.tabs.filter { $0.linkedWorktree != nil }.map(\.branch)

        #expect(linked == ["fix/tide-zone", "feature/widget", "agent/cache"])
        #expect(content.tabs.first { $0.branch == "agent/cache" }?.linkedWorktree?.path == "/worktrees/agent-cache")
    }

    @Test("the shelf has other work with a tab besides the open one's", arguments: [
        NamedCase("only the open work", (false, false, false)),
        NamedCase("the open work and another", (true, false, true)),
        NamedCase("another and nothing open", (false, true, true)),
    ])
    func otherWork(_ testCase: NamedCase<(Bool, Bool, Bool)>) {
        let (addsOther, closesOpen, expected) = testCase.value
        var builder = WorkSampleBuilder()
        builder.open = builder.add("harbor", .quiet)
        if addsOther {
            builder.add("pier-api", .checksFailing, minutesAgo: 1)
        }
        if closesOpen {
            builder.open = nil
            builder.add("pier-api", .checksFailing, minutesAgo: 1)
        }

        #expect(content(builder, .recentActivity).hasOtherWork == expected)
    }

    @Test("a window shows the shelf while it shows a repository with status on, never on Home or without one", arguments: [
        NamedCase("Changes", (DetailDestination.changes(RepositoryID()), true, true)),
        NamedCase("History", (DetailDestination.history(RepositoryID(), .history), true, true)),
        NamedCase("a missing repository", (DetailDestination.missing(RepositoryID()), true, true)),
        NamedCase("status off", (DetailDestination.changes(RepositoryID()), false, false)),
        NamedCase("Home", (DetailDestination.home, true, false)),
        NamedCase("no repository selected", (DetailDestination.noRepositorySelected, true, false)),
        NamedCase("Get Started", (DetailDestination.getStarted, true, false)),
    ])
    func windowShowsShelf(_ testCase: NamedCase<(DetailDestination, Bool, Bool)>) {
        let (destination, isStatusOn, expected) = testCase.value
        #expect(ShelfContent.windowShowsShelf(destination, isStatusOn: isStatusOn) == expected)
    }

    @Test("the toolbar has the Home button and the repository's items off Home, the Home capsule and the jump field on it, and today's items with Home off", arguments: [
        NamedCase("off Home", (true, false, ToolbarOffer(showsHomeButton: true, location: .location, showsRepositoryItems: true, showsJumpField: false, overflow: .repository))),
        NamedCase("on Home", (true, true, ToolbarOffer(showsHomeButton: false, location: .home, showsRepositoryItems: false, showsJumpField: true, overflow: .addRepository))),
        NamedCase("Home off", (false, false, ToolbarOffer(showsHomeButton: false, location: .location, showsRepositoryItems: true, showsJumpField: false, overflow: .repository))),
        NamedCase("Home off, still showing it", (false, true, ToolbarOffer(showsHomeButton: false, location: .location, showsRepositoryItems: true, showsJumpField: false, overflow: .repository))),
    ])
    func toolbar(_ testCase: NamedCase<(Bool, Bool, ToolbarOffer)>) {
        let (showsHome, isOnHome, expected) = testCase.value
        #expect(ToolbarOffer.make(showsHome: showsHome, isOnHome: isOnHome) == expected)
    }
}
