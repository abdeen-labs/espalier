// The Changes place at the window's size, on real repositories: the files
// with README.md's diff (light and dark), README.md partly included,
// filtered to nothing, no changes with Suggestions and a stash on the
// branch, and a merge's conflicts with the operation panel and the merge's
// commit form (light and dark).

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
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

    @Test("files with the diff, a file partly included, filtered, no changes")
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
            changes.setIncluded([readme.id], true)
            await fixture.settle()

            // The filter hides every file, LICENSE excluded.
            changes.setIncluded([try fixture.file("LICENSE").id], false)
            changes.select(fileIDs: [])
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

    @Test("a merge's conflicts in the list, its panel, and the merge's commit form")
    func conflicts() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await ChangesCaptureRepository.make(try await setupConflictedRepo())
            await capturePlace(fixture, named: "place-conflicts")
            await fixture.app.idle()
        }
    }

    /// Captures the place in the window's environment, once what it loads
    /// as it shows has arrived and the diff's rows are built.
    private func capturePlace(_ fixture: ChangesCaptureRepository, named name: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        await LoadedCapture.capture(
            ChangesScreen(repository: fixture.repository).windowEnvironment(fixture.context),
            named: name,
            area: area,
            size: size,
            loaded: { host in
                await fixture.settle()
                host.layoutSubtreeIfNeeded()
                await LoadedCapture.diffDocumentShown(in: host)
            },
            sourceLocation: sourceLocation
        )
    }
}
