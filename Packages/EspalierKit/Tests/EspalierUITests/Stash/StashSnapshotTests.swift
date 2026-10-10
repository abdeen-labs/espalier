// The Stashes section's rows and the stash's place, one image per layout:
// the column and the place in light and dark, the rest in light. The
// column's other states differ only in words or a disabled button
// (StashTests).

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Stash snapshots", .offline, .hangGuard(minutes: 5)) @MainActor
struct StashSnapshotTests {
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
        assertSnapshot(column(content()), named: "column", area: area)
        assertSnapshot(
            column(content(files: .failed(title: "Error", message: "fatal: bad object a1b2c3d"))),
            named: "column-failed",
            area: area,
            appearances: [.light]
        )
        assertSnapshot(column(content(filter: "nothing", selected: nil)), named: "column-noMatches", area: area, appearances: [.light])
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
        assertSnapshot(list, named: "rows", area: area, appearances: [.light])
    }

    @Test("the place on a real stash: its files and the selected file's diff")
    func place() async throws {
        let fixture = try await StashFixture.make()
        fixture.context.avatarLoader = MonogramAvatarLoader()
        let repository = fixture.repository
        let entry = try fixture.entry("master")
        repository.stash.show(entry)
        await fixture.settle()
        let files = try #require(repository.stash.files.value)
        let rows = StashColumnContent.files(files, filter: "")
        let content = StashColumnContent(
            branch: "master",
            files: .loaded(rows, total: files.count),
            isCurrentBranch: true,
            canRestore: true,
            canDiscard: true,
            isBusy: false,
            filter: "",
            selectedFileID: repository.stash.selectedFile?.id
        )
        let place = HStack(spacing: 0) {
            StashColumn(content: content)
                .frame(width: Metrics.Column.stashColumn.ideal)
            Divider()
            DiffContainer(repository.stash.diff, file: repository.stash.selectedFile.map(DiffFileInfo.init), context: .stash)
        }
        .environment(\.diffBuildsSynchronously, true)
        .windowEnvironment(fixture.context)
        assertSnapshot(place, named: "place", area: area, size: CGSize(width: 900, height: 360))
    }
}
