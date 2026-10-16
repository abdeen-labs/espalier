// History's simple list on a real repository (HistoryCaptureFixtures): the
// base's notice, then the feature branch's commits one after another,
// merges as one row; a merge expanded, the commits it brought in indented
// under it; and a search that moved to a match inside a merge. The list is
// drawn alone (the header is History's).

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Simple history", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct SimpleHistoryCaptures {
    private let area = "SimpleHistory"

    @Test("the list: the base's notice, then the branch's commits one after another, merges as one row")
    func list() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleHistoryFixture()
            try fixture.history.select(shas: [#require(fixture.shas["Fetch hourly data from the forecast API"])], contiguous: true)
            await fixture.settle()
            await captureList(fixture, named: "list")
            await fixture.settle()
        }
    }

    @Test("a merge expanded: the commits it brought in, indented under it")
    func expandedMerge() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleHistoryFixture()
            let mergeSHA = try #require(fixture.shas["Merge pull request #209 from jonas/widget-refresh"])
            let merge = try #require(fixture.history.row(of: mergeSHA))
            fixture.history.setMergeExpanded(true, row: merge)
            try fixture.history.select(shas: [#require(fixture.shas["Use the new widget sizes"])], contiguous: true)
            await fixture.settle()
            await captureList(fixture, named: "expanded")
            await fixture.settle()
        }
    }

    @Test("a search moved to a match inside a merge: the merge expanded, its matching commit selected, the others dimmed")
    func searchInsideMerge() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleHistoryFixture()
            fixture.history.setSearchQuery("refresh")
            await fixture.settle()
            // The merge's row, then "Refresh the widget's timeline" inside it.
            fixture.history.selectNextSearchMatch()
            fixture.history.selectNextSearchMatch()
            await fixture.settle()
            let match = try #require(fixture.shas["Refresh the widget's timeline"])
            try #require(fixture.history.selection.shas == [match])
            await captureList(fixture, named: "search-insideMerge")
            await fixture.settle()
        }
    }

    /// Captures the simple list alone.
    private func captureList(_ fixture: HistoryCaptureFixture, named name: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        await captureLoaded(
            SimpleHistoryList(repository: fixture.repository).windowEnvironment(fixture.context),
            named: name,
            area: area,
            size: CGSize(width: 400, height: 640),
            sourceLocation: sourceLocation
        )
    }
}
