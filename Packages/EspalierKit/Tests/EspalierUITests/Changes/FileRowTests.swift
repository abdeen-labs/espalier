// The Changes list's rows: what each status, rename, and checkbox state
// shows, a conflicted file's state and buttons, a stash's rows without
// checkboxes, and what VoiceOver reads.

import AppKit
@testable import EspalierCore
import Foundation
import GitKit
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

    @Test("a conflicted file's row says what's left and offers its buttons to VoiceOver")
    func conflictCell() {
        let conflict = ConflictFileRowContent(
            path: "Sources/App/Loader.swift",
            state: .markers(conflicts: 2),
            status: "2 conflicts",
            oursLabel: "Use the modified file from main",
            theirsLabel: "Use the modified file from feature"
        )
        let content = FileRowContent(id: "1", path: "Sources/App/Loader.swift", status: .conflicted, inclusion: true, conflict: conflict)
        #expect(content.accessibilityLabel == "Loader.swift, Conflicted, in Sources/App, 2 conflicts")
        #expect(conflict.help == "2 conflicts. \(OperationPanelContent.hint)")
        let deleted = ConflictFileRowContent(path: "old.txt", state: .manual, status: "File does not exist on main.")
        #expect(deleted.help == "File does not exist on main. \(OperationPanelContent.hint)")
        #expect(ConflictFileRowContent(path: "a.txt", state: .resolved(isUndoable: false), status: "No conflicts remaining").help == "No conflicts remaining")

        var opened = 0
        var chosen: [ManualConflictResolution?] = []
        let actions = ConflictFileRowActions(
            editorName: "Xcode",
            isEditorAvailable: true,
            openInEditor: { opened += 1 },
            choose: { chosen.append($0) }
        )
        let cell = FileRowView(frame: CGRect(x: 0, y: 0, width: 320, height: Metrics.FileList.rowHeight))
        cell.configure(content, conflictActions: actions)
        let custom = cell.accessibilityCustomActions() ?? []
        #expect(custom.map(\.name) == ["Exclude", "Open in Xcode", "Use the modified file from main", "Use the modified file from feature"])
        _ = custom[1].handler?()
        _ = custom[3].handler?()
        #expect(opened == 1)
        #expect(chosen == [.theirs])

        // Picked, it offers Undo.
        let picked = ConflictFileRowContent(path: "logo.png", state: .resolved(isUndoable: true), status: "Using the modified file from main")
        cell.configure(FileRowContent(id: "2", path: "logo.png", status: .conflicted, inclusion: true, conflict: picked), conflictActions: actions)
        let undo = cell.accessibilityCustomActions() ?? []
        #expect(undo.map(\.name) == ["Exclude", "Undo"])
        _ = undo[1].handler?()
        #expect(chosen == [.theirs, nil])
    }

    @Test("a stash's row has no checkbox: nothing to include, and VoiceOver hears no inclusion")
    func readOnlyCell() {
        let file = CommittedFileChange(path: "Sources/App/Loader.swift", status: .modified(), commitish: "a1b2c3d", parentCommitish: "a1b2c3d^")
        let content = FileRowContent(readOnly: file)
        #expect(!content.showsCheckbox)
        let cell = FileRowView(frame: CGRect(x: 0, y: 0, width: 320, height: Metrics.FileList.rowHeight))
        cell.configure(content)
        #expect(cell.checkbox.isHidden)
        #expect(cell.textField?.stringValue == "Loader.swift")
        #expect(cell.accessibilityValue() == nil)
        #expect(cell.accessibilityCustomActions()?.isEmpty ?? true)
    }
}
