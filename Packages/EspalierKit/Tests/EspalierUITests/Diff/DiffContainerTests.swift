// The diff container's choices: whether the diff shown is the file's while
// the next loads, and the options menu's expansion item.

import EspalierCore
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Diff container") @MainActor
struct DiffContainerTests {
    /// A diff, its file ("b"), and the file of the diff last loaded.
    struct Shown: Sendable {
        let diff: Loadable<Diff, OperationError>
        let loadedFileID: String?
        let isFilesDiff: Bool
    }

    @Test("the diff shown is the file's once loaded, or while the file's own diff reloads", arguments: [
        NamedCase("a loaded diff", Shown(diff: .loaded(.binary), loadedFileID: "a", isFilesDiff: true)),
        NamedCase("the previous file's diff while the file's loads", Shown(diff: .loading(previous: .binary), loadedFileID: "a", isFilesDiff: false)),
        NamedCase("the file's diff while it reloads", Shown(diff: .loading(previous: .binary), loadedFileID: "b", isFilesDiff: true)),
        NamedCase("a previous diff of no known file", Shown(diff: .loading(previous: .binary), loadedFileID: nil, isFilesDiff: false)),
        NamedCase("nothing while the first diff loads", Shown(diff: .loading(previous: nil), loadedFileID: "b", isFilesDiff: false)),
    ])
    func isFilesDiff(_ testCase: NamedCase<Shown>) {
        let shown = testCase.value
        #expect(DiffContainer.isFilesDiff(shown.diff, fileID: "b", loadedFileID: shown.loadedFileID) == shown.isFilesDiff)
    }

    /// A diff of `count` one-line hunks of `expansionType`.
    private static func diff(hunks count: Int, _ expansionType: DiffHunkExpansionType = .both) -> TextDiff {
        let hunks = (0..<count).map { index in
            DiffHunk(
                header: DiffHunkHeader(oldStartLine: index * 10 + 1, oldLineCount: 1, newStartLine: index * 10 + 1, newLineCount: 1),
                lines: [DiffLine(text: "+line", type: .add, originalLineNumber: index, oldLineNumber: nil, newLineNumber: index * 10 + 1, noTrailingNewLine: false)],
                unifiedDiffStart: index,
                unifiedDiffEnd: index,
                expansionType: expansionType
            )
        }
        return TextDiff(text: "", hunks: hunks, maxLineNumber: count * 10, hasHiddenBidiChars: false)
    }

    @Test("a diff without hunks offers no expansion, even once its file's contents load")
    func noHunks() {
        #expect(DiffContainer.expansion(Self.diff(hunks: 0), canExpand: true, hasExpandedLines: false) == nil)
    }

    @Test("Expand Whole File is disabled once the diff shows the whole file, and becomes Collapse once lines are expanded")
    func expansion() {
        #expect(DiffContainer.expansion(Self.diff(hunks: 2), canExpand: true, hasExpandedLines: false) == .expand(isEnabled: true))
        #expect(DiffContainer.expansion(Self.diff(hunks: 1, .none), canExpand: true, hasExpandedLines: false) == .expand(isEnabled: false))
        #expect(DiffContainer.expansion(Self.diff(hunks: 2), canExpand: true, hasExpandedLines: true) == .collapse)
    }
}
