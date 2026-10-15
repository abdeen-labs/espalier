// The reference version of getFilesDiffText resets the repository's
// index, stages the selected files, diffs, and resets the index again.
// GitKit runs the same commands against a temporary copy of the index.
// These tests run both on the same repository state and require identical
// output, and require the real index to be byte for byte unchanged by
// GitKit's version.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// The reference getFilesDiffText, on the repository's real index.
private func getFilesDiffTextUsingRealIndex(
    _ repository: Repository,
    _ files: [WorkingDirectoryFileChange],
    _ commitish: String? = nil
) async throws -> String {
    try await unstageAll(repository)

    try await stageFiles(repository, files)

    var args = ["diff", "--no-ext-diff", "--patch-with-raw", "--no-color", "--staged"]
    if let commitish {
        args.append(commitish)
    }
    let result = try await git(args, repository.path, "getFilesDiffText")

    try await unstageAll(repository)

    if result.stdoutData.count > 10 * 1024 * 1024 {
        throw GitLibError("Diff is too large to render")
    }
    return String(decoding: result.stdoutData, as: UTF8.self)
}

private func writeFile(_ repository: Repository, _ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(repository.path, path)))
}

private func readIndex(_ repository: Repository) throws -> Data? {
    FileManager.default.contents(atPath: POSIXPath.join(repository.resolvedGitDir, "index"))
}

/// Runs GitKit's getFilesDiffText, checks that the index is unchanged, then
/// runs the reference version on the same state and checks the outputs
/// match. Returns the diff.
@discardableResult
private func expectSameDiffAsDesktop(
    _ repository: Repository,
    _ files: [WorkingDirectoryFileChange],
    _ commitish: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> String {
    let indexBefore = try readIndex(repository)

    let diff = try await getFilesDiffText(repository, files, commitish)

    #expect(try readIndex(repository) == indexBefore, "the index changed", sourceLocation: sourceLocation)
    #expect(
        !FileManager.default.fileExists(atPath: POSIXPath.join(repository.resolvedGitDir, "index.lock")),
        sourceLocation: sourceLocation
    )

    let desktopDiff = try await getFilesDiffTextUsingRealIndex(repository, files, commitish)
    #expect(diff == desktopDiff, sourceLocation: sourceLocation)
    return diff
}

/// Selects only the diff lines of `file` whose text is in `lines`.
private func selectingLines(
    _ repository: Repository,
    _ file: WorkingDirectoryFileChange,
    _ lines: Set<String>
) async throws -> WorkingDirectoryFileChange {
    let diff = try await getWorkingDirectoryDiff(repository, file)
    guard case .text(let textDiff) = diff else {
        throw TestSupportError("Expected a text diff for \(file.path), got \(diff.kind)")
    }
    var selection = DiffSelection.fromInitialSelection(.none)
    for hunk in textDiff.hunks {
        for (index, line) in hunk.lines.enumerated() where lines.contains(line.text) {
            selection = selection.withLineSelection(hunk.unifiedDiffStart + index, selected: true)
        }
    }
    return file.withSelection(selection)
}

private func statusFiles(_ repository: Repository) async throws -> [String: WorkingDirectoryFileChange] {
    let status = try await getStatusOrThrow(repository)
    return Dictionary(uniqueKeysWithValues: status.workingDirectory.files.map { ($0.path, $0) })
}

private let twentyLines = (1...20).map { "line \($0)\n" }.joined()

@Suite("git/diff getFilesDiffText")
struct FilesDiffTextTests {
    @Test("matches desktop for full and partial selections, without touching the index")
    func partialSelections() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(entries: [
            TreeEntry(path: "modified.txt", contents: twentyLines),
            TreeEntry(path: "excluded.txt", contents: "excluded\n"),
        ]))

        try writeFile(repo, "modified.txt", twentyLines
            .replacingOccurrences(of: "line 2\n", with: "line two\n")
            .replacingOccurrences(of: "line 18\n", with: "line eighteen\n"))
        try writeFile(repo, "excluded.txt", "changed but not selected\n")
        try writeFile(repo, "untracked.txt", "first\nsecond\nthird\n")

        let files = try await statusFiles(repo)
        let modified = try await selectingLines(repo, try #require(files["modified.txt"]), ["-line 2", "+line two"])
        let untracked = try await selectingLines(repo, try #require(files["untracked.txt"]), ["+second"])
        #expect(files["excluded.txt"] != nil)

        // As the changes list does, pass only the files with something
        // selected (excluded.txt isn't).
        let diff = try await expectSameDiffAsDesktop(repo, [modified, untracked])
        #expect(diff.contains("+line two"))
        #expect(!diff.contains("line eighteen"))
        #expect(diff.contains("+second"))
        #expect(!diff.contains("first"))
        #expect(!diff.contains("excluded"))
    }

    @Test("matches desktop for renames, deletions, and untracked files")
    func renamesDeletionsAndUntracked() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(entries: [
            TreeEntry(path: "rename-me.txt", contents: twentyLines),
            TreeEntry(path: "rename-partially.txt", contents: twentyLines + "partial\n"),
            TreeEntry(path: "delete-me.txt", contents: "delete me\n"),
        ]))

        _ = try await Dugite.exec(["mv", "rename-me.txt", "renamed.txt"], repo.path)
        _ = try await Dugite.exec(["mv", "rename-partially.txt", "renamed-partially.txt"], repo.path)
        try writeFile(repo, "renamed-partially.txt", (twentyLines + "partial\n")
            .replacingOccurrences(of: "line 3\n", with: "line three\n")
            .replacingOccurrences(of: "line 19\n", with: "line nineteen\n"))
        try FileManager.default.removeItem(atPath: POSIXPath.join(repo.path, "delete-me.txt"))
        try writeFile(repo, "new.txt", "new\n")
        // A new file where the renamed one used to be, which isn't selected.
        try writeFile(repo, "rename-me.txt", "not part of the rename\n")

        let files = try await statusFiles(repo)
        let renamed = try #require(files["renamed.txt"])
        #expect(renamed.status == .renamed(oldPath: "rename-me.txt", renameIncludesModifications: false))
        let partial = try await selectingLines(
            repo,
            try #require(files["renamed-partially.txt"]),
            ["-line 3", "+line three"]
        )
        let deleted = try #require(files["delete-me.txt"])
        let untracked = try #require(files["new.txt"])

        let diff = try await expectSameDiffAsDesktop(repo, [renamed, partial, deleted, untracked])
        #expect(diff.contains("rename from rename-me.txt"))
        #expect(diff.contains("+line three"))
        #expect(!diff.contains("line nineteen"))
        #expect(diff.contains("deleted file mode"))
        #expect(diff.contains("+new"))
        #expect(!diff.contains("not part of the rename"))
    }

    @Test("matches desktop for binary files, and fails as desktop does for a partial binary selection")
    func binaryFiles() async throws {
        let repo = try setupEmptyRepository()
        let binary = Data([0, 1, 2, 3, 0, 255])
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "image.png", contents: binary)]))
        try (binary + [9]).write(to: URL(filePath: POSIXPath.join(repo.path, "image.png")))
        try (binary + [7]).write(to: URL(filePath: POSIXPath.join(repo.path, "new.bin")))

        let files = try await statusFiles(repo)
        let image = try #require(files["image.png"])
        let newBinary = try #require(files["new.bin"])

        let diff = try await expectSameDiffAsDesktop(repo, [image, newBinary])
        #expect(diff.contains("Binary files a/image.png and b/image.png differ"))
        #expect(diff.contains("Binary files /dev/null and b/new.bin differ"))

        // A partial selection of a binary file can't be staged.
        let partialBinary = newBinary.withSelection(DiffSelection.fromInitialSelection(.none).withLineSelection(1, selected: true))
        let indexBefore = try readIndex(repo)
        let error = await #expect(throws: GitLibError.self) {
            try await getFilesDiffText(repo, [partialBinary])
        }
        #expect(try readIndex(repo) == indexBefore)
        let desktopError = await #expect(throws: GitLibError.self) {
            try await getFilesDiffTextUsingRealIndex(repo, [partialBinary])
        }
        #expect(desktopError?.message == error?.message)
    }

    @Test("matches desktop on an unborn branch")
    func unbornBranch() async throws {
        let repo = try setupEmptyRepository()
        try writeFile(repo, "a.txt", "a1\na2\na3\n")
        try writeFile(repo, "b.txt", "b\n")
        // Something already staged in the real index.
        _ = try await Dugite.exec(["add", "b.txt"], repo.path)

        let files = try await statusFiles(repo)
        let a = try await selectingLines(repo, try #require(files["a.txt"]), ["+a1", "+a3"])
        let b = try #require(files["b.txt"])

        let diff = try await expectSameDiffAsDesktop(repo, [a, b])
        #expect(diff.contains("+a1\n+a3\n"))
        #expect(diff.contains("+b"))
    }

    @Test("matches desktop when amending, diffing against the commit's parent")
    func amendCommitish() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: twentyLines)]))
        try await makeCommit(repo, Tree(entries: [
            TreeEntry(path: "file.txt", contents: twentyLines.replacingOccurrences(of: "line 1\n", with: "line one\n")),
            TreeEntry(path: "committed.txt", contents: "committed\n"),
        ]))
        let head = try await getTipOrError(repo)

        try writeFile(repo, "file.txt", twentyLines
            .replacingOccurrences(of: "line 1\n", with: "line one\n")
            .replacingOccurrences(of: "line 20\n", with: "line twenty\n"))
        // Staged changes in the real index survive GitKit's version.
        try writeFile(repo, "staged.txt", "staged\n")
        _ = try await Dugite.exec(["add", "staged.txt"], repo.path)

        let files = try await statusFiles(repo)
        let file = try #require(files["file.txt"])

        let diff = try await expectSameDiffAsDesktop(repo, [file], "\(head.sha)^")
        #expect(diff.contains("+line one"))
        #expect(diff.contains("+line twenty"))
        #expect(diff.contains("+committed"))
        #expect(!diff.contains("staged"))
    }

    @Test("leaves staged changes staged, and works while another process holds index.lock")
    func leavesIndexAlone() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "one\n")]))
        try writeFile(repo, "file.txt", "two\n")
        try writeFile(repo, "staged.txt", "staged\n")
        _ = try await Dugite.exec(["add", "staged.txt"], repo.path)

        let files = try await statusFiles(repo)
        let file = try #require(files["file.txt"])

        let lock = POSIXPath.join(repo.resolvedGitDir, "index.lock")
        try Data().write(to: URL(filePath: lock))
        let diff = try await getFilesDiffText(repo, [file])
        try FileManager.default.removeItem(atPath: lock)

        #expect(diff.contains("+two"))
        #expect(!diff.contains("staged"))
        #expect(try await git(["diff", "--cached", "--name-only"], repo.path, "test").stdout == "staged.txt\n")
    }

    @Test("uses a linked worktree's own index")
    func linkedWorktree() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "file.txt", contents: "one\n")]))
        let worktreePath = try createTempDirectory() + "/linked"
        _ = try await Dugite.exec(["worktree", "add", "-b", "linked", worktreePath], repo.path)
        let worktree = Repository(path: worktreePath)

        try Data("two\n".utf8).write(to: URL(filePath: POSIXPath.join(worktreePath, "file.txt")))
        try Data("staged\n".utf8).write(to: URL(filePath: POSIXPath.join(worktreePath, "staged.txt")))
        _ = try await Dugite.exec(["add", "staged.txt"], worktreePath)

        let indexPath = POSIXPath.join(repo.resolvedGitDir, "worktrees", "linked", "index")
        let indexBefore = FileManager.default.contents(atPath: indexPath)
        let mainIndexBefore = try readIndex(repo)

        let files = try await statusFiles(worktree)
        let diff = try await getFilesDiffText(worktree, [try #require(files["file.txt"])])

        #expect(diff.contains("+two"))
        #expect(!diff.contains("staged"))
        #expect(FileManager.default.contents(atPath: indexPath) == indexBefore)
        #expect(try readIndex(repo) == mainIndexBefore)
    }
}
