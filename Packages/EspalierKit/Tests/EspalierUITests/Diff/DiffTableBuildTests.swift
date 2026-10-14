// The diff table while a new document builds: the rows on screen keep the
// previous document's content, a file switch still starts the new file
// fresh when other updates land during its build, and staging waits for
// the new rows.

import AppKit
import EspalierCore
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// What the table's staging gestures asked for.
@MainActor
private final class StagingRecorder {
    /// The generations `setLines` and `toggleLines` were called with.
    var generations: [Int] = []

    var actions: StagingActions {
        StagingActions(
            setLines: { [weak self] _, _, generation in self?.generations.append(generation) },
            toggleLines: { [weak self] _, generation in self?.generations.append(generation) },
            discardTitle: { _, _ in "Discard" },
            discardLines: { [weak self] _, generation in self?.generations.append(generation) },
            showWhitespaceChanges: {}
        )
    }
}

@Suite("Diff table while a document builds", .hangGuard(minutes: 5)) @MainActor
struct DiffTableBuildTests {
    /// A new file's diff of `count` added lines starting with `prefix`.
    private func addedLines(_ prefix: String, _ count: Int) throws -> TextDiff {
        let lines = (1...count).map { "+\(prefix) line \($0)" }.joined(separator: "\n")
        let raw = try DiffParser().parse("""
        diff --git a/\(prefix).txt b/\(prefix).txt
        new file mode 100644
        index 0000000..1111111
        --- /dev/null
        +++ b/\(prefix).txt
        @@ -0,0 +1,\(count) @@
        \(lines)
        """)
        return TextDiff(
            text: raw.contents,
            hunks: raw.hunks,
            lineEndingsChange: nil,
            maxLineNumber: raw.maxLineNumber,
            hasHiddenBidiChars: raw.hasHiddenBidiChars
        )
    }

    /// Staging that can select every line, for the diff of `generation`.
    private func staging(_ generation: Int) -> StagingState {
        StagingState(
            selection: DiffSelection.fromInitialSelection(.all),
            canSelectLines: true,
            hidesWhitespace: false,
            canDiscard: true,
            diffGeneration: generation
        )
    }

    /// A table in a window, 600 by 300, showing `content`.
    private func makeTable(_ content: DiffTableContent) async -> (DiffTableController, NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let controller = DiffTableController()
        window.contentView = controller.scrollView
        controller.scrollView.layoutSubtreeIfNeeded()
        controller.apply(content)
        await controller.documentIdle()
        return (controller, window)
    }

    /// A point in `row` that hits as `matches` says, scanning the row from
    /// its left edge.
    private func point(in controller: DiffTableController, row: Int, where matches: (DiffHit) -> Bool) throws -> CGPoint {
        let y = controller.tableView.rect(ofRow: row).midY
        let x = try #require(stride(from: CGFloat(1), to: 300, by: 1).first { matches(controller.hit(at: CGPoint(x: $0, y: y))) })
        return CGPoint(x: x, y: y)
    }

    @Test("another file starts at the top with no selection when an update lands during its build")
    func fileSwitchDuringBuild() async throws {
        let (controller, window) = await makeTable(DiffTableContent(fileID: "a", diff: try addedLines("a", 200)))
        defer {
            controller.tearDown()
            window.contentView = nil
        }
        controller.tableView.scroll(CGPoint(x: 0, y: 1_000))
        controller.textSelection = DiffTextSelection(
            column: .before,
            anchor: DiffTextPosition(row: 3, offset: 0),
            head: DiffTextPosition(row: 3, offset: 4)
        )
        #expect(controller.scrollView.contentView.bounds.origin.y > 0)

        // The new file's document builds; its tokens arrive before it
        // installs.
        let next = DiffTableContent(fileID: "b", diff: try addedLines("b", 150))
        controller.apply(next)
        var withTokens = next
        withTokens.tokensGeneration += 1
        controller.apply(withTokens)
        #expect(controller.shownContent?.fileID == "a")

        await controller.documentIdle()
        #expect(controller.shownContent?.fileID == "b")
        #expect(controller.shownContent?.tokensGeneration == withTokens.tokensGeneration)
        #expect(controller.scrollView.contentView.bounds.origin.y == 0)
        #expect(controller.textSelection == nil)
    }

    @Test("staging waits for a building document, then acts on its generation")
    func stagingDuringBuild() async throws {
        let recorder = StagingRecorder()
        let (controller, window) = await makeTable(DiffTableContent(fileID: "a", diff: try addedLines("a", 20), staging: staging(1)))
        defer {
            controller.tearDown()
            window.contentView = nil
        }
        controller.actions.staging = recorder.actions
        let gutter = try point(in: controller, row: 2) {
            if case .gutter = $0 { true } else { false }
        }
        let handle = try point(in: controller, row: 2) {
            if case .handle = $0 { true } else { false }
        }

        controller.mouseUp(drag: controller.mouseDown(at: gutter, clickCount: 1, extendsSelection: false))
        #expect(recorder.generations == [1])

        // The file changed: its new diff builds.
        controller.apply(DiffTableContent(fileID: "a", diff: try addedLines("a", 21), staging: staging(2)))
        #expect(controller.isBuilding)
        controller.mouseUp(drag: controller.mouseDown(at: gutter, clickCount: 1, extendsSelection: false))
        _ = controller.mouseDown(at: handle, clickCount: 1, extendsSelection: false)
        #expect(controller.menuContent(at: gutter) == nil)
        #expect(controller.accessibilityActions(ofRow: 2).isEmpty)
        #expect(recorder.generations == [1])
        #expect(controller.shownContent?.staging?.diffGeneration == 1)

        await controller.documentIdle()
        controller.mouseUp(drag: controller.mouseDown(at: gutter, clickCount: 1, extendsSelection: false))
        #expect(recorder.generations == [1, 2])
    }
}
