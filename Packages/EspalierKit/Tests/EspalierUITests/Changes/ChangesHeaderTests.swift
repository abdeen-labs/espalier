// The Changes header's content from repositories: the include-all checkbox,
// and the filter options and their counts.

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
        #expect(content.systemImage == "line.3.horizontal.decrease.circle.fill")
        let options: [WritableKeyPath<FileListFilter, Bool>] = [
            \.includedInCommit, \.excludedFromCommit, \.newFiles, \.modifiedFiles, \.deletedFiles,
        ]
        #expect(content.options.map { $0.keyPath as WritableKeyPath<FileListFilter, Bool> } == options)
    }

    @Test("the header follows the repository: the checkbox and the filter")
    func fromRepository() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithChanges()
            let fixture = try await ChangesWindowFixture.make(local)
            let changes = fixture.repository.changes
            let format = defaultNumberFormat

            var header = ChangesHeaderContent.make(fixture.repository, numberFormat: format)
            #expect(header.includeAll == true)
            #expect(header.isIncludeAllEnabled)

            changes.setIncluded([try fixture.file("README.md").id], false)
            header = ChangesHeaderContent.make(fixture.repository, numberFormat: format)
            #expect(header.includeAll == nil)

            // The toolbar's text filters; the checkbox covers what's shown.
            changes.filter.text = "loader"
            header = ChangesHeaderContent.make(fixture.repository, numberFormat: format)
            #expect(header.includeAll == true)
            #expect(header.filter.filter.text == "loader")

            changes.setVisibleFilesIncluded(false)
            #expect(try fixture.file("Sources/App/Loader.swift").selection.getSelectionType() == .none)
            #expect(try fixture.file("LICENSE").selection.getSelectionType() == .all)
            await fixture.app.idle()
        }
    }
}
