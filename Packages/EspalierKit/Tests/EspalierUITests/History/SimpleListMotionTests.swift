// Simple mode's motion. A merge's commits slide down from under it and back
// up, up to 100 rows, and the "Loading…" line shows only past 300 ms;
// motion never changes a result: expanding then collapsing during the load
// or the slide ends collapsed, the selection on the merge's commit.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Simple list motion", .offline, .hangGuard(minutes: 5)) @MainActor
struct SimpleListMotionTests {
    private let mergeSummary = "Merge pull request #209 from jonas/widget-refresh"

    @Test("expanding a merge, then collapsing it while its commits load, ends collapsed with the merge selected")
    func collapseDuringLoad() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleListFixture()
            let mergeSHA = try #require(fixture.shas[mergeSummary])
            let historyRow = try #require(fixture.history.row(of: mergeSHA))
            let (controller, window) = fixture.table()
            defer { window.contentView = nil }
            window.motionOverride = true
            controller.scheduler = fixture.harness.scheduler
            fixture.history.select(shas: [mergeSHA], contiguous: true)
            fixture.update(controller)
            let mergeTableRow = try fixture.tableRow(mergeSummary, in: controller)

            // Expanded: its commits load, and no line shows before 300 ms.
            fixture.history.setMergeExpanded(true, row: historyRow)
            fixture.update(controller)
            #expect(fixture.history.mergedCommits(ofRow: historyRow)?.state == .loading)
            #expect(controller.items.count == fixture.history.commitSHAs.count)

            // Collapsed before they load.
            controller.setExpanded(false, atTableRow: mergeTableRow)
            fixture.update(controller)
            await fixture.settle()
            fixture.update(controller)
            #expect(fixture.history.mergedCommits(ofRow: historyRow) == nil)
            #expect(controller.items == fixture.history.simpleOutline.items)
            #expect(controller.items.count == fixture.history.commitSHAs.count)
            #expect(controller.tableView.numberOfRows == controller.items.count)
            #expect(fixture.history.selection.shas == [mergeSHA])
            #expect(controller.tableView.selectedRowIndexes == IndexSet([mergeTableRow]))
        }
    }

    @Test("collapsing a merge while its commits slide in ends collapsed, the selection back on the merge")
    func collapseDuringSlide() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleListFixture()
            let mergeSHA = try #require(fixture.shas[mergeSummary])
            let historyRow = try #require(fixture.history.row(of: mergeSHA))
            let (controller, window) = fixture.table()
            defer { window.contentView = nil }
            window.motionOverride = true
            controller.scheduler = fixture.harness.scheduler
            let mergeTableRow = try fixture.tableRow(mergeSummary, in: controller)

            // The commits loaded: they slide down from under the merge.
            fixture.history.setMergeExpanded(true, row: historyRow)
            await fixture.settle()
            fixture.update(controller)
            #expect(controller.items.count == fixture.history.commitSHAs.count + 2)
            #expect(controller.tableView.numberOfRows == controller.items.count)

            // One of them selected, then ← while they slide: back to the
            // merge, collapsed.
            let widget = try fixture.tableRow("Use the new widget sizes", in: controller)
            controller.tableView.selectRowIndexes([widget], byExtendingSelection: false)
            #expect(fixture.history.selection.shas == [fixture.shas["Use the new widget sizes"]!])
            controller.setExpanded(false, atTableRow: widget)
            fixture.update(controller)
            #expect(controller.items == fixture.history.simpleOutline.items)
            #expect(controller.items.count == fixture.history.commitSHAs.count)
            #expect(controller.tableView.numberOfRows == controller.items.count)
            #expect(fixture.history.selection.shas == [mergeSHA])
            #expect(controller.tableView.selectedRowIndexes == IndexSet([mergeTableRow]))
            await fixture.settle()
        }
    }

    @Test("only a merge's commits slide, up to 100 rows")
    func slideLimits() {
        let merged = (0..<100).map { SimpleHistoryItem.mergedCommit(mergeRow: 3, index: $0) }
        #expect(SimpleListController.isMergeSlide(removed: [], inserted: merged))
        #expect(SimpleListController.isMergeSlide(removed: merged, inserted: []))
        // The loading line giving way to the commits.
        #expect(SimpleListController.isMergeSlide(removed: [.mergedCommitsStatus(mergeRow: 3)], inserted: Array(merged.prefix(4))))
        // More than 100 rows, a page of the branch's own commits, nothing.
        #expect(!SimpleListController.isMergeSlide(removed: [], inserted: merged + [.mergedCommit(mergeRow: 3, index: 100)]))
        #expect(!SimpleListController.isMergeSlide(removed: [], inserted: [.commit(row: 40), .commit(row: 41)]))
        #expect(!SimpleListController.isMergeSlide(removed: [], inserted: []))
    }
}
