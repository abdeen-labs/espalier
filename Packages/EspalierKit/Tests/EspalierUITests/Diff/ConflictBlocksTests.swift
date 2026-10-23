// A conflicted file drawn as blocks in the diff table: a header atop each
// side's block, its lines in that side, the markers left out, the file's
// line numbers, stray markers kept as lines; and a header's button, clicked,
// asks for its side of its conflict once, with the file as the table shows
// it, while the buttons wait until the file shows again (or the choice
// fails). A press that leaves the button asks for nothing, and the common
// ancestor's header has no button.

import AppKit
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// A choice the table asked for.
private struct Choice: Equatable, Sendable {
    let conflict: Int
    let side: ManualConflictResolution
    let file: ConflictedFileText
}

/// The choices the table's buttons asked for.
@MainActor
private final class ChoiceRecorder {
    var choices: [Choice] = []
}

@Suite("Conflict blocks", .hangGuard(minutes: 5)) @MainActor
struct ConflictBlocksTests {
    /// Two conflicts, the second with the common ancestor's lines.
    private let text = "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\nmid\n<<<<<<< HEAD\nours2\n||||||| base\nbase2\n=======\ntheirs2\n>>>>>>> b\nz\n"
    private let markers = [2, 4, 6, 8, 10, 12, 14]

    private var file: ConflictedFileText {
        ConflictedFileText(Data(text.utf8), markerLines: markers)
    }

    private func document(_ file: ConflictedFileText) -> DiffDocument {
        DiffDocument(input: DiffDocumentInput(hunks: [], maxLineNumber: 0, isSplit: true, conflictFile: file))
    }

    /// Each row: a header ("#"), or its line's content.
    private func texts(_ document: DiffDocument) -> [String] {
        document.rows.map { row in
            row.kind == .conflictHeader ? "#" : document.lines[Int(row.after)].content
        }
    }

    @Test("a header atop each side's block, its lines in that side, the markers left out, the file's line numbers")
    func rows() {
        let document = document(file)
        #expect(document.isWorkingFile)
        #expect(!document.isSplit)
        #expect(texts(document) == ["a", "#", "ours", "#", "theirs", "mid", "#", "ours2", "#", "base2", "#", "theirs2", "z"])
        #expect(document.conflictHeaders.map(\.side) == [.ours, .theirs, .ours, .base, .theirs])
        #expect(document.conflictHeaders.map(\.conflict) == [0, 0, 1, 1, 1])
        #expect(document.conflictHeaders.allSatisfy { document.rows[$0.row].kind == .conflictHeader })
        #expect(document.conflictMarkerRows == [document.conflictHeaders[0].row, document.conflictHeaders[2].row])
        let lines = document.rows.filter { $0.kind != .conflictHeader }.map { document.lines[Int($0.after)] }
        #expect(lines.map(\.newNumber) == [1, 3, 5, 7, 9, 11, 13, 15])
        #expect(lines.map(\.conflict) == [nil, .ours, .theirs, nil, .ours, .base, .theirs, nil])
        // The line cursor skips the headers.
        #expect(document.cursorRow(from: 1, forward: true) == 2)
    }

    @Test("markers that make no whole conflict stay as lines, as markers")
    func strayMarkers() {
        let file = ConflictedFileText(
            Data("<<<<<<< x\na\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\n".utf8),
            markerLines: [1, 3, 5, 7]
        )
        let document = document(file)
        #expect(texts(document) == ["<<<<<<< x", "a", "#", "ours", "#", "theirs"])
        #expect(document.lines.map(\.conflict) == [.marker, nil, .ours, .theirs])
    }

    // MARK: The buttons

    private func blocks(_ file: ConflictedFileText, buttons: Bool = true) -> ConflictBlocks {
        ConflictBlocks(
            file: file,
            ours: ConflictBlocks.Side(name: "feature", color: .systemBlue, buttonTitle: buttons ? "Use feature's Version" : nil),
            theirs: ConflictBlocks.Side(name: "main", color: .systemTeal, buttonTitle: buttons ? "Use main's Version" : nil)
        )
    }

    private func content(_ file: ConflictedFileText, buttons: Bool = true) -> DiffTableContent {
        DiffTableContent(
            fileID: "a",
            diff: TextDiff(text: "", hunks: [], lineEndingsChange: nil, maxLineNumber: 0, hasHiddenBidiChars: false),
            conflicts: blocks(file, buttons: buttons)
        )
    }

    /// A table in a window, 600 by 400, showing `content`, whose buttons'
    /// choices `recorder` gets, answering `answer`.
    private func makeTable(
        _ content: DiffTableContent,
        answer: Bool = true,
        recorder: ChoiceRecorder = ChoiceRecorder()
    ) async -> (DiffTableController, NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let controller = DiffTableController()
        window.contentView = controller.scrollView
        controller.scrollView.layoutSubtreeIfNeeded()
        var actions = DiffTableActions()
        actions.chooseConflictSide = { [recorder] file, conflict, side in
            recorder.choices.append(Choice(conflict: conflict, side: side, file: file))
            return answer
        }
        controller.actions = actions
        controller.apply(content)
        await controller.documentIdle()
        return (controller, window)
    }

    /// The middle of header `index`'s button.
    private func buttonPoint(_ controller: DiffTableController, header index: Int) throws -> CGPoint {
        let header = controller.document.conflictHeaders[index]
        let rect = controller.tableView.rect(ofRow: header.row)
        let button = try #require(controller.conflictButtonRect(ofRow: header.row, rowHeight: rect.height))
        return CGPoint(x: button.midX + controller.textScrollX, y: rect.minY + button.midY)
    }

    @Test("a header's button asks for its side of its conflict once, and the buttons wait until the file shows again")
    func click() async throws {
        let recorder = ChoiceRecorder()
        let (controller, window) = await makeTable(content(file), recorder: recorder)
        let point = try buttonPoint(controller, header: 4)
        #expect(controller.hit(at: point) == .conflictButton(header: 4))

        let drag = controller.mouseDown(at: point, clickCount: 1, extendsSelection: false)
        #expect(drag == .conflictButton(4))
        controller.mouseUp(drag: drag)
        await controller.conflictChoiceIdle()
        #expect(recorder.choices == [Choice(conflict: 1, side: .theirs, file: file)])

        // Waiting: another click does nothing.
        #expect(controller.pendingConflictChoice == 4)
        let again = controller.mouseDown(at: try buttonPoint(controller, header: 0), clickCount: 1, extendsSelection: false)
        #expect(again == .none)
        #expect(recorder.choices.count == 1)

        // The file shows again, with one conflict left: the buttons take
        // clicks.
        let next = ConflictedFileText(Data("a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\nmid\ntheirs2\nz\n".utf8), markerLines: [2, 4, 6])
        controller.apply(content(next))
        await controller.documentIdle()
        #expect(controller.pendingConflictChoice == nil)
        let first = try buttonPoint(controller, header: 0)
        controller.mouseUp(drag: controller.mouseDown(at: first, clickCount: 1, extendsSelection: false))
        await controller.conflictChoiceIdle()
        #expect(recorder.choices.last == Choice(conflict: 0, side: .ours, file: next))
        withExtendedLifetime(window) {}
    }

    @Test("a failed choice lets the buttons take clicks again")
    func failedChoice() async throws {
        let recorder = ChoiceRecorder()
        let (controller, window) = await makeTable(content(file), answer: false, recorder: recorder)
        controller.chooseConflictSide(header: 0)
        await controller.conflictChoiceIdle()
        #expect(recorder.choices.count == 1)
        #expect(controller.pendingConflictChoice == nil)
        #expect(controller.canChooseConflictSide(header: 1))
        withExtendedLifetime(window) {}
    }

    @Test("a press that leaves the button before the mouse goes up asks for nothing")
    func pressLeaves() async throws {
        let recorder = ChoiceRecorder()
        let (controller, window) = await makeTable(content(file), recorder: recorder)
        let point = try buttonPoint(controller, header: 1)
        let drag = controller.mouseDown(at: point, clickCount: 1, extendsSelection: false)
        #expect(controller.pressedConflictButton == 1)
        let outside = CGPoint(x: 4, y: point.y)
        controller.mouseDragged(to: outside, drag: drag)
        #expect(controller.pressedConflictButton == nil)
        controller.mouseUp(drag: drag)
        await controller.conflictChoiceIdle()
        #expect(recorder.choices.isEmpty)
        #expect(controller.pendingConflictChoice == nil)
        withExtendedLifetime(window) {}
    }

    @Test("the common ancestor's header has no button, nor do headers while a side is chosen for the whole file")
    func noButton() async throws {
        let (controller, window) = await makeTable(content(file))
        let base = controller.document.conflictHeaders[3]
        #expect(base.side == .base)
        #expect(controller.conflictButtonRect(ofRow: base.row, rowHeight: 30) == nil)
        #expect(!controller.canChooseConflictSide(header: 3))

        controller.apply(content(file, buttons: false))
        await controller.documentIdle()
        let ours = controller.document.conflictHeaders[0]
        #expect(controller.conflictButtonRect(ofRow: ours.row, rowHeight: 30) == nil)
        #expect(!controller.canChooseConflictSide(header: 0))
        withExtendedLifetime(window) {}
    }
}
