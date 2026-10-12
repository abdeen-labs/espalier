// The Changes header's content from repositories: its count line, the
// include-all checkbox, and the filter options' counts.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Changes header", .offline) @MainActor
struct ChangesHeaderTests {
    @Test("the count line counts the files, and the files shown while filtered")
    func titles() {
        let format = defaultNumberFormat
        #expect(ChangesHeaderContent.title(fileCount: 1, visibleCount: 1, numberFormat: format) == "1 changed file")
        #expect(ChangesHeaderContent.title(fileCount: 3, visibleCount: 3, numberFormat: format) == "3 changed files")
        #expect(ChangesHeaderContent.title(fileCount: 5, visibleCount: 2, numberFormat: format) == "2 of 5 changed files")
        #expect(ChangesHeaderContent.title(fileCount: 12_000, visibleCount: 1_500, numberFormat: format) == "1,500 of 12,000 changed files")
    }

    @Test("the filter options count the files shown")
    func filterCounts() {
        let files = [
            ModelFixtures.file("a.swift", status: .modified(), included: true),
            ModelFixtures.file("b.swift", status: .new(), included: false),
            ModelFixtures.file("c.swift", status: .untracked(), included: true),
            ModelFixtures.file("d.swift", status: .deleted(), included: false),
            ModelFixtures.file("e.swift", status: .renamed(oldPath: "x.swift", renameIncludesModifications: false), included: true),
        ]
        let content = FilterMenuContent(filter: FileListFilter(modifiedFiles: true), visibleFiles: files)
        #expect(content.includedCount == 3)
        #expect(content.excludedCount == 2)
        #expect(content.newCount == 2)
        #expect(content.modifiedCount == 1)
        #expect(content.deletedCount == 1)
        #expect(content.activeOptionCount == 1)
        #expect(content.help == "Filter Options (1 Applied)")
        #expect(content.systemImage == "line.3.horizontal.decrease.circle.fill")
        #expect(content.options.map(\.title) == [
            "Included in Commit (3)", "Excluded from Commit (2)", "New Files (2)", "Modified Files (1)", "Deleted Files (1)",
        ])
        #expect(FilterMenuContent().help == "Filter Options")
    }

    @Test("the header follows the repository: the checkbox, the count, and the filter")
    func fromRepository() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let changes = fixture.repository.changes
            let format = defaultNumberFormat

            var header = ChangesHeaderContent.make(fixture.repository, numberFormat: format)
            #expect(header.title == "3 changed files")
            #expect(header.included == "3 included")
            #expect(header.includeAll == true)
            #expect(header.isIncludeAllEnabled)

            changes.setIncluded([try fixture.file("README.md").id], false)
            header = ChangesHeaderContent.make(fixture.repository, numberFormat: format)
            #expect(header.includeAll == nil)
            #expect(header.included == "2 included")

            // The toolbar's text filters; the checkbox covers what's shown.
            changes.filter.text = "loader"
            header = ChangesHeaderContent.make(fixture.repository, numberFormat: format)
            #expect(header.title == "1 of 3 changed files")
            // What the commit includes, whatever the filter shows.
            #expect(header.included == "2 included")
            #expect(header.includeAll == true)
            #expect(header.filter.filter.text == "loader")

            changes.setVisibleFilesIncluded(false)
            #expect(try fixture.file("Sources/App/Loader.swift").selection.getSelectionType() == .none)
            #expect(try fixture.file("LICENSE").selection.getSelectionType() == .all)
            await fixture.app.idle()
        }
    }
}
