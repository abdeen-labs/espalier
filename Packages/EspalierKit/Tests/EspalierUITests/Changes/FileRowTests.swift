// The Changes list's rows: the name and folder each shows, when line counts
// show, the checkbox, a conflicted file's buttons for VoiceOver, and a
// stash's rows without checkboxes.

import AppKit
@testable import EspalierCore
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("File rows") @MainActor
struct FileRowTests {
    @Test("a row shows the name, its folder, and the path as its tooltip")
    func content() {
        let modified = FileRowContent(id: "1", path: "Sources/App/RepositoryLoader.swift", status: .modified, inclusion: true)
        #expect(modified.fileName == "RepositoryLoader.swift")
        #expect(modified.directory == "Sources/App")
        #expect(modified.renameSource == nil)
        #expect(modified.help == "Sources/App/RepositoryLoader.swift")

        let root = FileRowContent(id: "2", path: "README.md", status: .new, inclusion: false)
        #expect(root.directory.isEmpty)
    }

    @Test("a row shows no line counts for a file without counts or changes")
    func lineCounts() {
        func row(_ added: Int?, _ deleted: Int?) -> FileRowContent {
            let count = added.map { FileLineCount(added: $0, deleted: deleted) }
            return FileRowContent(id: "1", path: "Sources/App/Loader.swift", status: .modified, inclusion: true, lineCount: count)
        }
        // A rename without changes, a binary file, and a file not counted
        // yet show nothing.
        #expect(row(0, 0).countsText == nil)
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

    @Test("a row's cell shows the file's name, and its VoiceOver action includes the file")
    func cell() {
        let cell = FileRowView(frame: CGRect(x: 0, y: 0, width: 300, height: Metrics.FileList.rowHeight))
        var received: [Bool] = []
        cell.onIncludeChanged = { received.append($0) }
        cell.configure(FileRowContent(id: "1", path: "Sources/App/Loader.swift", oldPath: "Sources/App/OldLoader.swift", status: .renamed, inclusion: nil))
        #expect(cell.textField?.stringValue == "Loader.swift")
        let action = cell.accessibilityCustomActions()?.first
        _ = action?.handler?()
        #expect(received == [true])
    }

    @Test("a conflicted file's row offers its buttons to VoiceOver")
    func conflictCell() {
        let conflict = ConflictFileRowContent(
            path: "Sources/App/Loader.swift",
            state: .markers(conflicts: 2),
            status: "2 conflicts",
            oursLabel: "Use the modified file from main",
            theirsLabel: "Use the modified file from feature"
        )
        let content = FileRowContent(id: "1", path: "Sources/App/Loader.swift", status: .conflicted, inclusion: true, conflict: conflict)

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
        _ = custom[1].handler?()
        _ = custom[3].handler?()
        #expect(opened == 1)
        #expect(chosen == [.theirs])

        // Picked, it offers Undo.
        let picked = ConflictFileRowContent(path: "logo.png", state: .resolved(isUndoable: true), status: "Using the modified file from main")
        cell.configure(FileRowContent(id: "2", path: "logo.png", status: .conflicted, inclusion: true, conflict: picked), conflictActions: actions)
        let undo = cell.accessibilityCustomActions() ?? []
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
