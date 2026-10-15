// Ported from desktop/app/test/unit/patch-formatter-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private func parseDiff(_ diff: String) async throws -> TextDiff {
    let parser = DiffParser()
    let rawDiff = try parser.parse(diff)
    let repository = Repository(path: "")
    let fileChange = PlainFileChange("file.txt", .modified())
    let output = try await convertDiff(repository, fileChange, rawDiff, "HEAD", "HEAD")
    #expect(output.kind == .text)
    guard case .text(let textDiff) = output else {
        throw TestSupportError("Expected a text diff")
    }
    return textDiff
}

/// The working directory diff of `file`, which must be a text diff.
private func getTextDiff(_ repository: Repository, _ file: WorkingDirectoryFileChange) async throws -> TextDiff {
    let diff = try await getWorkingDirectoryDiff(repository, file)
    #expect(diff.kind == .text)
    guard case .text(let textDiff) = diff else {
        throw TestSupportError("Expected a text diff")
    }
    return textDiff
}

/// A repository whose file.txt has `head` committed and `working` in the
/// working copy, with git's diffs showing `context` lines of context
/// (`diff.context`), and the file's change and diff.
private func setupChangedFile(
    head: String,
    working: String,
    context: Int
) async throws -> (Repository, WorkingDirectoryFileChange, TextDiff) {
    let repository = try setupEmptyRepository()
    try await setupLocalConfig(repository, [("diff.context", "\(context)")])
    try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file.txt", contents: head)]))
    try Data(working.utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "file.txt")))
    let status = try await getStatusOrThrow(repository)
    let file = try #require(status.workingDirectory.files.first)
    return (repository, file, try await getTextDiff(repository, file))
}

/// The selection of `lines` (each once, as the diff shows them, "+" or "-"
/// first) in `diff`.
private func selection(of lines: [String], in diff: TextDiff) -> DiffSelection {
    var selection = DiffSelection.fromInitialSelection(.none)
    var remaining = lines
    for hunk in diff.hunks {
        for (index, line) in hunk.lines.enumerated() where line.isIncludeableLine() {
            if let found = remaining.firstIndex(of: line.text) {
                remaining.remove(at: found)
                selection = selection.withLineSelection(hunk.unifiedDiffStart + index, selected: true)
            }
        }
    }
    #expect(remaining.isEmpty, "Lines not in the diff: \(remaining)")
    return selection
}

/// file.txt in the index.
private func stagedContents(_ repository: Repository) async throws -> String {
    String(decoding: try await Dugite.exec(["show", ":file.txt"], repository.path).stdout, as: UTF8.self)
}

/// file.txt in the working copy.
private func workingContents(_ repository: Repository) throws -> String {
    String(decoding: try Data(contentsOf: URL(filePath: POSIXPath.join(repository.path, "file.txt"))), as: UTF8.self)
}

/// `lines`, each ended by a newline.
private func text(_ lines: [String]) -> String {
    lines.map { "\($0)\n" }.joined()
}

/// The numbers of `range`, as lines.
private func numbers(_ range: ClosedRange<Int>) -> [String] {
    range.map(String.init)
}

@Suite("patch formatting")
struct PatchFormatterTests {
    @Suite("formatPatchesForModifiedFile")
    struct FormatPatchesForModifiedFile {
        // modified-file.md's three hunks are "@@ -4,10 +4,6 @@",
        // "@@ -21,6 +17,10 @@", and "@@ -31,3 +31,8 @@". Each case starts
        // from every line selected, deselects whole hunks, and checks that
        // the patch has exactly the hunks still selected, each starting on
        // the new side where it lands without the hunks left out.
        @Test("creates right patch when hunks are deselected", arguments: [
            // Only the first hunk is selected; deselecting only the second hunk
            // would leave the first hunk's header in the patch whatever the
            // selection.
            NamedCase("creates right patch when first hunk is selected", (
                deselectedHunks: [1, 2],
                expectedHunkHeaders: ["@@ -4,10 +4,6 @@"]
            )),
            NamedCase("creates right patch when second hunk is selected", (
                deselectedHunks: [0],
                expectedHunkHeaders: ["@@ -21,6 +21,10 @@", "@@ -31,3 +35,8 @@"]
            )),
            NamedCase("creates right patch when first and third hunk is selected", (
                deselectedHunks: [1],
                expectedHunkHeaders: ["@@ -4,10 +4,6 @@", "@@ -31,3 +27,8 @@"]
            )),
        ])
        func hunkSelection(_ testCase: NamedCase<(deselectedHunks: [Int], expectedHunkHeaders: [String])>) async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let modifiedFile = "modified-file.md"

            let unselectedFile = DiffSelection.fromInitialSelection(.none)
            let file = WorkingDirectoryFileChange(path: modifiedFile, status: .modified(), selection: unselectedFile)

            let textDiff = try await getTextDiff(repository, file)

            var selection = DiffSelection.fromInitialSelection(.all)
            for index in testCase.value.deselectedHunks {
                // The whole hunk: its last line is at unifiedDiffEnd.
                let hunk = textDiff.hunks[index]
                selection = selection.withRangeSelection(
                    from: hunk.unifiedDiffStart,
                    length: hunk.unifiedDiffEnd - hunk.unifiedDiffStart + 1,
                    selected: false
                )
            }

            let updatedFile = WorkingDirectoryFileChange(path: modifiedFile, status: .modified(), selection: selection)

            let patch = try formatPatch(updatedFile, textDiff)

            #expect(patch.hasPrefix("--- a/modified-file.md\n+++ b/modified-file.md\n"))
            #expect(patch.split(separator: "\n").filter { $0.hasPrefix("@@") } == testCase.value.expectedHunkHeaders.map { Substring($0) })
        }

        @Test("creates the right patch when an addition is selected but preceding deletions aren't")
        func additionSelectedButNotDeletions() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let modifiedFile = "modified-file.md"
            try Data("line 1\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, modifiedFile)))

            let unselectedFile = DiffSelection.fromInitialSelection(.none)
            let file = WorkingDirectoryFileChange(path: modifiedFile, status: .modified(), selection: unselectedFile)

            let textDiff = try await getTextDiff(repository, file)

            var selection = DiffSelection.fromInitialSelection(.all)
            let hunk = textDiff.hunks[0]
            for (index, line) in hunk.lines.enumerated() {
                let absoluteIndex = hunk.unifiedDiffStart + index
                if line.text == "+line 1" {
                    selection = selection.withLineSelection(absoluteIndex, selected: true)
                } else {
                    selection = selection.withLineSelection(absoluteIndex, selected: false)
                }
            }

            let updatedFile = WorkingDirectoryFileChange(path: modifiedFile, status: .modified(), selection: selection)

            let patch = try formatPatch(updatedFile, textDiff)
            // The expected patch, one line per element: several lines are a
            // single space.
            let expectedPatch = [
                "--- a/modified-file.md",
                "+++ b/modified-file.md",
                "@@ -1,33 +1,34 @@",
                " Lorem ipsum dolor sit amet, consectetur adipiscing elit. Cras mi urna,",
                " ullamcorper sit amet tellus eget, congue ornare leo. Donec dapibus sem quis sem",
                " commodo, id ultricies ligula varius. Vestibulum ante ipsum primis in faucibus",
                " orci luctus et ultrices posuere cubilia Curae; Maecenas efficitur lacus ac",
                " tortor placerat facilisis. Ut sed ex tortor. Duis consectetur at ex vel mattis.",
                " ",
                " Aliquam leo ipsum, laoreet sed libero at, mollis pulvinar arcu. Nullam porttitor",
                " nisl eget hendrerit vestibulum. Curabitur ornare id neque ac tristique. Cras in",
                " eleifend mi.",
                " ",
                " Donec sit amet posuere nibh, sed laoreet nisl. Pellentesque a consectetur",
                " turpis. Curabitur varius ex nisi, vitae vestibulum augue cursus sit amet. Morbi",
                " non vestibulum velit. Integer consectetur lacus vitae erat pellentesque",
                " tincidunt. Nullam id nunc rhoncus, ultrices orci bibendum, blandit orci. Morbi",
                " vitae accumsan metus, et cursus diam. Sed mi augue, sollicitudin imperdiet",
                " semper ac, scelerisque vitae nulla. Nam cursus est massa, et tincidunt lectus",
                " consequat vel. Nunc commodo elementum metus, vel pellentesque est efficitur sit",
                " amet. Aliquam rhoncus, diam vel pulvinar eleifend, massa tellus lobortis elit,",
                " quis cursus justo tellus vel magna. Quisque placerat nunc non nibh porttitor,",
                " vel sagittis nisl rutrum. Proin enim augue, condimentum sit amet suscipit id,",
                " tempor a ligula. Proin pretium ipsum vel nulla sollicitudin mollis. Morbi",
                " elementum neque id tellus gravida rhoncus.",
                " ",
                " Ut fringilla, orci id consequat sodales, tellus tellus interdum risus, eleifend",
                " vestibulum velit nunc sit amet nulla. Ut tristique, diam ut rhoncus commodo,",
                " libero tellus maximus ex, vel rutrum mauris purus vel enim. Donec accumsan nulla",
                "  id purus lacinia venenatis. Phasellus convallis ex et vulputate aliquet. Ut",
                "  porttitor diam magna, vel porttitor tortor ornare et. Suspendisse eleifend",
                "  sagittis tempus. Pellentesque mollis dolor id lectus lobortis vulputate. Etiam",
                "  eu lacus sit amet mauris ornare dictum. Integer erat nisi, semper ut augue",
                "  vitae, cursus pulvinar lorem. Suspendisse potenti. Mauris eleifend elit ac",
                "  sodales posuere. Cras ultrices, ex in porta volutpat, libero sapien blandit",
                "  urna, ac porta justo leo sed magna.",
                "+line 1",
                "",
            ].joined(separator: "\n")
            #expect(patch == expectedPatch)
        }

        @Test("doesn't include unselected added lines as context")
        func unselectedAddedLinesNotContext() async throws {
            let rawDiff = [
                "--- a/file.md",
                "+++ b/file.md",
                "@@ -10,2 +10,4 @@",
                " context",
                "+added line 1",
                "+added line 2",
                " context",
            ].joined(separator: "\n")

            let diff = try await parseDiff(rawDiff)

            // Select the second added line
            let selection = DiffSelection.fromInitialSelection(.none).withLineSelection(3, selected: true)

            let file = WorkingDirectoryFileChange(path: "file.md", status: .modified(), selection: selection)
            let patch = try formatPatch(file, diff)

            #expect(patch == """
                --- a/file.md
                +++ b/file.md
                @@ -10,2 +10,3 @@
                 context
                +added line 2
                 context

                """)
        }

        @Test("rewrites hunk header when necessary")
        func rewritesHunkHeader() async throws {
            let rawDiff = [
                "--- /dev/null",
                "+++ b/file.md",
                "@@ -0,2 +1,2 @@",
                "+added line 1",
                "+added line 2",
            ].joined(separator: "\n")
            let diff = try await parseDiff(rawDiff)

            // Select the second added line
            let selection = DiffSelection.fromInitialSelection(.none).withLineSelection(2, selected: true)

            let file = WorkingDirectoryFileChange(path: "file.md", status: .new(), selection: selection)
            let patch = try formatPatch(file, diff)

            #expect(patch.contains("@@ -0,0 +1 @@"))
            #expect(patch.contains("+added line 2"))
        }

        @Test("includes empty context lines")
        func includesEmptyContextLines() async throws {
            let rawDiff = [
                "--- a/file.md",
                "+++ b/file.md",
                "@@ -1 +1,2 @@",
                " ",
                "+added line 2",
            ].joined(separator: "\n")
            let diff = try await parseDiff(rawDiff)

            // Select the second added line
            let selection = DiffSelection.fromInitialSelection(.none).withLineSelection(2, selected: true)

            let file = WorkingDirectoryFileChange(path: "file.md", status: .modified(), selection: selection)
            let patch = try formatPatch(file, diff)

            #expect(patch.contains("@@ -1 +1,2 @@"))
            #expect(patch.contains(" "))
            #expect(patch.contains("+added line 2"))
        }

        @Test("creates the right patch when a `No newline` marker is involved")
        func noNewlineMarker() async throws {
            let rawDiff = [
                "--- a/file.md",
                "+++ b/file.md",
                "@@ -23,5 +24,5 @@ and more stuff",
                " ",
                " ",
                " ",
                "-",
                "-and fun stuff? I dnno",
                "\\ No newline at end of file",
                "+and fun stuff? I dnno",
                "+it could be,",
            ].joined(separator: "\n")
            let diff = try await parseDiff(rawDiff)

            // Select the second added line
            let selection = DiffSelection.fromInitialSelection(.none).withLineSelection(7, selected: true)

            let file = WorkingDirectoryFileChange(path: "file.md", status: .modified(), selection: selection)

            let patch = try formatPatch(file, diff)

            // The old last line stays, now followed by a line, so it gains
            // its newline: git would otherwise join the next line to it.
            #expect(patch == """
                --- a/file.md
                +++ b/file.md
                @@ -23,5 +23,6 @@
                \u{20}
                \u{20}
                \u{20}
                \u{20}
                -and fun stuff? I dnno
                \\ No newline at end of file
                +and fun stuff? I dnno
                +it could be,

                """)
        }
    }

    // A line without a newline ends its file: a selection that puts a line
    // after it gives it one, and one that leaves it last keeps it without,
    // with or without context.
    @Suite("a last line without a newline")
    struct NoTrailingNewline {
        /// HEAD's contents, the working copy's, the lines chosen (as the
        /// diff shows them, "+" or "-" first), and the expected result.
        typealias Case = (head: String, working: String, lines: [String], expected: String)

        @Test("commits the chosen lines without joining any", arguments: [
            NamedCase("lines added after it", (head: "a\nlast", working: "a\nlast\nnew1\nnew2\n", lines: ["+new1", "+new2"], expected: "a\nlast\nnew1\nnew2\n")),
            NamedCase("the first line added after it", (head: "a\nlast", working: "a\nlast\nnew1\nnew2\n", lines: ["+new1"], expected: "a\nlast\nnew1\n")),
            NamedCase("the second line added after it", (head: "a\nlast", working: "a\nlast\nnew1\nnew2\n", lines: ["+new2"], expected: "a\nlast\nnew2\n")),
            NamedCase("its newline alone", (head: "a\nlast", working: "a\nlast\nnew1\nnew2\n", lines: ["-last", "+last"], expected: "a\nlast\n")),
            NamedCase("the new copy of it alone", (head: "a\nlast", working: "a\nlast\nnew1\nnew2\n", lines: ["+last"], expected: "a\nlast\nlast\n")),
            NamedCase("its removal alone", (head: "a\nlast", working: "a\nlast\nnew1\nnew2\n", lines: ["-last"], expected: "a\n")),
            NamedCase("a line added after it, changed but not chosen", (head: "a\nlast", working: "a\nLAST\nnew1\n", lines: ["+new1"], expected: "a\nlast\nnew1\n")),
            NamedCase("its change alone", (head: "a\nlast", working: "a\nLAST\nnew1\n", lines: ["-last", "+LAST"], expected: "a\nLAST\n")),
            NamedCase("its replacement added after it", (head: "a\nlast", working: "a\nLAST\nnew1\n", lines: ["+LAST"], expected: "a\nlast\nLAST\n")),
            NamedCase("its removal and a line added", (head: "a\nlast", working: "a\nLAST\nnew1\n", lines: ["-last", "+new1"], expected: "a\nnew1\n")),
            NamedCase("deleted", (head: "a\nlast", working: "a\n", lines: ["-last"], expected: "a\n")),
            NamedCase("a replacement without a newline added after it", (head: "a\nb", working: "a\nB", lines: ["+B"], expected: "a\nb\nB")),
            NamedCase("its replacement's removal alone", (head: "a\nb", working: "a\nB", lines: ["-b"], expected: "a\n")),
            NamedCase("a new last line without a newline", (head: "a\nlast", working: "a\nlast\nnew1", lines: ["+new1"], expected: "a\nlast\nnew1")),
        ], [0, 3])
        func commit(_ testCase: NamedCase<Case>, context: Int) async throws {
            let value = testCase.value
            let (repository, file, diff) = try await setupChangedFile(head: value.head, working: value.working, context: context)
            try await applyPatchToIndex(repository, file.withSelection(selection(of: value.lines, in: diff)))
            #expect(try await stagedContents(repository) == value.expected)
        }

        @Test("discards the chosen lines without joining any", arguments: [
            NamedCase("lines added after it", (head: "a\nlast", working: "a\nlast\nnew1\nnew2\n", lines: ["+new1", "+new2"], expected: "a\nlast\n")),
            NamedCase("its newline while lines follow it", (head: "a\nlast", working: "a\nlast\nnew1\nnew2\n", lines: ["-last", "+last"], expected: "a\nlast\nnew1\nnew2\n")),
            NamedCase("every change", (head: "a\nlast", working: "a\nlast\nnew1\nnew2\n", lines: ["-last", "+last", "+new1", "+new2"], expected: "a\nlast")),
            NamedCase("its removal alone", (head: "a\nlast", working: "a\nlast\nnew1\nnew2\n", lines: ["-last"], expected: "a\nlast\nlast\nnew1\nnew2\n")),
            NamedCase("its change, keeping a line added after it", (head: "a\nlast", working: "a\nLAST\nnew1\n", lines: ["-last", "+LAST"], expected: "a\nlast\nnew1\n")),
            NamedCase("a line added after its change", (head: "a\nlast", working: "a\nLAST\nnew1\n", lines: ["+new1"], expected: "a\nLAST\n")),
            NamedCase("a new last line without a newline", (head: "a\nb\n", working: "a\nb\nc", lines: ["+c"], expected: "a\nb\n")),
            NamedCase("its removal, keeping its replacement", (head: "a\nb", working: "a\nX", lines: ["-b"], expected: "a\nb\nX")),
            NamedCase("its replacement", (head: "a\nb", working: "a\nX", lines: ["+X"], expected: "a\n")),
        ], [0, 3])
        func discard(_ testCase: NamedCase<Case>, context: Int) async throws {
            let value = testCase.value
            let (repository, _, diff) = try await setupChangedFile(head: value.head, working: value.working, context: context)
            try await discardChangesFromSelection(repository, "file.txt", diff, selection(of: value.lines, in: diff))
            #expect(try workingContents(repository) == value.expected)
        }
    }

    // Each hunk of a patch starts where it lands once the patch's earlier
    // hunks are applied: `git apply` puts a hunk without context at that
    // line, and looks for a hunk's context outward from it.
    @Suite("lines chosen after changes left out")
    struct AfterChangesLeftOut {
        /// HEAD's lines, the working copy's, the lines chosen (as the diff
        /// shows them, "+" or "-" first), and the expected result's lines.
        typealias Case = (head: [String], working: [String], lines: [String], expected: [String])

        /// Six lines that `repeated` has twice, ten lines apart.
        static let block = ["p", "q", "r", "s", "t", "u"]
        /// Ten lines, two copies of `block` ten lines apart, and three more.
        static let repeated = (1...10).map { "b\($0)" } + block + ["m1", "m2", "m3", "m4"] + block + ["e1", "e2", "e3"]
        /// Ten lines added at the top, as many as the copies of `block` are
        /// apart.
        static let top = (1...10).map { "top \($0)" }

        /// Lines that repeat, among them a line of spaces and a tab.
        static let repeatingHead = ["  x", "", " ", "c", "", " ", "", "", " "]
        static let repeatingWorking = ["  x", "", " ", "", "\tt", "", " ", "", "c", " "]

        static let commitCases: [NamedCase<Case>] = [
            NamedCase("a line added after an addition left out", (
                head: numbers(1...12), working: ["1", "X"] + numbers(2...10) + ["Y", "11", "12"],
                lines: ["+Y"], expected: numbers(1...10) + ["Y", "11", "12"]
            )),
            NamedCase("a line added after a removal left out", (
                head: numbers(1...12), working: ["1"] + numbers(3...10) + ["Y", "11", "12"],
                lines: ["+Y"], expected: numbers(1...10) + ["Y", "11", "12"]
            )),
            NamedCase("a line removed after an addition left out", (
                head: numbers(1...12), working: ["X"] + numbers(1...9) + ["11", "12"],
                lines: ["-10"], expected: numbers(1...9) + ["11", "12"]
            )),
            NamedCase("a line added after a hunk partly chosen", (
                head: numbers(1...12), working: ["1", "X1", "X2"] + numbers(2...10) + ["Y", "11", "12"],
                lines: ["+X2", "+Y"], expected: ["1", "X2"] + numbers(2...10) + ["Y", "11", "12"]
            )),
            NamedCase("a line added at the end after a removal left out", (
                head: numbers(1...12), working: ["1"] + numbers(3...12) + ["Z"],
                lines: ["+Z"], expected: numbers(1...12) + ["Z"]
            )),
            NamedCase("a line added in a block repeated further on", (
                head: repeated, working: top + repeated[..<13] + ["X"] + repeated[13...],
                lines: ["+X"], expected: Array(repeated[..<13]) + ["X"] + repeated[13...]
            )),
            NamedCase("lines among lines that repeat", (
                head: repeatingHead, working: repeatingWorking,
                lines: ["-c", "- ", "+c"], expected: ["  x", "", " ", "", "", "", "c", " "]
            )),
        ]

        static let discardCases: [NamedCase<Case>] = [
            NamedCase("a removed line after an addition kept", (
                head: numbers(1...12), working: ["X"] + numbers(1...9) + ["11", "12"],
                lines: ["-10"], expected: ["X"] + numbers(1...12)
            )),
            NamedCase("a removed line after a removal kept", (
                head: numbers(1...12), working: ["1"] + numbers(3...9) + ["11", "12"],
                lines: ["-10"], expected: ["1"] + numbers(3...12)
            )),
            NamedCase("an added line after an addition kept", (
                head: numbers(1...12), working: ["X"] + numbers(1...10) + ["Y", "11", "12"],
                lines: ["+Y"], expected: ["X"] + numbers(1...12)
            )),
            NamedCase("a removed line after a hunk partly discarded", (
                head: numbers(1...12), working: ["1", "X1", "X2"] + numbers(2...9) + ["11", "12"],
                lines: ["+X2", "-10"], expected: ["1", "X1"] + numbers(2...12)
            )),
            NamedCase("a removed last line after an addition kept", (
                head: numbers(1...12), working: ["X"] + numbers(1...11),
                lines: ["-12"], expected: ["X"] + numbers(1...12)
            )),
            NamedCase("a removed line in a block repeated earlier on", (
                head: Array(repeated[..<23]) + ["X"] + repeated[23...], working: top + repeated,
                lines: ["-X"], expected: top + repeated[..<23] + ["X"] + repeated[23...]
            )),
            NamedCase("lines among lines that repeat", (
                head: repeatingHead, working: repeatingWorking,
                lines: ["-c", "- ", "+c"], expected: ["  x", "", " ", "c", "", " ", "\tt", "", " ", "", " "]
            )),
        ]

        @Test("commits the chosen lines in their place", arguments: Self.commitCases, [0, 3])
        func commit(_ testCase: NamedCase<Case>, context: Int) async throws {
            let value = testCase.value
            let (repository, file, diff) = try await setupChangedFile(head: text(value.head), working: text(value.working), context: context)
            try await applyPatchToIndex(repository, file.withSelection(selection(of: value.lines, in: diff)))
            #expect(try await stagedContents(repository) == text(value.expected))
        }

        @Test("discards the chosen lines in their place", arguments: Self.discardCases, [0, 3])
        func discard(_ testCase: NamedCase<Case>, context: Int) async throws {
            let value = testCase.value
            let (repository, _, diff) = try await setupChangedFile(head: text(value.head), working: text(value.working), context: context)
            try await discardChangesFromSelection(repository, "file.txt", diff, selection(of: value.lines, in: diff))
            #expect(try workingContents(repository) == text(value.expected))
        }

        @Test("commits and discards every choice of lines in place", arguments: [
            NamedCase("lines that repeat", (head: Self.repeatingHead, working: Self.repeatingWorking)),
            NamedCase("changes at the top, middle, and end", (
                head: numbers(1...12), working: ["X"] + numbers(1...4) + numbers(6...8) + ["Y"] + numbers(9...11) + ["Z"]
            )),
        ], [0, 1, 3])
        func everyChoice(_ testCase: NamedCase<(head: [String], working: [String])>, context: Int) async throws {
            let (head, working) = testCase.value
            let (repository, file, diff) = try await setupChangedFile(head: text(head), working: text(working), context: context)
            let changes = diff.hunks.flatMap { hunk in
                hunk.lines.indices.filter { hunk.lines[$0].isIncludeableLine() }.map { hunk.unifiedDiffStart + $0 }
            }
            #expect(changes.count == 5)

            for choice in 0..<(1 << changes.count) {
                let chosen = Set(changes.indices.filter { choice & (1 << $0) != 0 }.map { changes[$0] })
                let selection = chosen.reduce(DiffSelection.fromInitialSelection(.none)) {
                    $0.withLineSelection($1, selected: true)
                }

                _ = try await Dugite.exec(["reset", "-q"], repository.path)
                try await applyPatchToIndex(repository, file.withSelection(selection))
                #expect(
                    try await stagedContents(repository) == text(changed(head, by: diff, chosen, discarding: false)),
                    "Committing choice \(choice)"
                )

                try await discardChangesFromSelection(repository, "file.txt", diff, selection)
                #expect(
                    try workingContents(repository) == text(changed(working, by: diff, chosen, discarding: true)),
                    "Discarding choice \(choice)"
                )
                try Data(text(working).utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "file.txt")))
            }
        }

        /// `lines`, one side of `diff`, with the changes at `chosen` (indexes
        /// of the diff's lines) made: committing, the old side's lines with
        /// the chosen removals removed and the chosen additions added;
        /// discarding, the new side's with the chosen additions removed and
        /// the chosen removals added back.
        private func changed(_ lines: [String], by diff: TextDiff, _ chosen: Set<Int>, discarding: Bool) -> [String] {
            var result: [String] = []
            // The next line of `lines` to copy.
            var next = 0
            for hunk in diff.hunks {
                let (start, count) = discarding
                    ? (hunk.header.newStartLine, hunk.header.newLineCount)
                    : (hunk.header.oldStartLine, hunk.header.oldLineCount)
                // A side with no lines starts at the line before them.
                let first = count == 0 ? start : start - 1
                result += lines[next..<first]
                next = first
                for (index, line) in hunk.lines.enumerated() {
                    let text = String(line.text.dropFirst())
                    let isChosen = chosen.contains(hunk.unifiedDiffStart + index)
                    switch line.type {
                    case .context:
                        result.append(text)
                        next += 1
                    case .delete where discarding, .add where !discarding:
                        // A line of the other side: there only if chosen.
                        if isChosen {
                            result.append(text)
                        }
                    case .delete, .add:
                        // A line of `lines`: kept unless chosen.
                        if !isChosen {
                            result.append(text)
                        }
                        next += 1
                    case .hunk:
                        break
                    }
                }
            }
            return result + lines[next...]
        }
    }

    // Discarding is formatPatch's mirror image.
    @Suite("formatPatchToDiscardChanges")
    struct FormatPatchToDiscardChanges {
        @Test("reverses selected lines and keeps unselected additions as context")
        func reversesSelection() async throws {
            let rawDiff = [
                "--- a/file.md",
                "+++ b/file.md",
                "@@ -10,3 +10,3 @@",
                " context",
                "-removed",
                "+added 1",
                "+added 2",
            ].joined(separator: "\n")
            let diff = try await parseDiff(rawDiff)

            let selection = DiffSelection.fromInitialSelection(.none)
                .withLineSelection(2, selected: true)
                .withLineSelection(4, selected: true)

            #expect(formatPatchToDiscardChanges("file.md", diff, selection) == """
                --- a/file.md
                +++ b/file.md
                @@ -10,3 +10,3 @@
                 context
                +removed
                 added 1
                -added 2

                """)
            #expect(formatPatchToDiscardChanges("file.md", diff, .fromInitialSelection(.none)) == nil)
        }
    }

    @Suite("patch header paths")
    struct HeaderPaths {
        @Test("quotes paths with control characters, quotes, or backslashes as git does (desktop didn't)")
        func quoting() {
            #expect(quotePatchPath("a/plain name.txt") == "a/plain name.txt")
            #expect(quotePatchPath("a/caf\u{E9}.txt") == "a/caf\u{E9}.txt")
            #expect(quotePatchPath("a/tab\tname.txt") == #""a/tab\tname.txt""#)
            #expect(quotePatchPath("a/new\nline.txt") == #""a/new\nline.txt""#)
            #expect(quotePatchPath("a/say \"hi\".txt") == #""a/say \"hi\".txt""#)
            #expect(quotePatchPath("a/back\\slash.txt") == #""a/back\\slash.txt""#)
            #expect(quotePatchPath("a/bell\u{07}\u{01}\u{7F}.txt") == #""a/bell\a\001\177.txt""#)
        }

        @Test("a patch for a path with a tab or a newline applies")
        func applies() async throws {
            for name in ["tab\tname.txt", "new\nline.txt"] {
                let repository = try setupEmptyRepository()
                let path = POSIXPath.join(repository.path, name)
                try Data("one\ntwo\n".utf8).write(to: URL(filePath: path))
                _ = try await Dugite.exec(["add", "--", name], repository.path)
                _ = try await Dugite.exec(["commit", "-m", "Add"], repository.path)
                try Data("one\nthree\n".utf8).write(to: URL(filePath: path))
                let status = try await getStatusOrThrow(repository)
                let file = try #require(status.workingDirectory.files.first)
                #expect(file.path == name)
                let diff = try await getTextDiff(repository, file.withIncludeAll(true))

                // The whole change, staged through a patch.
                let patch = try formatPatch(file.withIncludeAll(true), diff)
                #expect(patch.hasPrefix("--- \"a/"))
                try await applyPatchToIndex(repository, file.withSelection(file.selection.withLineSelection(2, selected: true)))
                let staged = try await Dugite.exec(["diff", "--cached", "--name-only", "-z"], repository.path)
                #expect(String(decoding: staged.stdout, as: UTF8.self) == "\(name)\0")

                // And discarded from the working file through one.
                _ = try await Dugite.exec(["reset", "-q"], repository.path)
                try await discardChangesFromSelection(repository, name, diff, .fromInitialSelection(.all))
                #expect(try String(contentsOfFile: path, encoding: .utf8) == "one\ntwo\n")
            }
        }
    }
}
