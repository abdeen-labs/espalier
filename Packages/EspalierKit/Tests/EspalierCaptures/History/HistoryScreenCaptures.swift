// History's places on a real repository (HistoryCaptureFixtures): History
// with the graph of every local branch and HEAD's commit's detail, the
// working copy's detail, a branch's place with its history and with
// Compare's Behind, and a tag off the simple list's line. The list and the
// detail are laid out side by side, the list at its style's ideal width,
// rather than in the place's split, whose divider position is remembered.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("History screen", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct HistoryScreenCaptures {
    private let area = "HistoryScreen"

    @Test("History: the graph of every local branch, and HEAD's commit's detail")
    func history() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryPlaceFixture()
            await fixture.show(.history)
            await capturePlace(fixture, .history, named: "history")
            await fixture.settle()
        }
    }

    @Test("the working copy's row selected: the uncommitted changes")
    func workingCopy() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryPlaceFixture()
            await fixture.show(.history)
            fixture.history.selectWorkingCopy()
            fixture.repository.changes.select(fileIDs: fixture.repository.changes.workingDirectory.files.map(\.id))
            await fixture.settle()
            await capturePlace(fixture, .history, named: "workingCopy")
            await fixture.settle()
        }
    }

    @Test("a branch's place, compared with main: its history with its tip selected, then Compare to Branch's Behind, with a commit main doesn't have")
    func branch() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryPlaceFixture()
            let branch = try #require(fixture.repository.gitState.branches.all.first { $0.name == "fix/crash" })
            let place = SidebarPlace.branch(ref: branch.ref)
            await fixture.show(place)
            // The header's counts, which it reads from the cache once
            // they're counted.
            let head = try #require(fixture.repository.gitState.tip.sha)
            _ = await fixture.repository.branches.aheadBehind(from: head, to: branch.tip.sha)
            await capturePlace(fixture, place, named: "branch")

            HistoryPlaces.showComparison(of: branch, in: fixture.context)
            await fixture.show(place)
            await fixture.history.comparison.idle()
            await capturePlace(fixture, place, named: "compare")
            await fixture.settle()
        }
    }

    @Test("a tag off the simple list's line says so and offers the graph")
    func tagOffTheLine() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryPlaceFixture(dirty: false)
            try await runGit(["tag", "crash-fix", "fix/crash"], fixture.local)
            await fixture.repository.refresh(.full, reason: .user)
            fixture.history.setStyle(.simple)
            let place = SidebarPlace.tag(name: "crash-fix")
            await fixture.show(place)
            try #require(fixture.context.state.history.notice != nil)
            await capturePlace(fixture, place, named: "tagOffTheLine")
            await fixture.settle()
        }
    }

    /// Captures `place`'s list and detail, once the detail's diff shows.
    private func capturePlace(_ fixture: HistoryCaptureFixture, _ place: SidebarPlace, named name: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        let panes = HStack(spacing: 0) {
            HistoryListPane(repository: fixture.repository, place: place)
                .frame(width: place.kind(style: fixture.history.style).leadingColumn.ideal)
            Divider()
            HistoryDetailPane(repository: fixture.repository)
        }
        await captureLoaded(
            panes.windowEnvironment(fixture.context),
            named: name,
            area: area,
            size: CGSize(width: 1_100, height: 520),
            sourceLocation: sourceLocation
        )
    }
}
