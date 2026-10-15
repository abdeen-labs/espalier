// The Stashes section's rows and the stash's place, one capture per layout:
// the place's column (the current branch's stash, failed, no matches), the
// section's rows, and the place on a real stash with the selected file's
// diff, with the search typed hiding the selected file, and with a search
// matching no file.

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

    private func content(files: StashColumnContent.Files? = nil, filter: String = "", selected: Int? = 0) -> StashColumnContent {
        let rows = StashColumnContent.files(Self.files, filter: filter)
        return StashColumnContent(
            branch: "main",
            files: files ?? .loaded(rows, total: Self.files.count),
            isCurrentBranch: true,
            canRestore: true,
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

    @Test("the place's column: the current branch's stash, failed, and no matches")
    func columns() {
        capture(column(content()), named: "column", area: area)
        capture(column(content(files: .failed(title: "Error", message: "fatal: bad object a1b2c3d"))), named: "column-failed", area: area)
        capture(column(content(filter: "nothing", selected: nil)), named: "column-noMatches", area: area)
    }

    @Test("the section's rows: the current branch's stash first, with counts, and one selected")
    func rows() {
        let rows = StashRowContent.rows(
            branches: ["main", "feature/sign-in", "fix/crash"],
            currentBranch: "main",
            fileCount: { ["main": 4, "feature/sign-in": 12][$0] },
            filter: ""
        )
        let list = List {
            Section {
                ForEach(rows) { row in
                    StashRow(content: row)
                        .sidebarRow(.stash(branch: row.branch))
                }
            } header: {
                SidebarSectionHeader("Stashes")
            }
        }
        .sidebarListStyle()
        // A selected stash: the neutral wash, its name medium, its symbol in
        // the accent.
        .environment(\.sidebarSelection, .stash(branch: "feature/sign-in"))
        .frame(width: Metrics.Column.sidebar.ideal, height: 130)
        capture(list, named: "rows", area: area)
    }

    @Test("the place on a real stash: its files and the selected file's diff, searched, and matching nothing")
    func place() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await StashCaptureRepository.make()
            fixture.repository.stash.show(try fixture.entry("master"))
            await fixture.settle()
            await capturePlace(fixture, named: "place")
            // The search, typed while good-file is selected, hides it:
            // notes.txt is selected, with its diff.
            await capturePlace(fixture, named: "place-searched", typing: "notes")
            // No file matches: none is selected, and no diff shows.
            fixture.context.state.searchText = "zzz"
            await capturePlace(fixture, named: "place-noMatches")
            await fixture.settle()
        }
    }

    /// Captures master's stash in the window's environment, once its files
    /// and the selected file's diff have loaded; with `typing`, once that's
    /// typed in the toolbar's search after the place shows, and what follows
    /// has loaded.
    private func capturePlace(_ fixture: StashCaptureRepository, named name: String, typing: String? = nil) async {
        await LoadedCapture.capture(
            StashScreen(repository: fixture.repository, branch: "master").windowEnvironment(fixture.context),
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

    func entry(_ branch: String) throws -> StashEntry {
        try #require(repository.gitState.stashes.entriesByBranch[branch])
    }
}
