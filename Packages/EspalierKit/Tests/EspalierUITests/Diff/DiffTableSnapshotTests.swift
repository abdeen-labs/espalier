// Snapshots of the diff table: unified and split, included and excluded
// lines with tinted numbers and the handle, wrapping with a hanging indent,
// unwrapped lines scrolled sideways, intra-line ranges, hunk headers with
// their expansion buttons and checkbox, a missing newline, a conflicted
// file, find's matches, text selection, and the line cursor (syntax color
// is TreeSitterHighlighterSnapshotTests'). The table draws its own colors:
// unified, split, staging, and find in light and dark, the rest in light.

import AppKit
import EspalierCore
import GitKit
import SwiftUI
import Testing
@testable import EspalierUI

@Suite("Diff table snapshots") @MainActor
struct DiffTableSnapshotTests {
    static let area = "Diff"
    static let size = CGSize(width: 720, height: 300)

    private func snapshot(
        _ name: String,
        size: CGSize = Self.size,
        appearances: [SnapshotAppearance] = [.light],
        _ content: @escaping () -> DiffTableContent,
        configure: @escaping (DiffTableController) -> Void = { _ in }
    ) {
        var controllers: [DiffTableController] = []
        assertSnapshot({
            let controller = DiffTables.controller(content(), size: size)
            configure(controller)
            controllers.append(controller)
            return controller.scrollView
        }, named: name, area: Self.area, size: size, appearances: appearances)
        _ = controllers
    }

    /// A partial selection of the Swift change: the first deleted line and
    /// the last added line excluded.
    static var partialSelection: DiffSelection {
        let diff = DiffFixtures.swiftChange
        let changed = diff.hunks.flatMap(\.lines).compactMap { $0.isIncludeableLine() ? $0.originalLineNumber : nil }
        return DiffSelection.fromInitialSelection(.all)
            .withSelectableLines(Set(changed))
            .withLineSelection(changed[0], selected: false)
            .withLineSelection(changed[5], selected: false)
    }

    @Test("unified")
    func unified() {
        snapshot("table-unified", appearances: SnapshotAppearance.allCases) {
            DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange)
        }
    }

    @Test("split")
    func split() {
        snapshot("table-split", appearances: SnapshotAppearance.allCases) {
            DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, isSplit: true)
        }
    }

    @Test("staging with line numbers, partly excluded")
    func stagingNumbers() {
        snapshot("table-staging-numbers", appearances: SnapshotAppearance.allCases) {
            DiffTableContent(
                fileID: "a",
                diff: DiffFixtures.swiftChange,
                staging: StagingState(selection: Self.partialSelection, canSelectLines: true, hidesWhitespace: false, canDiscard: true)
            )
        }
    }

    @Test("split staging")
    func splitStaging() {
        snapshot("table-split-staging") {
            DiffTableContent(
                fileID: "a",
                diff: DiffFixtures.swiftChange,
                isSplit: true,
                staging: StagingState(selection: Self.partialSelection, canSelectLines: true, hidesWhitespace: false, canDiscard: true)
            )
        }
    }

    @Test("wrapped, with a tab and wide characters")
    func wrapped() {
        snapshot("table-wrapped", size: CGSize(width: 480, height: 220)) {
            DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping)
        }
    }

    @Test("unwrapped lines scrolled sideways: the numbers stay")
    func scrolledSideways() {
        snapshot("table-scrolled", size: CGSize(width: 480, height: 160), {
            DiffTableContent(fileID: "a", diff: DiffFixtures.wrapping, wrapsLines: false)
        }, configure: { controller in
            controller.scrollText(by: controller.font.characterWidth * 12)
        })
    }

    @Test("expansion buttons")
    func expansion() {
        snapshot("table-expansion", size: CGSize(width: 720, height: 340)) {
            DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChangeWithBottomHunk, canExpand: true)
        }
    }

    @Test("no newline at end of file")
    func noNewline() {
        snapshot("table-no-newline", size: CGSize(width: 520, height: 120)) {
            DiffTableContent(fileID: "a", diff: DiffFixtures.noNewline)
        }
    }

    @Test("conflict markers, and ours, the common ancestor's, and theirs between them")
    func conflict() {
        snapshot("table-conflict", size: CGSize(width: 520, height: 240)) {
            DiffTableContent(fileID: "a", diff: DiffFixtures.conflictWithBase, detectsConflictMarkers: true)
        }
    }

    @Test("find's matches on context, deleted, and added lines, the current one, on an added line, stronger")
    func find() {
        snapshot("table-find", appearances: SnapshotAppearance.allCases, {
            DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange)
        }, configure: { controller in
            controller.find.show(focus: false, from: DiffFindPosition(row: 5, column: .before, offset: 0))
            controller.find.query = "path"
        })
    }

    @Test("find's matches split: a context line's on both sides")
    func findSplit() {
        snapshot("table-find-split", appearances: SnapshotAppearance.allCases, {
            DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange, isSplit: true)
        }, configure: { controller in
            controller.find.show(focus: false, from: DiffFindPosition(row: 5, column: .after, offset: 0))
            controller.find.query = "path"
        })
    }

    @Test("text selected with the mouse: the line cursor doesn't show; Espalier's selection, neutral while the table doesn't have focus")
    func selection() {
        snapshot("table-selection", appearances: SnapshotAppearance.allCases, {
            DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange)
        }, configure: Self.selectText)
        for appearance in SnapshotAppearance.allCases {
            let size = Self.size
            let controller = DiffTables.controller(DiffTableContent(fileID: "a", diff: DiffFixtures.swiftChange), size: size)
            let window = SnapshotWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance.appearance
            window.contentView = controller.scrollView
            window.makeFirstResponder(controller.tableView)
            Self.selectText(controller)
            controller.scrollView.layoutSubtreeIfNeeded()
            let image = Snapshot.bitmap(size)
            controller.scrollView.cacheDisplay(in: controller.scrollView.bounds, to: image)
            assertSnapshot(image, named: "table-selection-focused", area: Self.area, appearance: appearance)
            window.contentView = nil
        }
    }

    /// Drags across rows 3 to 5, from column 12 to 20.
    private static func selectText(_ controller: DiffTableController) {
        let start = controller.geometry.x(ofColumn: 12, side: .before, scrollX: 0)
        let end = controller.geometry.x(ofColumn: 20, side: .before, scrollX: 0)
        let drag = controller.mouseDown(at: point(controller, row: 3, x: start), clickCount: 1, extendsSelection: false)
        controller.mouseDragged(to: point(controller, row: 5, x: end), drag: drag)
        controller.mouseUp(drag: drag)
    }

    @Test("the focused table: a block under the pointer on its handle, a hovered expansion button, the line cursor")
    func focusedAndHovered() {
        for appearance in [SnapshotAppearance.light] {
            let size = CGSize(width: 720, height: 300)
            let controller = DiffTables.controller(DiffTableContent(
                fileID: "a",
                diff: DiffFixtures.swiftChangeWithBottomHunk,
                canExpand: true,
                staging: StagingState(selection: Self.partialSelection, canSelectLines: true, hidesWhitespace: false, canDiscard: true)
            ), size: size)
            let window = SnapshotWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance.appearance
            window.contentView = controller.scrollView
            window.makeFirstResponder(controller.tableView)
            controller.setCursor(row: 5, extending: false)
            controller.mouseMoved(to: point(controller, row: 4, x: middle(controller.geometry.handle!)))
            let buttons = controller.geometry.expansionButtonRects(count: 2, rowHeight: controller.tableView.rect(ofRow: 12).height)
            #expect(controller.hoveredBlock == 0)
            controller.mouseMoved(to: point(controller, row: 12, x: buttons[1].midX))
            #expect(controller.hoveredButton?.button == .expandDown)
            // Hover the handle again; the button stays drawn hovered only
            // while the pointer is on it, so draw both states in one image
            // by hovering the handle last.
            controller.mouseMoved(to: point(controller, row: 4, x: middle(controller.geometry.handle!)))
            controller.scrollView.layoutSubtreeIfNeeded()
            // At 1x, as the other references are.
            let image = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            image.size = size
            controller.scrollView.cacheDisplay(in: controller.scrollView.bounds, to: image)
            assertSnapshot(image, named: "table-focused-hovered", area: Self.area, appearance: appearance)
            window.contentView = nil
        }
    }
}
