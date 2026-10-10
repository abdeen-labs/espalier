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

@Suite("patch formatting")
struct PatchFormatterTests {
    @Suite("formatPatchesForModifiedFile")
    struct FormatPatchesForModifiedFile {
        // modified-file.md's three hunks are "@@ -4,10 +4,6 @@",
        // "@@ -21,6 +17,10 @@", and "@@ -31,3 +31,8 @@". Each case starts
        // from every line selected, deselects whole hunks, and checks that
        // the patch has exactly the hunks still selected.
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
                expectedHunkHeaders: ["@@ -21,6 +17,10 @@", "@@ -31,3 +31,8 @@"]
            )),
            NamedCase("creates right patch when first and third hunk is selected", (
                deselectedHunks: [1],
                expectedHunkHeaders: ["@@ -4,10 +4,6 @@", "@@ -31,3 +31,8 @@"]
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

            #expect(patch.contains("\\ No newline at end of file"))
            #expect(patch.contains("+it could be"))
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
