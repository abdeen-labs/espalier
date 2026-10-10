// The Changes list's rows: what each status, rename, and checkbox state
// shows, what VoiceOver reads, and snapshots of every status, inclusion,
// and the selection, light and dark.

import AppKit
@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("File rows") @MainActor
struct FileRowTests {
    @Test("a row shows the name, its folder, a rename's source, and the status")
    func content() {
        let modified = FileRowContent(id: "1", path: "Sources/App/RepositoryLoader.swift", status: .modified, inclusion: true)
        #expect(modified.fileName == "RepositoryLoader.swift")
        #expect(modified.directory == "Sources/App")
        #expect(modified.renameSource == nil)
        #expect(modified.help == "Sources/App/RepositoryLoader.swift")
        #expect(modified.accessibilityLabel == "RepositoryLoader.swift, Modified, in Sources/App")
        #expect(modified.inclusionDescription == "Included")

        let root = FileRowContent(id: "2", path: "README.md", status: .new, inclusion: false)
        #expect(root.directory.isEmpty)
        #expect(root.accessibilityLabel == "README.md, New")
        #expect(root.inclusionDescription == "Not included")

        // A rename in the same folder names the old file; from another
        // folder, its whole path.
        let renamed = FileRowContent(id: "3", path: "Sources/App/Loader.swift", oldPath: "Sources/App/OldLoader.swift", status: .renamed, inclusion: nil)
        #expect(renamed.renameSource == "← OldLoader.swift")
        #expect(renamed.help == "Sources/App/OldLoader.swift → Sources/App/Loader.swift")
        #expect(renamed.inclusionDescription == "Partly included")
        let moved = FileRowContent(id: "4", path: "Loader.swift", oldPath: "Legacy/Loader.swift", status: .renamed, inclusion: true)
        #expect(moved.renameSource == "← Legacy/Loader.swift")
        #expect(moved.accessibilityLabel == "Loader.swift, Renamed, from Legacy/Loader.swift")
    }

    @Test("a row's line counts: zero counts left out, none for a file without counts or changes")
    func lineCounts() {
        func row(_ added: Int?, _ deleted: Int?) -> FileRowContent {
            let count = added.map { FileLineCount(added: $0, deleted: deleted) }
            return FileRowContent(id: "1", path: "Sources/App/Loader.swift", status: .modified, inclusion: true, lineCount: count)
        }
        #expect(row(10, 2).countsText == "+10 \u{2212}2")
        #expect(row(10, 2).accessibilityLabel == "Loader.swift, Modified, in Sources/App, 10 added lines, 2 removed lines")
        #expect(row(58, 0).countsText == "+58")
        #expect(row(0, 34).countsText == "\u{2212}34")
        #expect(row(1_204, 0).countsText == "+1,204")
        // A rename without changes, a binary file, and a file not counted
        // yet show nothing.
        #expect(row(0, 0).countsText == nil)
        #expect(row(0, 0).accessibilityLabel == "Loader.swift, Modified, in Sources/App")
        #expect(row(nil, nil).countsText == nil)
        #expect(FileRowContent(id: "1", path: "a.png", status: .modified, inclusion: true, lineCount: FileLineCount(added: nil, deleted: nil)).countsText == nil)
    }

    @Test("the checkbox includes all unless all is included")
    func checkboxToggle() {
        var received: [Bool] = []
        for value in [true, false, nil] as [Bool?] {
            let checkbox = InclusionCheckbox(value: value) { received.append($0) }
            let coordinator = checkbox.makeCoordinator()
            let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            button.allowsMixedState = true
            coordinator.toggle(button)
            // The box shows the model's state until the model changes.
            #expect(button.state == InclusionCheckbox.state(value))
        }
        #expect(received == [false, true, true])
    }

    @Test("a row's cell shows its content and reads to VoiceOver")
    func cell() {
        let cell = FileRowView(frame: CGRect(x: 0, y: 0, width: 300, height: Metrics.FileList.rowHeight))
        var received: [Bool] = []
        cell.onIncludeChanged = { received.append($0) }
        cell.configure(FileRowContent(id: "1", path: "Sources/App/Loader.swift", oldPath: "Sources/App/OldLoader.swift", status: .renamed, inclusion: nil))
        #expect(cell.textField?.stringValue == "Loader.swift")
        #expect(cell.accessibilityLabel() == "Loader.swift, Renamed, in Sources/App, from Sources/App/OldLoader.swift")
        #expect(cell.accessibilityValue() as? String == "Partly included")
        let action = cell.accessibilityCustomActions()?.first
        #expect(action?.name == "Include")
        _ = action?.handler?()
        #expect(received == [true])
    }

    @Test("rows snapshot: every status, inclusion, line counts, and the selection")
    func snapshots() {
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
            file("Package.resolved", .conflicted(.conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 3))),
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
        let table = FileTable(files: files, selectedIDs: [files[1].id], inclusion: inclusion, lineCounts: lineCounts)
        assertSnapshot(table, named: "rows", area: "Changes", size: CGSize(width: Metrics.Column.changesFileList.ideal, height: 290))
    }
}
