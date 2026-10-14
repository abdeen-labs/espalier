// Ported from desktop/app/test/unit/copilot-conflict-context-test.ts

@testable import AIKit
import Foundation
import Testing
import TestSupport

/// Promotes a file-level context into the resolution context the formatter
/// expects, defaulting the commit and pull request fields to empty.
private func toResolutionContext(
    _ context: AIConflictContext,
    pullRequests: [ConflictContextPullRequest] = [],
    ourCommits: [ConflictContextCommit] = [],
    theirCommits: [ConflictContextCommit] = []
) -> ConflictResolutionContext {
    ConflictResolutionContext(context, pullRequests: pullRequests, ourCommits: ourCommits, theirCommits: theirCommits)
}

private func makeContextCommit(_ shortSha: String, _ summary: String) -> ConflictContextCommit {
    ConflictContextCommit(
        sha: shortSha.padding(toLength: 40, withPad: "0", startingAt: 0),
        shortSha: shortSha,
        summary: summary,
        isOnRemote: false
    )
}

private func makeContextPr(_ number: Int, _ title: String, _ body: String) -> ConflictContextPullRequest {
    ConflictContextPullRequest(number: number, title: title, body: body)
}

private func hunk(
    _ ours: String,
    _ theirs: String,
    base: String? = nil,
    before: String = "",
    after: String = ""
) -> ConflictHunk {
    ConflictHunk(oursContent: ours, theirsContent: theirs, baseContent: base, contextBefore: before, contextAfter: after)
}

private func context(_ files: [FileConflictContext], ours: String = "main", theirs: String = "feature") -> AIConflictContext {
    AIConflictContext(ourLabel: ours, theirLabel: theirs, files: files)
}

@Suite("copilot-conflict-context: extractConflictHunks")
struct ExtractConflictHunksTests {
    @Test("handles CRLF line endings (Windows)")
    func crlf() {
        let content = ["line before", "<<<<<<< HEAD", "our change", "=======", "their change", ">>>>>>> feature", "line after"]
            .joined(separator: "\r\n")

        let hunks = extractConflictHunks(content)

        #expect(hunks.count == 1)
        #expect(hunks[0].oursContent == "our change")
        #expect(hunks[0].theirsContent == "their change")
        #expect(hunks[0].baseContent == nil)
    }

    @Test("does not bleed conflict markers into context lines")
    func noMarkerBleed() {
        let content = [
            "start", "<<<<<<< HEAD", "ours-1", "=======", "theirs-1", ">>>>>>> feature",
            "middle", "<<<<<<< HEAD", "ours-2", "=======", "theirs-2", ">>>>>>> feature", "end",
        ].joined(separator: "\n")

        let hunks = extractConflictHunks(content, contextLines: 5)

        #expect(hunks.count == 2)
        // The first hunk's contextAfter stops before the next <<<<<<< marker.
        #expect(hunks[0].contextAfter == "middle")
        #expect(!hunks[0].contextAfter.contains("<<<<<<<"))
        // The second hunk's contextBefore stops after the previous >>>>>>> marker.
        #expect(hunks[1].contextBefore == "middle")
        #expect(!hunks[1].contextBefore.contains(">>>>>>>"))
    }

    @Test("extracts a standard two-way conflict hunk")
    func twoWay() {
        let content = ["line before", "<<<<<<< HEAD", "our change", "=======", "their change", ">>>>>>> feature", "line after"]
            .joined(separator: "\n")

        let hunks = extractConflictHunks(content)

        #expect(hunks.count == 1)
        #expect(hunks[0].oursContent == "our change")
        #expect(hunks[0].theirsContent == "their change")
        #expect(hunks[0].baseContent == nil)
    }

    @Test("extracts a diff3 three-way conflict hunk")
    func threeWay() {
        let content = [
            "unchanged", "<<<<<<< HEAD", "our version", "||||||| merged common ancestors", "original version",
            "=======", "their version", ">>>>>>> feature", "more unchanged",
        ].joined(separator: "\n")

        let hunks = extractConflictHunks(content)

        #expect(hunks.count == 1)
        #expect(hunks[0].oursContent == "our version")
        #expect(hunks[0].baseContent == "original version")
        #expect(hunks[0].theirsContent == "their version")

        // Multi-line base content is preserved.
        let multiLineBase = [
            "<<<<<<< HEAD", "ours", "||||||| base", "base line 1", "base line 2", "=======", "theirs", ">>>>>>> feature",
        ].joined(separator: "\n")

        let hunks2 = extractConflictHunks(multiLineBase)
        #expect(hunks2.count == 1)
        #expect(hunks2[0].baseContent == "base line 1\nbase line 2")
    }

    @Test("extracts multiple conflict hunks from one file")
    func multipleHunks() {
        let content = [
            "start", "<<<<<<< HEAD", "ours-1", "=======", "theirs-1", ">>>>>>> feature",
            "middle", "<<<<<<< HEAD", "ours-2", "=======", "theirs-2", ">>>>>>> feature", "end",
        ].joined(separator: "\n")

        let hunks = extractConflictHunks(content)

        #expect(hunks.count == 2)
        #expect(hunks[0].oursContent == "ours-1")
        #expect(hunks[0].theirsContent == "theirs-1")
        #expect(hunks[1].oursContent == "ours-2")
        #expect(hunks[1].theirsContent == "theirs-2")
    }

    @Test("returns an empty array when no conflict markers are present")
    func noMarkers() {
        #expect(extractConflictHunks("just a normal file\nwith no conflicts\n").isEmpty)
    }

    @Test("includes surrounding context lines and respects contextLines parameter")
    func contextLines() {
        let content = [
            "line 1", "line 2", "line 3", "line 4", "<<<<<<< HEAD", "our change", "=======", "their change",
            ">>>>>>> feature", "line 5", "line 6", "line 7", "line 8",
        ].joined(separator: "\n")

        // Default-like: 3 context lines.
        let hunks3 = extractConflictHunks(content, contextLines: 3)
        #expect(hunks3.count == 1)
        #expect(hunks3[0].contextBefore == "line 2\nline 3\nline 4")
        #expect(hunks3[0].contextAfter == "line 5\nline 6\nline 7")

        // Custom: 1 context line.
        let hunks1 = extractConflictHunks(content, contextLines: 1)
        #expect(hunks1.count == 1)
        #expect(hunks1[0].contextBefore == "line 4")
        #expect(hunks1[0].contextAfter == "line 5")
    }

    @Test("handles zero context lines")
    func zeroContextLines() {
        let content = ["line before", "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> feature", "line after"]
            .joined(separator: "\n")

        let hunks = extractConflictHunks(content, contextLines: 0)

        #expect(hunks.count == 1)
        #expect(hunks[0].contextBefore == "")
        #expect(hunks[0].contextAfter == "")
    }

    @Test("handles conflict markers at the start of the file")
    func markersAtStart() {
        let content = ["<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> feature", "after"].joined(separator: "\n")

        let hunks = extractConflictHunks(content)

        #expect(hunks.count == 1)
        #expect(hunks[0].contextBefore == "")
        #expect(hunks[0].oursContent == "ours")
        #expect(hunks[0].theirsContent == "theirs")
        #expect(hunks[0].contextAfter == "after")
    }

    @Test("handles conflict markers at the end of the file")
    func markersAtEnd() {
        let content = ["before", "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> feature"].joined(separator: "\n")

        let hunks = extractConflictHunks(content)

        #expect(hunks.count == 1)
        #expect(hunks[0].contextBefore == "before")
        #expect(hunks[0].oursContent == "ours")
        #expect(hunks[0].theirsContent == "theirs")
        #expect(hunks[0].contextAfter == "")
    }

    @Test("handles multi-line content in each section")
    func multiLineSections() {
        let content = [
            "<<<<<<< HEAD", "our line 1", "our line 2", "our line 3", "=======", "their line 1", "their line 2",
            ">>>>>>> feature",
        ].joined(separator: "\n")

        let hunks = extractConflictHunks(content)

        #expect(hunks.count == 1)
        #expect(hunks[0].oursContent == "our line 1\nour line 2\nour line 3")
        #expect(hunks[0].theirsContent == "their line 1\ntheir line 2")
    }

    @Test("handles empty ours content")
    func emptyOurs() {
        let hunks = extractConflictHunks(["<<<<<<< HEAD", "=======", "their change", ">>>>>>> feature"].joined(separator: "\n"))

        #expect(hunks.count == 1)
        #expect(hunks[0].oursContent == "")
        #expect(hunks[0].theirsContent == "their change")
    }

    @Test("handles empty theirs content")
    func emptyTheirs() {
        let hunks = extractConflictHunks(["<<<<<<< HEAD", "our change", "=======", ">>>>>>> feature"].joined(separator: "\n"))

        #expect(hunks.count == 1)
        #expect(hunks[0].oursContent == "our change")
        #expect(hunks[0].theirsContent == "")
    }

    @Test("does not treat markers inside content as boundaries")
    func markersInsideContent() {
        // Conflict markers must start at column 0 with exactly 7 characters.
        let content = [
            "<<<<<<< HEAD", #"const s = "<<<<<<< not a real marker""#, "=======", #"const s = ">>>>>>> also not real""#,
            ">>>>>>> feature",
        ].joined(separator: "\n")

        let hunks = extractConflictHunks(content)

        #expect(hunks.count == 1)
        #expect(hunks[0].oursContent == #"const s = "<<<<<<< not a real marker""#)
        #expect(hunks[0].theirsContent == #"const s = ">>>>>>> also not real""#)
    }

    @Test("skips a malformed hunk with no closing marker")
    func noClosingMarker() {
        let content = ["<<<<<<< HEAD", "ours", "=======", "theirs without closing marker"].joined(separator: "\n")
        #expect(extractConflictHunks(content).isEmpty)
    }


    @Test("treats markers followed by Unicode whitespace as markers, and longer runs as content")
    func markerEdges() {
        let content = [
            "<<<<<<<\u{3000}HEAD", "<<<<<<<< not a marker", "=======", "theirs", ">>>>>>>", "after",
        ].joined(separator: "\n")
        let hunks = extractConflictHunks(content)
        #expect(hunks.count == 1)
        #expect(hunks[0].oursContent == "<<<<<<<< not a marker")
        #expect(hunks[0].contextAfter == "after")
    }
}

@Suite("copilot-conflict-context: formatConflictContextForPrompt")
struct FormatConflictContextTests {
    @Test("formats a single file with one conflict")
    func singleFile() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(
                context([
                    FileConflictContext(
                        path: "src/app.ts",
                        hunks: [hunk("const x = 1", "const x = 2", before: "import foo", after: "export default")]
                    ),
                ])
            )
        )

        #expect(result.contains(#""main" (ours)"#))
        #expect(result.contains(#""feature" (theirs)"#))
        #expect(result.contains("## File: src/app.ts"))
        #expect(result.contains("Conflict 1 of 1"))
        #expect(result.contains("const x = 1"))
        #expect(result.contains("const x = 2"))
        #expect(result.contains("import foo"))
        #expect(result.contains("export default"))
        // No base section for a two-way conflict.
        #expect(!result.contains("Base (common ancestor)"))
    }

    @Test("uses language from file extension in code fences")
    func languageFromExtension() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(context([FileConflictContext(path: "src/app.ts", hunks: [hunk("ours", "theirs")])]))
        )

        #expect(result.contains("```ts"))
        #expect(!result.contains("Language hint"))
    }

    @Test("formats multiple files with multiple conflicts")
    func multipleFiles() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(
                context([
                    FileConflictContext(path: "src/a.ts", hunks: [hunk("a-ours-1", "a-theirs-1"), hunk("a-ours-2", "a-theirs-2")]),
                    FileConflictContext(path: "src/b.tsx", hunks: [hunk("b-ours", "b-theirs")]),
                ])
            )
        )

        #expect(result.contains("## File: src/a.ts"))
        #expect(result.contains("## File: src/b.tsx"))
        #expect(result.contains("Conflict 1 of 2"))
        #expect(result.contains("Conflict 2 of 2"))
        #expect(result.contains("a-ours-1"))
        #expect(result.contains("a-ours-2"))
        #expect(result.contains("b-ours"))
    }

    @Test("includes base content for diff3 conflicts")
    func baseContent() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(context([FileConflictContext(path: "file.ts", hunks: [hunk("ours", "theirs", base: "original")])]))
        )

        #expect(result.contains("Base (common ancestor)"))
        #expect(result.contains("original"))
    }

    @Test("uses empty language for extensionless files")
    func extensionless() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(context([FileConflictContext(path: "Makefile", hunks: [hunk("ours", "theirs")])]))
        )

        #expect(result.contains("## File: Makefile"))
        // Code fences should just be ``` with no language.
        #expect(result.contains("```\n"))
    }

    @Test("omits context before/after blocks when empty")
    func omitsEmptyContext() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(context([FileConflictContext(path: "file.ts", hunks: [hunk("ours", "theirs")])]))
        )

        #expect(!result.contains("Context before"))
        #expect(!result.contains("Context after"))
    }

    @Test("renders skipped files with a reason instead of hunks")
    func skippedFiles() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(
                context([
                    FileConflictContext(path: "src/big-file.ts", hunks: [], skippedReason: "File exceeds 1MB size limit"),
                    FileConflictContext(path: "src/normal.ts", hunks: [hunk("ours", "theirs")]),
                ])
            )
        )

        // The skipped file shows its heading and reason.
        #expect(result.contains("## File: src/big-file.ts"))
        #expect(result.contains("Skipped: File exceeds 1MB size limit"))
        // The normal file still renders its hunks.
        #expect(result.contains("## File: src/normal.ts"))
        #expect(result.contains("ours"))
    }
}

@Suite("copilot-conflict-context: formatConflictContextForPrompt with enrichment")
struct FormatEnrichedContextTests {
    private let baseContext = context(
        [FileConflictContext(path: "src/user.ts", hunks: [hunk("id: number", "id: string")])],
        theirs: "feature/uuids"
    )

    @Test("includes commit context in output")
    func commitContext() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(
                baseContext,
                ourCommits: [makeContextCommit("abc1234", "Add numeric IDs"), makeContextCommit("def5678", "Update schema")],
                theirCommits: [makeContextCommit("111aaaa", "Add UUID support")]
            )
        )

        #expect(result.contains("## Recent Commits"))
        #expect(result.contains("### Ours (main) commits:"))
        #expect(result.contains("- abc1234: Add numeric IDs"))
        #expect(result.contains("- def5678: Update schema"))
        #expect(result.contains("### Theirs (feature/uuids) commits:"))
        #expect(result.contains("- 111aaaa: Add UUID support"))
        // File content is still present.
        #expect(result.contains("## File: src/user.ts"))
    }

    @Test("includes PR context in output with body fenced")
    func pullRequestContext() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(
                baseContext,
                pullRequests: [makeContextPr(99, "Migrate to UUIDs", "This migrates all user IDs from integers to UUIDs.")]
            )
        )

        #expect(result.contains("## Pull Request Context"))
        #expect(result.contains("PR #99: Migrate to UUIDs"))
        #expect(result.contains("Description:"))
        #expect(result.contains("This migrates all user IDs from integers to UUIDs."))
        // No commit section.
        #expect(!result.contains("## Recent Commits"))
        // File content is still present.
        #expect(result.contains("## File: src/user.ts"))

        // A PR body with backticks is wrapped in a longer fence.
        let result2 = formatConflictContextForPrompt(
            toResolutionContext(
                baseContext,
                pullRequests: [makeContextPr(42, "Docs update", "## Changes\n- Updated ```code``` examples")]
            )
        )
        #expect(result2.contains("Description:"))
        #expect(result2.contains("````"))
    }

    @Test("truncates an over-long PR body")
    func truncatesLongBody() {
        let longBody = String(repeating: "x", count: 5000)
        let result = formatConflictContextForPrompt(
            toResolutionContext(baseContext, pullRequests: [makeContextPr(7, "Big PR", longBody)])
        )

        #expect(result.contains("\u{2026}(truncated)"))
        #expect(!result.contains(longBody))
    }

    @Test("omits PR description section when body is empty")
    func omitsEmptyBody() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(baseContext, pullRequests: [makeContextPr(10, "Quick fix", "")])
        )

        #expect(result.contains("PR #10: Quick fix"))
        #expect(!result.contains("Description:"))
    }

    @Test("uses safe fences when content contains backticks")
    func safeFences() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(
                context([
                    FileConflictContext(
                        path: "README.md",
                        hunks: [
                            hunk("Use ```ts\nconst x = 1\n``` for examples", "Use ```js\nconst x = 2\n``` for examples"),
                        ]
                    ),
                ])
            )
        )

        // The fence is longer than the 3-backtick runs in the content.
        #expect(result.contains("````"))
    }

    @Test("sanitizes malicious file paths in markdown headings")
    func sanitizesPaths() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(
                context([FileConflictContext(path: "src/evil\npath`inject.ts", hunks: [hunk("ours", "theirs")])])
            )
        )

        // The newline and backtick are stripped from the heading.
        #expect(!result.contains("## File: src/evil\npath"))
        #expect(!result.contains("`inject"))
        #expect(result.contains("## File: src/evilpathinject.ts"))
    }

    @Test("falls back to empty language for non-alphanumeric extensions")
    func nonAlphanumericExtension() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(context([FileConflictContext(path: "src/module.c++", hunks: [hunk("ours", "theirs")])]))
        )

        // .c++ has a non-alphanumeric '+', so it isn't a language tag.
        #expect(!result.contains("```c++"))
        // A plain fence with no language.
        #expect(result.contains("```\nours"))
    }

    @Test("handles one-sided commit context")
    func oneSidedCommits() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(baseContext, ourCommits: [makeContextCommit("aaa1111", "Fix type error")], theirCommits: [])
        )

        #expect(result.contains("## Recent Commits"))
        #expect(result.contains("aaa1111"))
        #expect(result.contains("Fix type error"))
        // The theirs label still appears in the header.
        #expect(result.contains("(theirs)"))
    }

    @Test("does not include rawContent in prompt (used only for reassembly)")
    func excludesRawContent() {
        let rawFile = [
            #"import { foo } from "bar""#, "", "const a = 1", "<<<<<<< HEAD", "const b = 2", "=======", "const b = 3",
            ">>>>>>> feature", "", "export default a + b",
        ].joined(separator: "\n")

        let result = formatConflictContextForPrompt(
            toResolutionContext(
                context([
                    FileConflictContext(
                        path: "src/math.ts",
                        hunks: [hunk("const b = 2", "const b = 3", before: "const a = 1")],
                        rawContent: rawFile
                    ),
                ])
            )
        )

        // rawContent is not in the prompt; it's for reassembly only.
        #expect(!result.contains("Full file content"))
        #expect(!result.contains(#"import { foo } from "bar""#))
        #expect(!result.contains("export default a + b"))
        // The hunk breakdown is still included.
        #expect(result.contains("Conflict 1 of 1"))
        #expect(result.contains("const b = 2"))
    }
}

@Suite("copilot-conflict-context: formatConflictContextForPrompt with delete-vs-modify")
struct FormatDeleteConflictTests {
    @Test("renders delete-vs-modify conflict with scenario description")
    func theirsDeleted() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(context([FileConflictContext(path: "utils.ts", hunks: [], deletedSide: .theirs)]))
        )

        #expect(result.contains("File: utils.ts (delete-vs-modify conflict)"))
        #expect(result.contains(#"Deleted on "feature" (theirs), modified on "main" (ours)"#))
        #expect(result.contains(#""action": "keep""#))
        #expect(result.contains(#""action": "delete""#))
    }

    @Test("renders ours-deleted scenario correctly")
    func oursDeleted() {
        let result = formatConflictContextForPrompt(
            toResolutionContext(context([FileConflictContext(path: "old-file.ts", hunks: [], deletedSide: .ours)]))
        )

        #expect(result.contains(#"Deleted on "main" (ours), modified on "feature" (theirs)"#))
    }
}

@Suite("copilot-conflict-context: getHunkSkipReason")
struct HunkSkipReasonTests {
    @Test("returns null for a small, resolvable conflict")
    func resolvable() {
        #expect(getHunkSkipReason([hunk("our change\n", "their change\n")]) == nil)
    }

    @Test("returns null for no hunks")
    func noHunks() {
        #expect(getHunkSkipReason([]) == nil)
    }

    @Test("skips when a single line exceeds the max line length")
    func longLine() {
        let longLine = String(repeating: "a", count: 5001)
        #expect(
            getHunkSkipReason([hunk("\(longLine)\n", "their change\n")])
                == "Conflict contains lines too long to resolve automatically"
        )
    }

    @Test("does not skip a line exactly at the max line length")
    func lineAtLimit() {
        let atLimit = String(repeating: "a", count: 5000)
        #expect(getHunkSkipReason([hunk("\(atLimit)\n", "their change\n")]) == nil)
    }

    @Test("detects a long line in diff3 base content")
    func longBaseLine() {
        let longLine = String(repeating: "c", count: 6000)
        #expect(
            getHunkSkipReason([hunk("ours\n", "theirs\n", base: "\(longLine)\n")])
                == "Conflict contains lines too long to resolve automatically"
        )
    }

    @Test("skips when total conflict content exceeds the max content size")
    func tooMuchContent() {
        // Many short lines whose combined length exceeds 256KB, with no line
        // over the per-line limit.
        let line = String(repeating: "x", count: 100) + "\n"
        let bigSide = String(repeating: line, count: 3000)  // ~300KB
        #expect(
            getHunkSkipReason([hunk(bigSide, "their change\n")])
                == "Conflict region too large to resolve automatically"
        )
    }

    @Test("accumulates content across multiple hunks")
    func accumulates() {
        let line = String(repeating: "y", count: 100) + "\n"
        let chunk = String(repeating: line, count: 1000)  // ~100KB per side
        #expect(
            getHunkSkipReason([hunk(chunk, chunk), hunk(chunk, chunk)])
                == "Conflict region too large to resolve automatically"
        )
    }

    @Test("measures lengths in UTF-16 code units, as JavaScript does")
    func utf16Lengths() {
        // 2,501 emoji are 5,002 UTF-16 code units.
        let emojiLine = String(repeating: "\u{1F600}", count: 2501)
        #expect(
            getHunkSkipReason([hunk(emojiLine, "theirs")])
                == "Conflict contains lines too long to resolve automatically"
        )
    }
}

@Suite("buildConflictContext")
struct BuildConflictContextTests {
    private let conflicted = ["a", "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> feature", "b"].joined(separator: "\n")

    @Test("extracts hunks and keeps the raw content of resolvable files")
    func resolvableFile() {
        let built = buildConflictContext(
            ourLabel: "main",
            theirLabel: "feature",
            files: [ConflictedFile(path: "a.txt", contents: .text(conflicted))]
        )
        #expect(built.ourLabel == "main")
        #expect(built.theirLabel == "feature")
        #expect(
            built.files == [
                FileConflictContext(
                    path: "a.txt",
                    hunks: [hunk("ours", "theirs", before: "a", after: "b")],
                    rawContent: conflicted
                ),
            ]
        )
    }

    @Test("includes delete-vs-modify conflicts without contents")
    func deleteConflicts() {
        let built = buildConflictContext(
            ourLabel: "main",
            theirLabel: "feature",
            files: [ConflictedFile(path: "gone.txt", deletedSide: .ours)]
        )
        #expect(built.files == [FileConflictContext(path: "gone.txt", hunks: [], deletedSide: .ours)])
    }

    @Test("skips unreadable files, files without markers, and files with unresolvable hunks")
    func skipReasons() {
        let longLine = String(repeating: "z", count: 5001)
        let files: [(ConflictedFileContents, String)] = [
            (.unreadable, "File could not be read"),
            (.text("no markers"), "No conflict markers found"),
            (
                .text("<<<<<<< HEAD\n\(longLine)\n=======\nx\n>>>>>>> b"),
                "Conflict contains lines too long to resolve automatically"
            ),
        ]
        let built = buildConflictContext(
            ourLabel: "main",
            theirLabel: "feature",
            files: files.enumerated().map { ConflictedFile(path: "f\($0.offset)", contents: $0.element.0) }
        )
        #expect(built.files.map(\.skippedReason) == files.map(\.1))
        #expect(built.files.allSatisfy { $0.hunks.isEmpty && $0.rawContent == nil })
    }

    @Test("skips a file with conflict markers outside its blocks")
    func unmatchedMarkers() {
        let block = ["<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> feature"]
        let unmatched = [
            block + ["<<<<<<< leftover", "x"],
            [">>>>>>> leftover"] + block,
            block + ["=======", "x", ">>>>>>> leftover"],
            block + ["<<<<<<< HEAD", "a", "=======", "b"],
        ]
        let resolvable = [
            ["Title", "======="] + block,
            block + ["||||||| x"],
            block + ["<<<<<<<< eight", ">>>>>>>> eight"],
        ]
        let built = buildConflictContext(
            ourLabel: "main",
            theirLabel: "feature",
            files: (unmatched + resolvable).enumerated().map {
                ConflictedFile(path: "f\($0.offset)", contents: .text($0.element.joined(separator: "\n")))
            }
        )
        #expect(
            built.files.map(\.skippedReason)
                == Array(repeating: "Unmatched conflict markers found", count: unmatched.count) + Array(repeating: nil, count: resolvable.count)
        )
        #expect(built.files.prefix(unmatched.count).allSatisfy { $0.hunks.isEmpty && $0.rawContent == nil })
    }

    @Test("restricts a context to some files")
    func restricted() {
        let full = ConflictResolutionContext(
            ourLabel: "main",
            theirLabel: "feature",
            files: ["a", "b", "c"].map { FileConflictContext(path: $0, hunks: []) },
            pullRequests: [makeContextPr(1, "PR", "")],
            ourCommits: [makeContextCommit("abc1234", "One")]
        )
        let restricted = full.restricted(to: ["c", "a"])
        #expect(restricted.files.map(\.path) == ["a", "c"])
        #expect(restricted.pullRequests == full.pullRequests)
        #expect(restricted.ourCommits == full.ourCommits)

        // Paths are compared by code units: a decomposed é names another file.
        let accented = ConflictResolutionContext(
            ourLabel: "main",
            theirLabel: "feature",
            files: ["caf\u{E9}.txt", "cafe\u{301}.txt"].map { FileConflictContext(path: $0, hunks: []) }
        )
        let decomposed = accented.restricted(to: ["cafe\u{301}.txt"]).files.map { Array($0.path.unicodeScalars) }
        #expect(decomposed == [Array("cafe\u{301}.txt".unicodeScalars)])
    }
}
