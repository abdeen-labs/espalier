// Ported from desktop/app/test/unit/diff-parser-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

// Atom doesn't like lines with just one space and tries to
// de-indent so when copying- and pasting diff contents the
// space signalling that the line is a context line gets lost.
//
// This function reinstates that space and makes us all
// feel a little bit sad.
private func reinstateSpacesAtTheStartOfBlankLines(_ text: String) -> String {
    text.replacingOccurrences(of: "\n\n", with: "\n \n")
}

@Suite("DiffParser")
struct DiffParserTests {
    @Test("parses changed files")
    func parsesChangedFiles() throws {
        let diffText = #"""
            diff --git a/app/src/lib/diff-parser.ts b/app/src/lib/diff-parser.ts
            index e1d4871..3bd3ee0 100644
            --- a/app/src/lib/diff-parser.ts
            +++ b/app/src/lib/diff-parser.ts
            @@ -18,6 +18,7 @@ export function parseRawDiff(lines: ReadonlyArray<string>): Diff {

                 let numberOfUnifiedDiffLines = 0

            +
                 while (prefixFound) {

                   // trim any preceding text
            @@ -71,12 +72,9 @@ export function parseRawDiff(lines: ReadonlyArray<string>): Diff {
                     diffSections.push(new DiffSection(range, diffLines, startDiffSection, endDiffSection))
                   } else {
                     const diffBody = diffTextBuffer
            -
                     let startDiffSection: number = 0
                     let endDiffSection: number = 0
            -
                     const diffLines = diffBody.split('\n')
            -
                     if (diffSections.length === 0) {
                       startDiffSection = 0
                       endDiffSection = diffLines.length
            @@ -84,10 +82,8 @@ export function parseRawDiff(lines: ReadonlyArray<string>): Diff {
                       startDiffSection = numberOfUnifiedDiffLines
                       endDiffSection = startDiffSection + diffLines.length
                     }
            -
                     diffSections.push(new DiffSection(range, diffLines, startDiffSection, endDiffSection))
                   }
                 }
            -
                 return new Diff(diffSections)
             }

            """#

        let parser = DiffParser()
        let diff = try parser.parse(reinstateSpacesAtTheStartOfBlankLines(diffText))
        #expect(diff.hunks.count == 3)

        var hunk = diff.hunks[0]
        #expect(hunk.unifiedDiffStart == 0)
        #expect(hunk.unifiedDiffEnd == 7)

        var lines = hunk.lines
        #expect(lines.count == 8)

        var i = 0
        #expect(lines[i].text == "@@ -18,6 +18,7 @@ export function parseRawDiff(lines: ReadonlyArray<string>): Diff {")
        #expect(lines[i].type == .hunk)
        #expect(lines[i].oldLineNumber == nil)
        #expect(lines[i].newLineNumber == nil)
        i += 1

        #expect(lines[i].text == " ")
        #expect(lines[i].type == .context)
        #expect(lines[i].oldLineNumber == 18)
        #expect(lines[i].newLineNumber == 18)
        i += 1

        #expect(lines[i].text == "     let numberOfUnifiedDiffLines = 0")
        #expect(lines[i].type == .context)
        #expect(lines[i].oldLineNumber == 19)
        #expect(lines[i].newLineNumber == 19)
        i += 1

        #expect(lines[i].text == " ")
        #expect(lines[i].type == .context)
        #expect(lines[i].oldLineNumber == 20)
        #expect(lines[i].newLineNumber == 20)
        i += 1

        #expect(lines[i].text == "+")
        #expect(lines[i].type == .add)
        #expect(lines[i].oldLineNumber == nil)
        #expect(lines[i].newLineNumber == 21)
        i += 1

        #expect(lines[i].text == "     while (prefixFound) {")
        #expect(lines[i].type == .context)
        #expect(lines[i].oldLineNumber == 21)
        #expect(lines[i].newLineNumber == 22)
        i += 1

        hunk = diff.hunks[1]
        #expect(hunk.unifiedDiffStart == 8)
        #expect(hunk.unifiedDiffEnd == 20)

        lines = hunk.lines
        #expect(lines.count == 13)
    }

    @Test("parses new files")
    func parsesNewFiles() throws {
        let diffText = """
            diff --git a/testste b/testste
            new file mode 100644
            index 0000000..f13588b
            --- /dev/null
            +++ b/testste
            @@ -0,0 +1 @@
            +asdfasdf

            """

        let parser = DiffParser()
        let diff = try parser.parse(diffText)
        #expect(diff.hunks.count == 1)

        let hunk = diff.hunks[0]
        #expect(hunk.unifiedDiffStart == 0)
        #expect(hunk.unifiedDiffEnd == 1)

        let lines = hunk.lines
        #expect(lines.count == 2)

        var i = 0
        #expect(lines[i].text == "@@ -0,0 +1 @@")
        #expect(lines[i].type == .hunk)
        #expect(lines[i].oldLineNumber == nil)
        #expect(lines[i].newLineNumber == nil)
        i += 1

        #expect(lines[i].text == "+asdfasdf")
        #expect(lines[i].type == .add)
        #expect(lines[i].oldLineNumber == nil)
        #expect(lines[i].newLineNumber == 1)
    }

    @Test("parses files containing @@")
    func parsesFilesContainingAtAt() throws {
        let diffText = """
            diff --git a/test.txt b/test.txt
            index 24219cc..bf711a5 100644
            --- a/test.txt
            +++ b/test.txt
            @@ -1 +1 @@
            -foo @@
            +@@ foo

            """

        let parser = DiffParser()
        let diff = try parser.parse(diffText)
        #expect(diff.hunks.count == 1)

        let hunk = diff.hunks[0]
        #expect(hunk.unifiedDiffStart == 0)
        #expect(hunk.unifiedDiffEnd == 2)

        let lines = hunk.lines
        #expect(lines.count == 3)

        var i = 0
        #expect(lines[i].text == "@@ -1 +1 @@")
        #expect(lines[i].type == .hunk)
        #expect(lines[i].oldLineNumber == nil)
        #expect(lines[i].newLineNumber == nil)
        i += 1

        #expect(lines[i].text == "-foo @@")
        #expect(lines[i].type == .delete)
        #expect(lines[i].oldLineNumber == 1)
        #expect(lines[i].newLineNumber == nil)
        i += 1

        #expect(lines[i].text == "+@@ foo")
        #expect(lines[i].type == .add)
        #expect(lines[i].oldLineNumber == nil)
        #expect(lines[i].newLineNumber == 1)
    }

    @Test("parses diffs that adds newline to end of file")
    func parsesDiffsAddingNewline() throws {
        let diffText = #"""
            diff --git a/test2.txt b/test2.txt
            index 1910281..257cc56 100644
            --- a/test2.txt
            +++ b/test2.txt
            @@ -1 +1 @@
            -foo
            \ No newline at end of file
            +foo

            """#
        let parser = DiffParser()
        let diff = try parser.parse(diffText)
        #expect(diff.hunks.count == 1)

        let hunk = diff.hunks[0]
        #expect(hunk.unifiedDiffStart == 0)
        #expect(hunk.unifiedDiffEnd == 2)

        let lines = hunk.lines
        #expect(lines.count == 3)

        var i = 0
        #expect(lines[i].text == "@@ -1 +1 @@")
        #expect(lines[i].type == .hunk)
        #expect(lines[i].oldLineNumber == nil)
        #expect(lines[i].newLineNumber == nil)
        #expect(lines[i].noTrailingNewLine == false)
        i += 1

        #expect(lines[i].text == "-foo")
        #expect(lines[i].type == .delete)
        #expect(lines[i].oldLineNumber == 1)
        #expect(lines[i].newLineNumber == nil)
        #expect(lines[i].originalLineNumber == 1)
        #expect(lines[i].noTrailingNewLine == true)
        i += 1

        #expect(lines[i].text == "+foo")
        #expect(lines[i].type == .add)
        #expect(lines[i].oldLineNumber == nil)
        #expect(lines[i].newLineNumber == 1)
        #expect(lines[i].originalLineNumber == 2)
        #expect(lines[i].noTrailingNewLine == false)
    }

    @Test("parses diffs where neither file version has a trailing newline")
    func parsesDiffsWithoutTrailingNewlines() throws {
        // echo -n 'foo' >  test
        // git add -A && git commit -m foo
        // echo -n 'bar' > test
        // git diff test
        let diffText = #"""
            diff --git a/test b/test
            index 1910281..ba0e162 100644
            --- a/test
            +++ b/test
            @@ -1 +1 @@
            -foo
            \ No newline at end of file
            +bar
            \ No newline at end of file

            """#
        let parser = DiffParser()
        let diff = try parser.parse(diffText)
        #expect(diff.hunks.count == 1)

        let hunk = diff.hunks[0]
        #expect(hunk.unifiedDiffStart == 0)
        #expect(hunk.unifiedDiffEnd == 2)

        let lines = hunk.lines
        #expect(lines.count == 3)

        var i = 0
        #expect(lines[i].text == "@@ -1 +1 @@")
        #expect(lines[i].type == .hunk)
        #expect(lines[i].oldLineNumber == nil)
        #expect(lines[i].newLineNumber == nil)
        #expect(lines[i].noTrailingNewLine == false)
        i += 1

        #expect(lines[i].text == "-foo")
        #expect(lines[i].type == .delete)
        #expect(lines[i].oldLineNumber == 1)
        #expect(lines[i].newLineNumber == nil)
        #expect(lines[i].originalLineNumber == 1)
        #expect(lines[i].noTrailingNewLine == true)
        i += 1

        #expect(lines[i].text == "+bar")
        #expect(lines[i].type == .add)
        #expect(lines[i].oldLineNumber == nil)
        #expect(lines[i].newLineNumber == 1)
        #expect(lines[i].originalLineNumber == 2)
        #expect(lines[i].noTrailingNewLine == true)
    }

    @Test("parses binary diffs")
    func parsesBinaryDiffs() throws {
        let diffText = """
            diff --git a/IMG_2306.CR2 b/IMG_2306.CR2
            new file mode 100644
            index 0000000..4bf3a64
            Binary files /dev/null and b/IMG_2306.CR2 differ

            """
        let parser = DiffParser()
        let diff = try parser.parse(diffText)
        #expect(diff.hunks.count == 0)
        #expect(diff.isBinary)
    }

    @Test("parses diff of empty file")
    func parsesDiffOfEmptyFile() throws {
        // To produce this output, do
        // touch foo
        // git diff --no-index --patch-with-raw -z -- /dev/null foo
        let diffText = """
            new file mode 100644
            index 0000000..e69de29

            """

        let parser = DiffParser()
        let diff = try parser.parse(diffText)
        #expect(diff.hunks.count == 0)
    }

    @Test("parses hunk headers with omitted line counts from new file")
    func parsesHunkHeadersOmittedNewFile() throws {
        let diffText = """
            diff --git a/testste b/testste
            new file mode 100644
            index 0000000..f13588b
            --- /dev/null
            +++ b/testste
            @@ -0,0 +1 @@
            +asdfasdf

            """

        let parser = DiffParser()
        let diff = try parser.parse(diffText)
        #expect(diff.hunks.count == 1)

        let hunk = diff.hunks[0]
        #expect(hunk.header.oldStartLine == 0)
        #expect(hunk.header.oldLineCount == 0)
        #expect(hunk.header.newStartLine == 1)
        #expect(hunk.header.newLineCount == 1)
    }

    @Test("parses hunk headers with omitted line counts from old file")
    func parsesHunkHeadersOmittedOldFile() throws {
        let diffText = """
            diff --git a/testste b/testste
            new file mode 100644
            index 0000000..f13588b
            --- /dev/null
            +++ b/testste
            @@ -1 +0,0 @@
            -asdfasdf

            """

        let parser = DiffParser()
        let diff = try parser.parse(diffText)
        #expect(diff.hunks.count == 1)

        let hunk = diff.hunks[0]
        #expect(hunk.header.oldStartLine == 1)
        #expect(hunk.header.oldLineCount == 1)
        #expect(hunk.header.newStartLine == 0)
        #expect(hunk.header.newLineCount == 0)
    }

    // The byte parser keeps JavaScript's string semantics.

    @Test("keeps the header, contents, and expansion types")
    func headerContentsAndExpansion() throws {
        let diffText = #"""
            diff --git a/a b/a
            index 1910281..ba0e162 100644
            --- a/a
            +++ b/a
            @@ -1,2 +1,2 @@
             one
            -two
            +zwei
            @@ -10 +10 @@ section
            -ten
            \ No newline at end of file
            +zehn
            \ No newline at end of file
            @@ -40 +40 @@
            -forty
            +vierzig
            """#
        let diff = try DiffParser().parse(diffText)

        #expect(diff.header == "diff --git a/a b/a\nindex 1910281..ba0e162 100644\n--- a/a\n+++ b/a")
        #expect(diff.contents == "@@ -1,2 +1,2 @@\n one\n-two\n+zwei\n@@ -10 +10 @@ section\n-ten\n+zehn\n@@ -40 +40 @@\n-forty\n+vierzig")
        #expect(diff.hunks.map(\.expansionType) == [.none, .short, .both])
        #expect(diff.hunks.map(\.unifiedDiffStart) == [0, 4, 7])
        #expect(diff.maxLineNumber == 40)
        #expect(!diff.hasHiddenBidiChars)
    }

    @Test("the largest line number is the largest old or new one, wherever it is")
    func largestLineNumber() throws {
        let deletions = (1...12).map { "-old\($0)" }
        let diffText = (["--- a/a", "+++ b/a", "@@ -1,12 +1,2 @@"] + deletions + ["+new1", "+new2"]).joined(separator: "\n")
        let diff = try DiffParser().parse(diffText)
        #expect(diff.maxLineNumber == 12)
    }

    @Test("decodes invalid UTF-8 per line as Node decodes the whole buffer")
    func invalidUTF8() throws {
        var bytes = Data("--- a/a\n+++ b/a\n@@ -1 +1 @@\n-caf".utf8)
        bytes.append(contentsOf: [0xC3])
        bytes.append(contentsOf: Data("\n+caf\u{E9} \u{202E}\r\n".utf8))

        let diff = try DiffParser().parse(bytes)
        #expect(diff.hunks[0].lines.map(\.text) == ["@@ -1 +1 @@", "-caf\u{FFFD}", "+caf\u{E9} \u{202E}\r"])
        #expect(diff.contents == "@@ -1 +1 @@\n-caf\u{FFFD}\n+caf\u{E9} \u{202E}\r")
        #expect(diff.hasHiddenBidiChars)
        #expect(containsHiddenBidiChars("x\u{2069}"))
        #expect(!containsHiddenBidiChars("x\u{2065}\u{202F}"))
    }

    @Test("rejects malformed diffs", arguments: [
        // An empty hunk.
        "--- a/a\n+++ b/a\n@@ -1 +1 @@\n",
        // A bad hunk header.
        "--- a/a\n+++ b/a\n@@ -1 +x @@\n+a\n",
        "--- a/a\n+++ b/a\n@@ -1, +1 @@\n+a\n",
        // A "no newline" marker shorter than 12 UTF-16 code units, even
        // though it's 12 bytes long.
        "--- a/a\n+++ b/a\n@@ -1 +1 @@\n+a\n\\ \u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\n",
        // A blank line inside the diff, which git never writes.
        "--- a/a\n+++ b/a\n@@ -1 +1 @@\n+a\n\n+b\n",
        // A second file's patch.
        "--- a/a\n+++ b/a\n@@ -1 +1 @@\n+a\ndiff --git a/b b/b\n",
    ])
    func rejectsMalformedDiffs(_ text: String) {
        #expect(throws: GitLibError.self) {
            _ = try DiffParser().parse(text)
        }
    }

    // A regression bound, not a benchmark: parsing 40 times the hunks takes
    // about 40 times the work, and only something like quadratic work could
    // take 6 times that. Work is CPU time on this thread, the least of a
    // few runs, which other work on the machine doesn't add to.
    @Test("parses a 5 MB diff in linear time")
    func largeDiffBound() throws {
        func diff(hunks: Int) -> Data {
            var text = "diff --git a/big b/big\n--- a/big\n+++ b/big\n"
            for hunk in 0..<hunks {
                text += "@@ -\(hunk * 100 + 1),50 +\(hunk * 100 + 1),50 @@ context\n"
                for line in 0..<25 {
                    text += " unchanged line \(line) with some text to make it longer\n"
                    text += line.isMultiple(of: 2) ? "-removed \(line) \u{E9}\u{6F22}\n" : "+added \(line)\n"
                }
                text += "\\ No newline at end of file\n"
            }
            return Data(text.utf8)
        }
        let large = diff(hunks: 3000)
        let small = diff(hunks: 75)
        #expect(large.count > 5_000_000)

        var hunkCount = 0
        let largeTime = try leastThreadCPUTime(runs: 3) {
            hunkCount = try DiffParser().parse(large).hunks.count
        }
        let smallTime = try leastThreadCPUTime(runs: 5) {
            _ = try DiffParser().parse(small)
        }

        #expect(hunkCount == 3000)
        #expect(largeTime < smallTime * 40 * 6, "parsing 3,000 hunks took \(largeTime), 75 hunks \(smallTime)")
    }

    @Test("parses hunk headers with large and zero counts")
    func hunkHeaderNumbers() throws {
        let diff = try DiffParser().parse("+++ b/a\n@@ -0,0 +123456,2 @@ heading @@ more\n+a\n+b\n")
        #expect(diff.hunks[0].header == DiffHunkHeader(oldStartLine: 0, oldLineCount: 0, newStartLine: 123456, newLineCount: 2))
        #expect(diff.hunks[0].header.toDiffLineRepresentation() == "@@ -0,0 +123456,2 @@")
        #expect(diff.hunks[0].lines[1].newLineNumber == 123456)
    }
}
