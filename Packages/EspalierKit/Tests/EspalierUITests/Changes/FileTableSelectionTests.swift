// The file table keeps the model's selection when a filter takes rows away:
// the rows it drops aren't reported back as a selection.

import AppKit
import EspalierCore
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("File table selection") @MainActor
struct FileTableSelectionTests {
    /// The selections the table reported.
    private final class Reports {
        var selections: [[String]] = []
    }

    private static func files(_ paths: [String]) -> FileTableFiles {
        .readOnly(paths.map { CommittedFileChange(path: $0, status: .modified(), commitish: "a1b2c3d", parentCommitish: "a1b2c3d^") })
    }

    @Test("a filter dropping the selected last row reports no selection, and the table selects the model's file")
    func filterDropsSelectedRow() throws {
        let reports = Reports()
        let all = Self.files(["a.txt", "b.txt", "c.txt"])
        var table = FileTable(
            files: all,
            selectedIDs: [all.id(at: 2)],
            actions: FileTableActions(select: { reports.selections.append($0) })
        )
        let coordinator = FileTableCoordinator(table)
        _ = FileTable.makeScrollView(coordinator: coordinator, table: table)
        let tableView = try #require(coordinator.tableView)
        #expect(tableView.selectedRowIndexes == [2])

        // The filter lists a.txt alone, and the model selects it.
        let filtered = Self.files(["a.txt"])
        table.files = filtered
        table.selectedIDs = [filtered.id(at: 0)]
        table.scope = FileTableScope(filter: FileListFilter(text: "a"))
        coordinator.update(table)
        #expect(reports.selections.isEmpty)
        #expect(tableView.selectedRowIndexes == [0])
    }
}
