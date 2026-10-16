// The Stashes section's rows and the stash's place, one capture per layout:
// the place's column (a branch's stash, at the widest with the header's
// title, one made outside Espalier, failed, no matches), the section's rows (several per branch, both markers, and
// others by git's message), the place on a real stash with the selected
// file's diff, with the search typed hiding the selected file, and with a
// search matching no file, and the Changes list's "Stashed Changes" row with
// one stash and with several.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Stash", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct StashCaptures {
    private let area = "Stash"

    private static let files = [
        CommittedFileChange(path: "Sources/App/RepositoryLoader.swift", status: .modified(), commitish: "a1b2c3d", parentCommitish: "a1b2c3d^"),
        CommittedFileChange(path: "Sources/App/EmptyState.swift", status: .new(), commitish: "a1b2c3d", parentCommitish: "a1b2c3d^"),
        CommittedFileChange(path: "Legacy.swift", status: .deleted(), commitish: "a1b2c3d", parentCommitish: "a1b2c3d^"),
        CommittedFileChange(path: "README.md", status: .modified(), commitish: "a1b2c3d", parentCommitish: "a1b2c3d^"),
    ]

    private func content(
        files: StashColumnContent.Files? = nil,
        branch: String? = "main",
        message: String = "On main: !!Espalier<main>",
        filter: String = "",
        selected: Int? = 0
    ) -> StashColumnContent {
        let rows = StashColumnContent.files(Self.files, filter: filter)
        return StashColumnContent(
            sha: "a1b2c3d",
            branch: branch,
            message: message,
            files: files ?? .loaded(rows, total: Self.files.count),
            canRestore: true,
            canApply: true,
            canDiscard: true,
            isBusy: false,
            filter: filter,
            selectedFileID: selected.flatMap { rows.indices.contains($0) ? rows[$0].id : nil }
        )
    }

    private func column(_ content: StashColumnContent) -> some View {
        StashColumn(content: content)
            .frame(width: Metrics.Column.stashColumn.ideal, height: 340)
    }

    @Test("the place's column: a branch's stash, at the widest, one made outside Espalier, failed, and no matches")
    func columns() {
        capture(column(content()), named: "column", area: area)
        capture(column(content(branch: nil, message: "On main: fix the login redirect loop")), named: "column-outside", area: area)
        capture(
            StashColumn(content: content()).frame(width: Metrics.Column.stashColumn.max, height: 340),
            named: "column-widest",
            area: area
        )
        capture(column(content(files: .failed(title: "Error", message: "fatal: bad object a1b2c3d"))), named: "column-failed", area: area)
        capture(column(content(filter: "nothing", selected: nil)), named: "column-noMatches", area: area)
    }

    @Test("the section's rows: every entry newest first, with counts, and one selected")
    func rows() {
        let rows = [
            StashRowContent(sha: "1", branch: "main", message: "On main: !!Espalier<main>", fileCount: 4),
            StashRowContent(sha: "2", branch: nil, message: "WIP on main: 9fceb02 Cache forecasts for 10 minutes", fileCount: 2),
            StashRowContent(sha: "3", branch: "feature/sign-in", message: "On feature/sign-in: !!GitHub_Desktop<feature/sign-in>", fileCount: 12),
            StashRowContent(sha: "4", branch: nil, message: "On main: fix the login redirect loop", fileCount: 1),
            StashRowContent(sha: "5", branch: "main", message: "On main: !!Espalier<main>", fileCount: nil),
        ]
        let list = List {
            Section {
                ForEach(rows) { row in
                    StashRow(content: row)
                        .sidebarRow(.stash(sha: row.sha))
                }
            } header: {
                SidebarSectionHeader("Stashes")
            }
        }
        .sidebarListStyle()
        // A selected stash: the neutral wash, its name medium, its symbol in
        // the accent.
        .environment(\.sidebarSelection, .stash(sha: "3"))
        .frame(width: Metrics.Column.sidebar.ideal, height: 190)
        capture(list, named: "rows", area: area)
    }

    @Test("the Changes list's Stashed Changes row: one stash, and several")
    func stashedChangesRow() {
        let rows = VStack(spacing: 0) {
            StashedChangesRow(count: 1) {}
            Hairline()
            StashedChangesRow(count: 3) {}
        }
        .frame(width: Metrics.Column.changesFileList.ideal)
        .background(Color(espalier: Palette.background))
        capture(rows, named: "stashedChangesRow", area: area)
    }

    @Test("the place on a real stash: its files and the selected file's diff, searched, and matching nothing")
    func place() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await StashCaptureRepository.make()
            let entry = try fixture.entry("master")
            fixture.repository.stash.show(entry)
            await fixture.settle()
            await capturePlace(fixture, entry, named: "place")
            // The search, typed while good-file is selected, hides it:
            // notes.txt is selected, with its diff.
            await capturePlace(fixture, entry, named: "place-searched", typing: "notes")
            // No file matches: none is selected, and no diff shows.
            fixture.context.state.searchText = "zzz"
            await capturePlace(fixture, entry, named: "place-noMatches")
            await fixture.settle()
        }
    }

    /// Captures `entry` in the window's environment, once its files and the
    /// selected file's diff have loaded; with `typing`, once that's typed in
    /// the toolbar's search after the place shows, and what follows has
    /// loaded.
    private func capturePlace(_ fixture: StashCaptureRepository, _ entry: StashEntry, named name: String, typing: String? = nil) async {
        await LoadedCapture.capture(
            StashScreen(repository: fixture.repository, sha: entry.stashSha).windowEnvironment(fixture.context),
            named: name,
            area: area,
            size: CGSize(width: 900, height: 360)
        ) { host in
            await fixture.settle()
            host.layoutSubtreeIfNeeded()
            await LoadedCapture.diffDocumentShown(in: host)
            if let typing {
                fixture.context.state.searchText = typing
                // The list shows the one file matching.
                await waitUntilRunLoopIdle {
                    host.captureDescendants(ChangesTableView.self).first?.numberOfRows == 1
                }
                await fixture.settle()
                host.layoutSubtreeIfNeeded()
                await LoadedCapture.diffDocumentShown(in: host)
            }
        }
    }
}

/// A repository on `master` with a stash on `master` (good-file edited,
/// notes.txt added) and one on `feature` (todo.txt added), selected, with a
/// window.
@MainActor
struct StashCaptureRepository {
    let harness: AppHarness
    let app: AppModel
    let repository: RepositoryModel
    let context: WindowContext

    static func make() async throws -> StashCaptureRepository {
        let local = try await setupTwoCommitRepo()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        let repository = try await harness.addAndSelect(local, to: app)
        let context = WindowContext(app: app)
        context.avatarLoader = MonogramAvatarLoader()
        let fixture = StashCaptureRepository(harness: harness, app: app, repository: repository, context: context)

        try harness.write("good-file", "is stashed\n", in: local)
        try harness.write("notes.txt", "notes\n", in: local)
        await fixture.refresh()
        try #require(try await repository.stash.stashAllChanges())
        try await runGit(["checkout", "-q", "-b", "feature"], local)
        try harness.write("todo.txt", "todo\n", in: local)
        await fixture.refresh()
        try #require(try await repository.stash.stashAllChanges())
        try await runGit(["checkout", "-q", "master"], local)
        await fixture.refresh()
        return fixture
    }

    func refresh() async {
        await repository.refresh(.full, reason: .user)
        await settle()
    }

    /// Waits for the app, the actions, and the stash's loads.
    func settle() async {
        await app.idle()
        await context.actions.idle()
        await repository.stash.loadsIdle()
        await app.idle()
    }

    /// The branch's newest stash.
    func entry(_ branch: String) throws -> StashEntry {
        try #require(repository.gitState.stashes.entries(onBranch: branch).first)
    }
}
