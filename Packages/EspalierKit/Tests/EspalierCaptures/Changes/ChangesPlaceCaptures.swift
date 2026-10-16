// The Changes place at the window's size, on real repositories: the files
// with README.md's diff (light and dark), README.md partly included (also
// under Included in Commit), the search typed hiding the selected file,
// filtered to nothing, no changes with Suggestions and a stash on the
// branch, a merge's conflicts with the operation panel and the merge's
// commit form, and a rebase's conflicts with the panel and the conflicted
// file's band (light and dark).

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Changes place", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct ChangesPlaceCaptures {
    private let area = "Changes"
    /// The place at the window's size.
    private let size = CGSize(width: 960, height: 620)

    @Test("files with the diff, a file partly included and under Included in Commit, searched, filtered, no changes")
    func place() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await ChangesCaptureRepository.make(try await ChangesCaptureRepository.withChanges())
            let changes = fixture.repository.changes

            let readme = try fixture.file("README.md")
            changes.select(fileIDs: [readme.id])
            await fixture.settle()
            await capturePlace(fixture, named: "place-files")

            // Gutter staging (the diff through the changes model): the last
            // added line left out, so the row's checkbox is mixed.
            try #require(changes.canSelectLines)
            let selection = try #require(changes.diffSelection)
            changes.setLineSelection(selection.withLineSelection(4, selected: false), forFile: readme.id)
            await fixture.settle()
            await capturePlace(fixture, named: "place-partial")
            // Included in Commit keeps the partly included file and hides
            // LICENSE, excluded.
            changes.setIncluded([try fixture.file("LICENSE").id], false)
            changes.filter.includedInCommit = true
            await fixture.settle()
            await capturePlace(fixture, named: "place-partial-included")
            changes.filter = FileListFilter()
            changes.setIncluded([readme.id], true)
            await fixture.settle()

            // The search, typed while the last file is selected, hides it:
            // the file it shows is selected, with its diff.
            changes.select(fileIDs: [try fixture.file("Sources/App/Loader.swift").id])
            await fixture.settle()
            await capturePlace(fixture, named: "place-searched", typing: "readme")
            fixture.context.state.searchText = ""
            changes.filter = FileListFilter()
            await fixture.settle()

            // The filter hides every file, the selected one too, LICENSE
            // excluded.
            changes.setIncluded([try fixture.file("LICENSE").id], false)
            changes.filter.newFiles = true
            changes.filter.deletedFiles = true
            await fixture.settle()
            await capturePlace(fixture, named: "place-no-matches")
            changes.filter = FileListFilter()

            // Nothing left: Suggestions, with a stash on the branch.
            try await fixture.repository.stash.stashAllChanges()
            await fixture.settle()
            await capturePlace(fixture, named: "place-no-changes")
            await fixture.app.idle()
        }
    }

    @Test("a merge's conflicts in the list, its panel, the conflicted file's band, and the merge's commit form")
    func conflicts() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await ChangesCaptureRepository.make(try await setupConflictedRepo())
            fixture.repository.changes.select(fileIDs: [try fixture.file("foo").id])
            await fixture.settle()
            await capturePlace(fixture, named: "place-conflicts")
            await fixture.app.idle()
        }
    }

    @Test("a rebase's conflicts: the panel, and the conflicted file's band")
    func rebaseConflicts() async throws {
        try await withIsolatedGitConfig { _ in
            let local = try setupEmptyRepositoryDefaultMain()
            let loader = URL(exactFilePath: POSIXPath.join(local.path, "Loader.swift"))
            try Data("let retries = 1\n".utf8).write(to: loader)
            try await runGit(["add", "Loader.swift"], local)
            try await runGit(["commit", "-m", "Add the loader"], local)
            try await runGit(["branch", "feature/login"], local)
            try Data("let retries = 3\n".utf8).write(to: loader)
            try await runGit(["commit", "-am", "Retry three times"], local)
            try await runGit(["checkout", "feature/login"], local)
            try Data("let retries = 5\n".utf8).write(to: loader)
            try await runGit(["commit", "-am", "Retry five times"], local)
            _ = try await Dugite.exec(["rebase", "main"], local.path)
            let fixture = try await ChangesCaptureRepository.make(local)
            fixture.repository.changes.select(fileIDs: [try fixture.file("Loader.swift").id])
            await fixture.settle()
            await capturePlace(fixture, named: "place-conflicts-rebase")
            await fixture.app.idle()
        }
    }

    /// Captures the place in the window's environment, once what it loads
    /// as it shows has arrived and the diff's rows are built; with `typing`,
    /// once that's typed in the toolbar's search after the place shows, and
    /// what follows has loaded.
    private func capturePlace(
        _ fixture: ChangesCaptureRepository,
        named name: String,
        typing: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await LoadedCapture.capture(
            ChangesScreen(repository: fixture.repository).windowEnvironment(fixture.context),
            named: name,
            area: area,
            size: size,
            loaded: { host in
                await fixture.settle()
                host.layoutSubtreeIfNeeded()
                await LoadedCapture.diffDocumentShown(in: host)
                if let typing {
                    fixture.context.state.searchText = typing
                    await waitUntilRunLoopIdle {
                        fixture.repository.changes.filter.text == typing
                    }
                    await fixture.settle()
                    host.layoutSubtreeIfNeeded()
                    await LoadedCapture.diffDocumentShown(in: host)
                }
            },
            sourceLocation: sourceLocation
        )
    }
}
