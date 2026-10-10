// The diff's text arithmetic: display columns, wrapping at exact columns
// with a hanging indent, hit-testing offsets, drawing runs, changed ranges,
// and text selection and copying (one-column selection and whole-diff
// copy).

import GitKit
import Testing
@testable import EspalierUI

@Suite("Diff text")
struct DiffTextTests {
    // MARK: Columns and wrapping

    @Test("display columns: ASCII 1, wide 2, combining and controls 0")
    func displayColumns() {
        #expect(DisplayColumns.width(of: "a") == 1)
        #expect(DisplayColumns.width(of: "\u{65E5}") == 2)
        #expect(DisplayColumns.width(of: "\u{FF21}") == 2)
        #expect(DisplayColumns.width(of: "\u{1F600}") == 2)
        #expect(DisplayColumns.width(of: "\u{301}") == 0)
        #expect(DisplayColumns.width(of: "\u{200B}") == 0)
        #expect(DisplayColumns.width(of: "\u{202E}") == 0)
        #expect(DisplayColumns.width(of: "\u{1}") == 0)
        #expect(DisplayColumns.width(of: "\u{E9}") == 1)
    }

    @Test("visual lines: counted for simple lines (continuation lines two columns in), laid out for the rest")
    func visualLineCounts() {
        let simple = LineTextInfo(utf16Count: 25, columns: 25, isSimple: true)
        #expect(simple.visualLineCount(columnsPerLine: 10) == 3)
        #expect(simple.visualLineCount(columnsPerLine: 25) == 1)
        #expect(simple.visualLineCount(columnsPerLine: 100) == 1)
        let complex = LineTextInfo(utf16Count: 25, columns: 30, isSimple: false)
        #expect(complex.visualLineCount(columnsPerLine: 40) == 1)
        #expect(complex.visualLineCount(columnsPerLine: 10) == nil)
    }

    @Test("a simple line wraps at exactly the columns that fit, continuing two columns in")
    func simpleWrapping() {
        let text = "+" + String(repeating: "abcdefghij", count: 3)
        let info = LineTextInfo(text, skippingFirstScalar: true, tabSize: 4)
        let layout = LineLayout(text, skippingFirstScalar: true, info: info, tabSize: 4, columnsPerLine: 12)
        #expect(layout.indent == 2)
        #expect(layout.visualLineCount == 3)
        #expect(info.visualLineCount(columnsPerLine: 12) == 3)
        #expect(layout.range(ofVisualLine: 0) == 0..<12)
        #expect(layout.range(ofVisualLine: 1) == 12..<22)
        #expect(layout.range(ofVisualLine: 2) == 22..<30)
        #expect(layout.visualLine(of: 12) == 1)
        #expect(layout.visualLine(of: 22) == 2)
        #expect(layout.visualLine(of: 30) == 2)
        #expect(layout.column(of: 11) == 11)
        #expect(layout.column(of: 13) == 3)
        #expect(layout.column(of: 30) == 10)
        #expect(layout.endColumn(ofVisualLine: 2) == 10)
        #expect(layout.offset(atVisualLine: 1, column: 4.4) == 14)
        #expect(layout.offset(atVisualLine: 1, column: 4.6) == 15)
        // A click in the indent is the line's start.
        #expect(layout.offset(atVisualLine: 1, column: 1) == 12)
        #expect(layout.offset(atVisualLine: 2, column: 50) == 30)
        #expect(layout.runs(ofVisualLine: 0, units: Array(text.utf16.dropFirst())) == [LineLayout.Run(range: 0..<12, column: 0, isSimple: true)])
        #expect(layout.runs(ofVisualLine: 1, units: Array(text.utf16.dropFirst())) == [LineLayout.Run(range: 12..<22, column: 2, isSimple: true)])
    }

    @Test("continuation lines hang under the first character after the indentation, two columns in, at most halfway across")
    func hangingIndent() {
        // Four spaces, then 21 characters: continuation lines start at 6.
        let indented = "+    let x = foo(bar, baz)"
        let info = LineTextInfo(indented, skippingFirstScalar: true, tabSize: 4)
        #expect(info.leadingColumns == 4)
        let layout = LineLayout(indented, skippingFirstScalar: true, info: info, tabSize: 4, columnsPerLine: 14)
        #expect(layout.indent == 6)
        #expect(layout.range(ofVisualLine: 1) == 14..<22)
        #expect(layout.column(of: 14) == 6)
        #expect(layout.visualLineCount == info.visualLineCount(columnsPerLine: 14))

        // A tab indents as far as its tab stop.
        let tabbed = LineTextInfo("+\tlet x = foo(bar, baz)", skippingFirstScalar: true, tabSize: 4)
        #expect(tabbed.leadingColumns == 4)

        // Deep indentation stops halfway across.
        let deep = LineTextInfo("+" + String(repeating: " ", count: 20) + "x", skippingFirstScalar: true, tabSize: 4)
        #expect(deep.hangingIndent(columnsPerLine: 12) == 6)

        // A line that fits doesn't indent.
        let short = LineLayout(indented, skippingFirstScalar: true, info: info, tabSize: 4, columnsPerLine: 40)
        #expect(short.indent == 0)
        #expect(short.visualLineCount == 1)
    }

    @Test("a wide character that doesn't fit moves to the next line")
    func wideCharacterWraps() {
        // "abc" then two wide characters at 4 columns per line: "abc" fits;
        // each wide character would straddle the end of its line, so each
        // starts the next, two columns in.
        let text = " abc\u{65E5}\u{672C}"
        let info = LineTextInfo(text, skippingFirstScalar: true, tabSize: 4)
        #expect(info.columns == 7)
        let layout = LineLayout(text, skippingFirstScalar: true, info: info, tabSize: 4, columnsPerLine: 4)
        #expect(layout.visualLineCount == 3)
        #expect(layout.range(ofVisualLine: 0) == 0..<3)
        #expect(layout.range(ofVisualLine: 1) == 3..<4)
        #expect(layout.range(ofVisualLine: 2) == 4..<5)
        #expect(layout.placement(of: 3) == (2, 2))
        #expect(layout.placement(of: 4) == (2, 2))
        #expect(layout.endColumn(ofVisualLine: 1) == 4)
        // Hit-testing: the middle of a wide character rounds.
        #expect(layout.offset(atVisualLine: 1, column: 2.9) == 3)
        #expect(layout.offset(atVisualLine: 1, column: 3.1) == 4)
    }

    @Test("tabs advance to the next stop and stop at the end of a line")
    func tabs() {
        let text = " a\tb"
        let info = LineTextInfo(text, skippingFirstScalar: true, tabSize: 4)
        #expect(info.columns == 5)
        let unwrapped = LineLayout(text, skippingFirstScalar: true, info: info, tabSize: 4, columnsPerLine: .max)
        #expect(unwrapped.placement(of: 1) == (1, 3))
        #expect(unwrapped.placement(of: 2) == (4, 1))
        #expect(unwrapped.runs(ofVisualLine: 0, units: Array("a\tb".utf16)) == [
            LineLayout.Run(range: 0..<1, column: 0, isSimple: true),
            LineLayout.Run(range: 2..<3, column: 4, isSimple: true),
        ])
        // At 3 columns the tab fills the line's last two columns; "b"
        // continues a column in.
        let wrapped = LineLayout(text, skippingFirstScalar: true, info: info, tabSize: 4, columnsPerLine: 3)
        #expect(wrapped.visualLineCount == 2)
        #expect(wrapped.placement(of: 1) == (1, 2))
        #expect(wrapped.range(ofVisualLine: 1) == 2..<3)
        #expect(wrapped.placement(of: 2) == (1, 1))
    }

    @Test("combining marks stay with their character, and a surrogate pair is one character")
    func clusters() {
        let text = "+e\u{301}x\u{1F600}y"
        let info = LineTextInfo(text, skippingFirstScalar: true, tabSize: 4)
        #expect(info.utf16Count == 6)
        #expect(info.columns == 5)
        let layout = LineLayout(text, skippingFirstScalar: true, info: info, tabSize: 4, columnsPerLine: .max)
        #expect(layout.placement(of: 0) == (0, 1))
        #expect(layout.placement(of: 1) == (1, 0))
        #expect(layout.placement(of: 2) == (1, 1))
        #expect(layout.placement(of: 3) == (2, 2))
        #expect(layout.placement(of: 4) == (2, 0))
        #expect(layout.placement(of: 5) == (4, 1))
        // Clicking just right of "e" lands after its combining mark.
        #expect(layout.offset(atVisualLine: 0, column: 0.8) == 2)
        #expect(layout.offset(atVisualLine: 0, column: 2.5) == 3)
        #expect(layout.offset(atVisualLine: 0, column: 3.5) == 5)
        let runs = layout.runs(ofVisualLine: 0, units: Array(text.utf16.dropFirst()))
        #expect(runs == [
            LineLayout.Run(range: 0..<2, column: 0, isSimple: false),
            LineLayout.Run(range: 2..<3, column: 1, isSimple: true),
            LineLayout.Run(range: 3..<5, column: 2, isSimple: false),
            LineLayout.Run(range: 5..<6, column: 4, isSimple: true),
        ])
    }

    // MARK: Changed ranges

    @Test("the changed range is what's left after the common prefix and suffix")
    func relativeChangeRanges() {
        let change = relativeChanges("let tip = repo.tip!", "let tip = repo.tip")
        #expect(change.stringARange == IntraLineRange(location: 18, length: 1))
        #expect(change.stringBRange == IntraLineRange(location: 18, length: 0))

        let middle = relativeChanges("return a + b", "return a - b")
        #expect(middle.stringARange == IntraLineRange(location: 9, length: 1))
        #expect(middle.stringBRange == IntraLineRange(location: 9, length: 1))

        let same = relativeChanges("abc", "abc")
        #expect(same.stringARange.length == 0 && same.stringBRange.length == 0)

        let different = relativeChanges("abc", "xyz")
        #expect(different.stringARange == IntraLineRange(location: 0, length: 3))
    }

    @Test("ranges are UTF-16, as desktop's strings are")
    func utf16Ranges() {
        let change = relativeChanges("a\u{1F600}b", "a\u{1F601}b")
        // The emoji's lead surrogates match; only the trail differs.
        #expect(change.stringARange == IntraLineRange(location: 2, length: 1))
    }

    @Test("lines of 1,024 code units or more get no intra-line range")
    func longLines() {
        let long = String(repeating: "x", count: 1_024)
        #expect(intraLineChange(before: long, after: long + "y") == nil)
        #expect(intraLineChange(before: "ab", after: "ac") != nil)
    }

    // MARK: Selection and copying

    private var unified: DiffDocument {
        DiffDocument(input: DiffDocumentInput(hunks: DiffFixtures.swiftChange.hunks, maxLineNumber: 50, isSplit: false))
    }

    private var split: DiffDocument {
        DiffDocument(input: DiffDocumentInput(hunks: DiffFixtures.swiftChange.hunks, maxLineNumber: 50, isSplit: true))
    }

    @Test("a selection copies each row's selected content, without markers")
    func copySelection() {
        let selection = DiffTextSelection(column: .before, anchor: DiffTextPosition(row: 3, offset: 12), head: DiffTextPosition(row: 5, offset: 13))
        #expect(unified.text(of: selection) == "tip = repo.tip!\n        return Repository(path: path, tip: tip)\n        guard")
        // Backwards gives the same.
        let backwards = DiffTextSelection(column: .before, anchor: selection.head, head: selection.anchor)
        #expect(unified.text(of: backwards) == unified.text(of: selection))
    }

    @Test("a split selection stays on its side and skips rows without text there")
    func splitSelection() {
        // Rows 3-6: two modified rows, then two added rows (nothing on the
        // old side).
        let old = DiffTextSelection(column: .before, anchor: DiffTextPosition(row: 3, offset: 8), head: DiffTextPosition(row: 7, offset: 5))
        #expect(split.text(of: old) == "let tip = repo.tip!\n        return Repository(path: path, tip: tip)\n    }")
        let new = DiffTextSelection(column: .after, anchor: DiffTextPosition(row: 4, offset: 12), head: DiffTextPosition(row: 5, offset: 9))
        #expect(split.text(of: new) == "return .empty\n        }")
    }

    @Test("Select All selects a side: unified everything, split the old or the new text")
    func selectAll() {
        let all = try! #require(unified.selectAll(.after))
        let text = unified.text(of: all)
        #expect(text.hasPrefix("    func load() throws -> Repository {\n"))
        #expect(text.contains("        let tip = repo.tip!\n"))
        #expect(text.contains("        guard let tip = repo.tip else {\n"))
        #expect(!text.contains("@@"))
        #expect(text.hasSuffix("    }\n}"))

        let old = split.text(of: try! #require(split.selectAll(.before)))
        #expect(old.contains("let tip = repo.tip!") && !old.contains("guard let tip"))
        let new = split.text(of: try! #require(split.selectAll(.after)))
        #expect(!new.contains("let tip = repo.tip!") && new.contains("guard let tip"))
        #expect(!new.contains("TODO") && old.contains("TODO"))
    }

    @Test("double-click selects a word, triple-click a line")
    func wordAndLine() {
        let word = try! #require(unified.wordSelection(row: 5, column: .before, offset: 19))
        #expect(unified.text(of: word) == "tip")
        let spaces = try! #require(unified.wordSelection(row: 5, column: .before, offset: 2))
        #expect(unified.text(of: spaces) == "        ")
        let punctuation = try! #require(unified.wordSelection(row: 5, column: .before, offset: 28))
        #expect(unified.text(of: punctuation) == ".")
        let line = try! #require(unified.lineSelection(row: 5, column: .before))
        #expect(unified.text(of: line) == "        guard let tip = repo.tip else {")
        #expect(unified.wordSelection(row: 0, column: .before, offset: 0) == nil)
    }

    @Test("copying cursor rows copies their lines without markers, both sides of a split row")
    func copyRows() {
        #expect(unified.text(ofRows: 3...4) == "        let tip = repo.tip!\n        return Repository(path: path, tip: tip)")
        #expect(split.text(ofRows: 3...3) == "        let tip = repo.tip!\n        guard let tip = repo.tip else {")
        #expect(split.text(ofRows: 1...1) == "    func load() throws -> Repository {")
    }
}
