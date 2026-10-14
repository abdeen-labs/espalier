// The Changes list's rows: every status, inclusion, line counts, and the
// selection; and the row a context menu acts on, with the accent ring,
// unselected and selected.

import AppKit
@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Changes rows", .captures) @MainActor
struct ChangesFileRowCaptures {
    private let area = "Changes"

    @Test("every status, inclusion, line counts, and the selection")
    func rows() {
        func file(_ path: String, _ status: AppFileStatus, _ selection: DiffSelectionType = .all) -> WorkingDirectoryFileChange {
            var lines = DiffSelection.fromInitialSelection(selection == .none ? .none : .all)
            if selection == .partial {
                lines = lines.withSelectableLines([1, 2]).withLineSelection(2, selected: false)
            }
            return WorkingDirectoryFileChange(path: path, status: status, selection: lines)
        }
        let submoduleHelp = "This submodule has uncommitted changes, so its change can't be committed here."
        let files = [
            file("Sources/App/RepositoryLoader.swift", .modified()),
            file("Sources/App/EmptyState.swift", .new(), .partial),
            file("Legacy.swift", .deleted(), .none),
            file("Sources/App/Loader.swift", .renamed(oldPath: "Sources/App/OldLoader.swift", renameIncludesModifications: true)),
            file("Sources/App/Copy.swift", .copied(oldPath: "Sources/Other/Original.swift", renameIncludesModifications: false)),
            file("notes.txt", .untracked()),
            file("Package.resolved", .conflicted(.conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 3, conflictCount: 1))),
            file("Vendor/Kit", .modified(submoduleStatus: SubmoduleStatus(commitChanged: false, modifiedChanges: true, untrackedChanges: false)), .none),
            file("Sources/Feature/AVeryLongFileNameThatGoesOnAndOn.swift", .modified()),
        ]
        let inclusion = { (file: WorkingDirectoryFileChange) -> FileInclusionState in
            let state = BenchmarkList.inclusion(file)
            switch file.status.kind {
            case .conflicted: return FileInclusionState(value: true, isEnabled: false, help: nil)
            case .modified where file.status.submoduleStatus != nil: return FileInclusionState(value: false, isEnabled: false, help: submoduleHelp)
            default: return state
            }
        }
        // Counts as the changes model loads them: none for the conflicted
        // file and the submodule, nothing shown for the unchanged rename.
        let counts: [Int: FileLineCount] = [
            0: FileLineCount(added: 10, deleted: 2),
            1: FileLineCount(added: 58, deleted: 0),
            2: FileLineCount(added: 0, deleted: 34),
            3: FileLineCount(added: 0, deleted: 0),
            4: FileLineCount(added: 12, deleted: 0),
            5: FileLineCount(added: 6, deleted: 0),
            8: FileLineCount(added: 1_204, deleted: 317),
        ]
        let lineCounts = Dictionary(uniqueKeysWithValues: counts.map { (ExactString(files[$0.key].id), $0.value) })
        let table = FileTable(files: .changes(files), selectedIDs: [files[1].id], inclusion: inclusion, lineCounts: lineCounts)
        capture(table, named: "rows", area: area, size: CGSize(width: Metrics.Column.changesFileList.ideal, height: 290))
    }

    @Test("the row a context menu acts on shows the accent ring, unselected and selected")
    func contextTarget() {
        let files = [
            WorkingDirectoryFileChange(path: "Sources/App/RepositoryLoader.swift", status: .modified(), selection: .fromInitialSelection(.all)),
            WorkingDirectoryFileChange(path: "README.md", status: .modified(), selection: .fromInitialSelection(.all)),
        ]
        // The tables' coordinators, which they hold weakly.
        var coordinators: [FileTableCoordinator] = []
        for (name, selection) in [("contextTarget", [String]()), ("contextTargetSelected", [files[0].id])] {
            capture({
                let table = FileTable(files: .changes(files), selectedIDs: selection, inclusion: BenchmarkList.inclusion)
                let coordinator = table.makeCoordinator()
                coordinators.append(coordinator)
                let scrollView = FileTable.makeScrollView(coordinator: coordinator, table: table)
                _ = (scrollView.documentView as? ChangesTableView)?.contextMenuTarget.mark(0)
                return scrollView
            }, named: name, area: area, size: CGSize(width: Metrics.Column.changesFileList.ideal, height: 76))
        }
        withExtendedLifetime(coordinators) {}
    }
}
