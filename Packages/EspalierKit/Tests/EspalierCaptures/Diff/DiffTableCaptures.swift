// The diff table: unified and split, included and excluded lines with
// tinted numbers and the handle, wrapping with a hanging indent, unwrapped
// lines scrolled sideways, intra-line ranges, hunk headers with their
// expansion buttons and checkbox, a missing newline, a conflicted file,
// find's matches, text selection, the line cursor, and hover (syntax
// color is DiffHighlightCaptures'). Unified, split, staging, find, and
// selection in light and dark, the rest in light.

import AppKit
import EspalierCore
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Diff table", .captures, .hangGuard(minutes: 5)) @MainActor
struct DiffTableCaptures {
    private let area = "Diff"
    private static let size = CGSize(width: 720, height: 300)

    /// Captures `content` in a table of `size`, focused when `focused`,
    /// after `configure` (find, scrolling, the mouse).
    private func capture(
        _ name: String,
        size: CGSize = Self.size,
        appearances: [CaptureAppearance] = [.light],
        focused: Bool = false,
        _ content: @autoclosure () -> DiffTableContent,
        configure: (DiffTableScene) -> Void = { _ in }
    ) async {
        for appearance in appearances {
            let scene = await DiffTableScene(content(), size: size, appearance: appearance)
            if focused {
                scene.window.makeFirstResponder(scene.controller.tableView)
            }
            configure(scene)
            EspalierCaptures.capture(named: name, area: area, appearances: [appearance]) { _ in
                scene.image()
            }
        }
    }

    @Test("unified")
    func unified() async {
        await capture("table-unified", appearances: CaptureAppearance.allCases, DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.swiftChange))
    }

    @Test("split")
    func split() async {
        await capture("table-split", appearances: CaptureAppearance.allCases, DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.swiftChange, isSplit: true))
    }

    @Test("staging with line numbers, partly excluded")
    func stagingNumbers() async {
        await capture(
            "table-staging-numbers",
            appearances: CaptureAppearance.allCases,
            DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.swiftChange, staging: DiffCaptureFixtures.partialStaging)
        )
    }

    @Test("split staging")
    func splitStaging() async {
        await capture(
            "table-split-staging",
            DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.swiftChange, isSplit: true, staging: DiffCaptureFixtures.partialStaging)
        )
    }

    @Test("wrapped, with a tab and wide characters")
    func wrapped() async {
        await capture("table-wrapped", size: CGSize(width: 480, height: 220), DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.wrapping))
    }

    @Test("unwrapped lines scrolled sideways: the numbers stay")
    func scrolledSideways() async {
        await capture(
            "table-scrolled",
            size: CGSize(width: 480, height: 160),
            DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.wrapping, wrapsLines: false)
        ) { scene in
            scene.controller.scrollText(by: scene.controller.font.characterWidth * 12)
        }
    }

    @Test("expansion buttons")
    func expansion() async {
        await capture(
            "table-expansion",
            size: CGSize(width: 720, height: 340),
            DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.swiftChangeWithBottomHunk, canExpand: true)
        )
    }

    @Test("no newline at end of file")
    func noNewline() async {
        await capture("table-no-newline", size: CGSize(width: 520, height: 120), DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.noNewline))
    }

    @Test("conflict markers, and ours, the common ancestor's, and theirs between them")
    func conflict() async {
        await capture(
            "table-conflict",
            size: CGSize(width: 520, height: 240),
            DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.conflictWithBase, detectsConflictMarkers: true)
        )
    }

    @Test("find's matches on context, deleted, and added lines; the current one, on an added line, stronger")
    func find() async {
        await capture("table-find", appearances: CaptureAppearance.allCases, DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.swiftChange)) { scene in
            scene.controller.find.show(focus: false, from: DiffFindPosition(row: 5, column: .before, offset: 0))
            scene.controller.find.query = "path"
        }
    }

    @Test("find's matches split: a context line's on both sides")
    func findSplit() async {
        await capture(
            "table-find-split",
            appearances: CaptureAppearance.allCases,
            DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.swiftChange, isSplit: true)
        ) { scene in
            scene.controller.find.show(focus: false, from: DiffFindPosition(row: 5, column: .after, offset: 0))
            scene.controller.find.query = "path"
        }
    }

    @Test("text selected with the mouse, then focus elsewhere: no line cursor; the selection neutral while the table doesn't have focus")
    func selection() async {
        await capture("table-selection", appearances: CaptureAppearance.allCases, DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.swiftChange)) { scene in
            Self.selectText(scene)
            scene.window.makeFirstResponder(nil)
        }
    }

    @Test("text selected with the mouse in the focused table")
    func selectionFocused() async {
        await capture(
            "table-selection-focused",
            appearances: CaptureAppearance.allCases,
            focused: true,
            DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.swiftChange)
        ) { scene in
            Self.selectText(scene)
        }
    }

    /// Drags across rows 3 to 5, from column 12 to 20.
    private static func selectText(_ scene: DiffTableScene) {
        let controller = scene.controller
        let start = controller.geometry.x(ofColumn: 12, side: .before, scrollX: 0)
        let end = controller.geometry.x(ofColumn: 20, side: .before, scrollX: 0)
        let drag = controller.mouseDown(at: scene.point(row: 3, x: start), clickCount: 1, extendsSelection: false)
        controller.mouseDragged(to: scene.point(row: 5, x: end), drag: drag)
        controller.mouseUp(drag: drag)
    }

    @Test("the focused table: the line cursor, and the block under the pointer on its handle")
    func focusedAndHovered() async {
        await capture(
            "table-focused-hovered",
            focused: true,
            DiffTableContent(
                fileID: "a",
                diff: DiffCaptureFixtures.swiftChangeWithBottomHunk,
                canExpand: true,
                staging: DiffCaptureFixtures.partialStaging
            )
        ) { scene in
            let controller = scene.controller
            controller.setCursor(row: 5, extending: false)
            controller.mouseMoved(to: scene.point(row: 4, x: DiffTableScene.middle(controller.geometry.handle!)))
        }
    }

    @Test("a hovered expansion button")
    func hoveredExpansionButton() async {
        await capture(
            "table-expansion-hovered",
            size: CGSize(width: 720, height: 340),
            focused: true,
            DiffTableContent(fileID: "a", diff: DiffCaptureFixtures.swiftChangeWithBottomHunk, canExpand: true)
        ) { scene in
            let controller = scene.controller
            let row = controller.document.hunks[1].row
            let buttons = controller.geometry.expansionButtonRects(count: 2, rowHeight: controller.tableView.rect(ofRow: row).height)
            controller.mouseMoved(to: scene.point(row: row, x: buttons[1].midX))
        }
    }
}
