// The history graph's table on a real repository (HistoryCaptureFixtures):
// its rows (the working copy, HEAD with its branch, a merge, unpushed
// commits, a remote branch and tags on one commit, and the selection), the
// row a context menu acts on, the narrowest rows, and a search with a
// focused branch over a clean working copy. The table is focused, so the
// selection draws in the accent.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("History table", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct HistoryTableCaptures {
    private let area = "HistoryTable"

    @Test("rows: the working copy, HEAD with refs, a merge, unpushed commits, and selection")
    func rows() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryTableFixture()
            await fixture.show(.history)
            try fixture.history.select(shas: [#require(fixture.shas["Add sign-in sheet"])], contiguous: true)
            await fixture.settle()
            captureTable(fixture, place: .history, named: "rows")
            await fixture.settle()
        }
    }

    @Test("the row a context menu acts on shows the accent ring, unselected and selected")
    func contextTarget() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryTableFixture()
            await fixture.show(.history)
            let selected = try #require(fixture.shas["Sign in with the device flow"])
            fixture.history.select(shas: [selected], contiguous: true)
            await fixture.settle()
            let selectedRow = try #require(fixture.history.row(of: selected))
            let other = try #require(fixture.shas["Update docs"])
            let otherRow = try #require(fixture.history.row(of: other))
            captureTable(fixture, place: .history, named: "context-target") { controller in
                _ = controller.tableView.contextMenuTarget.mark(otherRow)
            }
            captureTable(fixture, place: .history, named: "context-target-selected") { controller in
                _ = controller.tableView.contextMenuTarget.mark(selectedRow)
            }
            await fixture.settle()
        }
    }

    @Test("the narrowest rows: no author, avatar, or date")
    func narrow() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryTableFixture()
            await fixture.show(.history)
            captureTable(fixture, place: .history, named: "narrow-360", width: 360)
            await fixture.settle()
        }
    }

    @Test("a clean working copy, a search, and a focused branch")
    func searchAndFocus() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryTableFixture(dirty: false)
            let place = SidebarPlace.branch(ref: "refs/heads/feature/login")
            await fixture.show(place)
            fixture.history.setSearchQuery("sign")
            await fixture.settle()
            captureTable(fixture, place: place, named: "search-focus")
            await fixture.settle()
        }
    }

    /// Captures the graph table of `fixture`'s history as `place` shows it,
    /// every row in view, focused; `prepare` gets the laid-out controller
    /// before drawing.
    private func captureTable(
        _ fixture: HistoryCaptureFixture,
        place: SidebarPlace,
        named name: String,
        width: CGFloat = 640,
        prepare: (GraphTableController) -> Void = { _ in },
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let history = fixture.history
        let size = CGSize(width: width, height: CGFloat(history.graph.count) * Metrics.Graph.rowHeight)
        capture(named: name, area: area, sourceLocation: sourceLocation) { appearance in
            let controller = GraphTableController()
            controller.avatarLoader = MonogramAvatarLoader()
            let window = CaptureWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance.appearance
            let container = NSView(frame: CGRect(origin: .zero, size: size))
            controller.scrollView.frame = container.bounds
            controller.scrollView.autoresizingMask = [.width, .height]
            container.addSubview(controller.scrollView)
            window.contentView = container
            defer { window.contentView = nil }
            window.makeFirstResponder(controller.tableView)
            controller.update(
                source: history,
                presentation: GraphPresentation(repository: fixture.repository, place: place),
                selection: GraphSelection(shas: history.selection.shas, isWorkingCopy: history.isWorkingCopySelected),
                reorderInsertionRow: nil
            )
            container.layoutSubtreeIfNeeded()
            controller.tableView.layoutSubtreeIfNeeded()
            prepare(controller)
            container.layoutSubtreeIfNeeded()
            return Capture.image(of: container)
        }
    }
}
