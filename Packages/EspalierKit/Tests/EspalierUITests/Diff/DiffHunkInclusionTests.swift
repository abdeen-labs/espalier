// A hunk's checkbox: how much of the hunk the commit includes, and the
// diff table keeping it current as the staging and the document change.

import AppKit
import EspalierCore
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

private let everyLine = DiffSelection.fromInitialSelection(.all)
private let noLine = DiffSelection.fromInitialSelection(.none)

@Suite("Hunk inclusion")
struct HunkInclusionTests {
    @Test("is all, none, or partial by the hunk's changed lines", arguments: [
        NamedCase("every changed line included", (lines: [2, 3], selection: everyLine, expected: .all)),
        NamedCase("no changed line included", (lines: [2, 3], selection: noLine, expected: DiffSelectionType.none)),
        NamedCase("some changed lines included", (lines: [2, 3], selection: everyLine.withLineSelection(3, selected: false), expected: .partial)),
        NamedCase("a line of another hunk left out", (lines: [2, 3], selection: everyLine.withLineSelection(7, selected: false), expected: .all)),
        NamedCase("a line of another hunk included", (lines: [2, 3], selection: noLine.withLineSelection(7, selected: true), expected: DiffSelectionType.none)),
        NamedCase("no changed lines", (lines: [], selection: everyLine, expected: nil)),
    ] as [NamedCase<(lines: [Int], selection: DiffSelection, expected: DiffSelectionType?)>])
    func inclusion(_ testCase: NamedCase<(lines: [Int], selection: DiffSelection, expected: DiffSelectionType?)>) {
        #expect(hunkInclusion(ofChangedLines: testCase.value.lines, in: testCase.value.selection) == testCase.value.expected)
    }
}

@Suite("Diff table hunk checkboxes", .hangGuard(minutes: 5)) @MainActor
struct DiffTableHunkInclusionTests {
    /// A modified file's diff with `hunks`.
    private func diff(_ hunks: String) throws -> TextDiff {
        let raw = try DiffParser().parse("""
        diff --git a/f.txt b/f.txt
        index 1111111..2222222 100644
        --- a/f.txt
        +++ b/f.txt
        \(hunks)
        """)
        return TextDiff(
            text: raw.contents,
            hunks: raw.hunks,
            lineEndingsChange: nil,
            maxLineNumber: raw.maxLineNumber,
            hasHiddenBidiChars: raw.hasHiddenBidiChars
        )
    }

    private func content(_ diff: TextDiff, _ selection: DiffSelection) -> DiffTableContent {
        DiffTableContent(
            fileID: "f",
            diff: diff,
            staging: StagingState(selection: selection, canSelectLines: true, hidesWhitespace: false, canDiscard: true)
        )
    }

    // With motion, the staging's crossfade works out the new inclusions of
    // the hunks on screen; without, they're worked out as headers draw.
    @Test("follow the staging and the document", arguments: [
        NamedCase("with motion", true),
        NamedCase("without motion", false),
    ])
    func followStagingAndDocument(_ motion: NamedCase<Bool>) async throws {
        // Diff lines 2 and 3 are the first hunk's changes, 7 the second's.
        let twoHunks = try diff("""
        @@ -1,2 +1,4 @@
         a
        +b
        +c
         d
        @@ -10,2 +12,3 @@
         j
        +k
         l
        """)
        let excludingB = everyLine.withLineSelection(2, selected: false)

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.motionOverride = motion.value
        let controller = DiffTableController()
        window.contentView = controller.scrollView
        controller.scrollView.layoutSubtreeIfNeeded()
        defer {
            controller.tearDown()
            window.contentView = nil
        }
        controller.apply(content(twoHunks, excludingB))
        await controller.documentIdle()

        func inclusions() -> [DiffSelectionType?] {
            controller.document.hunks.map { controller.inclusion(ofHunk: $0) }
        }
        #expect(inclusions() == [.partial, .all])

        controller.apply(content(twoHunks, noLine))
        #expect(inclusions() == [DiffSelectionType.none, DiffSelectionType.none])

        controller.apply(content(twoHunks, excludingB))
        #expect(inclusions() == [.partial, .all])

        // Another diff of the file, with the same staging: its one hunk's
        // only change is line 2.
        let oneHunk = try diff("""
        @@ -1,2 +1,3 @@
         a
        +b
         d
        """)
        controller.apply(content(oneHunk, excludingB))
        await controller.documentIdle()
        #expect(inclusions() == [DiffSelectionType.none])
    }
}
