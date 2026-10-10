// Ported from desktop/app/test/unit/git/apply-test.ts

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private func getDiff(_ repository: Repository, _ filePath: String) async throws -> TextDiff {
    let file = WorkingDirectoryFileChange(path: filePath, status: .modified(), selection: .fromInitialSelection(.none))
    guard case .text(let diff) = try await getWorkingDirectoryDiff(repository, file) else {
        throw TestSupportError("Expected a text diff")
    }
    return diff
}

private func readFile(_ path: String) throws -> String {
    String(decoding: try Data(contentsOf: URL(filePath: path)), as: UTF8.self)
}

/// Returns a diff-style string with the line differences between two strings.
///
/// This gets the hunks from `git diff --no-index -U0` and writes their
/// headers the way the `diff` package's `structuredPatch` does: counts are
/// always written, and an empty range starts at the line after the change
/// rather than the line before it.
private func getDifference(_ before: String, _ after: String) async throws -> String {
    let directory = try createTempDirectory()
    let beforePath = POSIXPath.join(directory, "before")
    let afterPath = POSIXPath.join(directory, "after")
    try Data(before.replacingOccurrences(of: "\r\n", with: "\n").utf8).write(to: URL(filePath: beforePath))
    try Data(after.replacingOccurrences(of: "\r\n", with: "\n").utf8).write(to: URL(filePath: afterPath))

    let result = try await git(
        ["diff", "--no-index", "--no-color", "--no-ext-diff", "-U0", "--", beforePath, afterPath],
        directory,
        "getDifference",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )

    let header = JSCompat.regex(#"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@"#)
    var lines: [String] = []
    var inHunk = false
    for line in JSCompat.split(result.stdout, "\n") where !line.isEmpty {
        if let match = JSCompat.match(line, header) {
            let oldCount = match[2].flatMap { Int($0) } ?? 1
            let newCount = match[4].flatMap { Int($0) } ?? 1
            let oldStart = Int(match[1]!)! + (oldCount == 0 ? 1 : 0)
            let newStart = Int(match[3]!)! + (newCount == 0 ? 1 : 0)
            lines.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            inHunk = true
        } else if inHunk {
            lines.append(line)
        }
    }
    return lines.joined(separator: "\n")
}

@Suite("git/apply")
struct ApplyTests {
    @Suite("discardChangesFromSelection()")
    struct DiscardChangesFromSelection {
        @Test("does not change the file when an empty selection is passed")
        func emptySelection() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let filePath = "modified-file.md"
            let previousDiff = try await getDiff(repository, filePath)

            try await discardChangesFromSelection(
                repository,
                filePath,
                previousDiff,
                .fromInitialSelection(.none)
            )

            let diff = try await getDiff(repository, filePath)

            #expect(diff.text == previousDiff.text)
        }

        @Test("discards all file changes when a full selection is passed")
        func fullSelection() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let filePath = "modified-file.md"
            try await discardChangesFromSelection(
                repository,
                filePath,
                try await getDiff(repository, filePath),
                .fromInitialSelection(.all)
            )

            let diff = try await getDiff(repository, filePath)

            // Check that the file has no local changes.
            #expect(diff.text == "")
            #expect(diff.hunks.count == 0)
        }

        @Test("re-adds a single removed line")
        func readdsRemovedLine() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let filePath = "modified-file.md"
            let selection = DiffSelection.fromInitialSelection(.none).withLineSelection(4, selected: true)

            let previousContents = try readFile(POSIXPath.join(repository.path, filePath))

            try await discardChangesFromSelection(
                repository,
                filePath,
                try await getDiff(repository, filePath),
                selection
            )

            let fileContents = try readFile(POSIXPath.join(repository.path, filePath))

            #expect(try await getDifference(previousContents, fileContents) == """
                @@ -7,0 +7,1 @@
                +Aliquam leo ipsum, laoreet sed libero at, mollis pulvinar arcu. Nullam porttitor
                """)
        }

        @Test("re-adds a removed hunk")
        func readdsRemovedHunk() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let filePath = "modified-file.md"
            let diff = try await getDiff(repository, filePath)
            let hunkRange = try #require(findInteractiveDiffRange(diff.hunks, 4))

            let selection = DiffSelection.fromInitialSelection(.none).withRangeSelection(
                from: hunkRange.from,
                length: hunkRange.to - hunkRange.from + 1,
                selected: true
            )

            let previousContents = try readFile(POSIXPath.join(repository.path, filePath))

            try await discardChangesFromSelection(repository, filePath, diff, selection)

            let fileContents = try readFile(POSIXPath.join(repository.path, filePath))

            #expect(try await getDifference(previousContents, fileContents) == """
                @@ -7,0 +7,4 @@
                +Aliquam leo ipsum, laoreet sed libero at, mollis pulvinar arcu. Nullam porttitor
                +nisl eget hendrerit vestibulum. Curabitur ornare id neque ac tristique. Cras in
                +eleifend mi.
                +
                """)
        }

        @Test("removes an added line")
        func removesAddedLine() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let filePath = "modified-file.md"
            let selection = DiffSelection.fromInitialSelection(.none).withLineSelection(16, selected: true)

            let previousContents = try readFile(POSIXPath.join(repository.path, filePath))

            try await discardChangesFromSelection(
                repository,
                filePath,
                try await getDiff(repository, filePath),
                selection
            )

            let fileContents = try readFile(POSIXPath.join(repository.path, filePath))

            #expect(try await getDifference(previousContents, fileContents) == """
                @@ -21,1 +21,0 @@
                -nisl eget hendrerit vestibulum. Curabitur ornare id neque ac tristique. Cras in
                """)
        }

        @Test("removes an added hunk")
        func removesAddedHunk() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-changes")
            let repository = Repository(path: testRepoPath)

            let filePath = "modified-file.md"
            let diff = try await getDiff(repository, filePath)
            let hunkRange = try #require(findInteractiveDiffRange(diff.hunks, 16))
            let selection = DiffSelection.fromInitialSelection(.none).withRangeSelection(
                from: hunkRange.from,
                length: hunkRange.to - hunkRange.from + 1,
                selected: true
            )

            let previousContents = try readFile(POSIXPath.join(repository.path, filePath))

            try await discardChangesFromSelection(
                repository,
                filePath,
                try await getDiff(repository, filePath),
                selection
            )

            let fileContents = try readFile(POSIXPath.join(repository.path, filePath))

            #expect(try await getDifference(previousContents, fileContents) == """
                @@ -20,4 +20,0 @@
                -Aliquam leo ipsum, laoreet sed libero at, mollis pulvinar arcu. Nullam porttitor
                -nisl eget hendrerit vestibulum. Curabitur ornare id neque ac tristique. Cras in
                -eleifend mi.
                -
                """)
        }
    }

    // `findInteractiveDiffRange`, which only these tests use.
    @Test("finds the interactive range around a line")
    func interactiveRange() async throws {
        let testRepoPath = try setupFixtureRepository("repo-with-changes")
        let repository = Repository(path: testRepoPath)
        let diff = try await getDiff(repository, "modified-file.md")

        #expect(findInteractiveDiffRange(diff.hunks, 4) == DiffRange(from: 4, to: 7, type: .deletions))
        #expect(findInteractiveDiffRange(diff.hunks, 16) == DiffRange(from: 15, to: 18, type: .additions))
        #expect(findInteractiveDiffRange(diff.hunks, 1000) == nil)
    }

    // applyPatchToIndex stages part of a renamed file the way the commit flow
    // does: after resetting the index, it recreates the rename and applies the
    // selected lines on top.
    @Test("applies a partial selection to the index, recreating a rename")
    func applyPatchToIndexRecreatesRename() async throws {
        let repo = try setupEmptyRepository()
        let contents = (1...10).map { "line \($0)\n" }.joined()
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "old.txt", contents: contents)]))
        _ = try await Dugite.exec(["mv", "old.txt", "new.txt"], repo.path)
        let changed = contents
            .replacingOccurrences(of: "line 2\n", with: "line two\n")
            .replacingOccurrences(of: "line 9\n", with: "line nine\n")
        try Data(changed.utf8).write(to: URL(filePath: POSIXPath.join(repo.path, "new.txt")))

        let status = try await getStatusOrThrow(repo)
        let file = try #require(status.workingDirectory.files.first)
        #expect(status.workingDirectory.files.count == 1)
        #expect(file.status == .renamed(oldPath: "old.txt", renameIncludesModifications: true))

        guard case .text(let textDiff) = try await getWorkingDirectoryDiff(repo, file) else {
            Issue.record("Expected a text diff")
            return
        }
        var selection = DiffSelection.fromInitialSelection(.none)
        for hunk in textDiff.hunks {
            for (index, line) in hunk.lines.enumerated() where line.text == "-line 2" || line.text == "+line two" {
                selection = selection.withLineSelection(hunk.unifiedDiffStart + index, selected: true)
            }
        }

        try await unstageAll(repo)
        try await applyPatchToIndex(repo, file.withSelection(selection))

        let staged = try await git(["diff", "--cached", "-M", "--name-status"], repo.path, "test").stdout
        #expect(staged.hasPrefix("R"))
        #expect(staged.hasSuffix("\told.txt\tnew.txt\n"))
        let index = try await git(["show", ":new.txt"], repo.path, "test").stdout
        #expect(index == contents.replacingOccurrences(of: "line 2\n", with: "line two\n"))
    }
}
