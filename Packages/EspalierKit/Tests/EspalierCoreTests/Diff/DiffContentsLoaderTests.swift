// These load a changed file's old and new contents for diff expansion and
// syntax highlighting: in a commit and in the working directory; added,
// deleted, renamed, binary, and too-large files; and loads that replace
// each other.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Diff contents loader", .offline) @MainActor
struct DiffContentsLoaderTests {
    /// A commit that modifies, adds, deletes, and renames files.
    private func makeRepository() async throws -> (HistoryFixture, String) {
        var commit = ""
        let fixture = try await makeHistoryFixture { repository in
            try await commitWithGit(repository, "modified.txt", "one\ntwo\nthree\n", message: "Base")
            try await commitWithGit(repository, "deleted.txt", "gone\n", message: "Deleted file")
            try await commitWithGit(repository, "old-name.txt", "renamed\ncontents\n", message: "To rename")
            try Data("one\r\nTWO\r\nthree\r\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "modified.txt")))
            try Data("new\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "added.txt")))
            try await runGit(["add", "modified.txt", "added.txt"], repository)
            try await runGit(["rm", "-q", "deleted.txt"], repository)
            try await runGit(["mv", "old-name.txt", "new-name.txt"], repository)
            try await runGit(["commit", "-q", "-m", "Change everything"], repository)
            commit = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
        }
        return (fixture, commit)
    }

    private func changedFiles(_ fixture: HistoryFixture, _ commit: String) async throws -> [String: CommittedFileChange] {
        let changeset = try await getChangedFiles(fixture.local, commit)
        return Dictionary(uniqueKeysWithValues: changeset.files.map { ($0.path, $0) })
    }

    private func load(_ file: CommittedFileChange, in fixture: HistoryFixture) async throws -> DiffFileContents {
        let loader = DiffContentsLoader(repository: fixture.model)
        loader.load(file)
        #expect(loader.contents.isLoading)
        await loader.idle()
        return try #require(loader.contents.value)
    }

    @Test("a modified file in a commit: the parent's lines and the commit's")
    func modifiedInCommit() async throws {
        let (fixture, commit) = try await makeRepository()
        let file = try #require(try await changedFiles(fixture, commit)["modified.txt"])
        let contents = try await load(file, in: fixture)

        #expect(contents.fileID == file.id)
        #expect(contents.oldLines == ["one", "two", "three", ""])
        // `\r\n` endings are split like `\n`.
        #expect(contents.newLines == ["one", "TWO", "three", ""])
        #expect(contents.canBeExpanded)
        #expect(contents.isBinary == false)
    }

    @Test("an added file has no old lines; a deleted one no new lines and no expansion")
    func addedAndDeleted() async throws {
        let (fixture, commit) = try await makeRepository()
        let files = try await changedFiles(fixture, commit)

        let added = try await load(try #require(files["added.txt"]), in: fixture)
        #expect(added.oldLines.isEmpty)
        #expect(added.newLines == ["new", ""])
        #expect(added.canBeExpanded)

        let deleted = try await load(try #require(files["deleted.txt"]), in: fixture)
        #expect(deleted.oldLines == ["gone", ""])
        #expect(deleted.newLines.isEmpty)
        #expect(deleted.canBeExpanded == false)
    }

    @Test("a renamed file's old lines come from its old path")
    func renamed() async throws {
        let (fixture, commit) = try await makeRepository()
        let file = try #require(try await changedFiles(fixture, commit)["new-name.txt"])
        #expect(file.status.kind == .renamed)
        let contents = try await load(file, in: fixture)
        #expect(contents.oldLines == ["renamed", "contents", ""])
        #expect(contents.newLines == ["renamed", "contents", ""])
    }

    @Test("a working directory file: HEAD's lines and the file on disk")
    func workingDirectory() async throws {
        let (fixture, _) = try await makeRepository()
        try fixture.write("modified.txt", "one\nchanged\n")
        try fixture.write("untracked.txt", "fresh\n")
        try FileManager.default.removeItem(atPath: POSIXPath.join(fixture.local.path, "added.txt"))
        await fixture.model.refresh(.status, reason: .user)
        await fixture.settle()
        let files = Dictionary(uniqueKeysWithValues: fixture.model.changes.workingDirectory.files.map { ($0.path, $0) })
        let loader = DiffContentsLoader(repository: fixture.model)

        loader.load(try #require(files["modified.txt"]))
        await loader.idle()
        #expect(loader.contents.value?.oldLines == ["one", "TWO", "three", ""])
        #expect(loader.contents.value?.newLines == ["one", "changed", ""])
        #expect(loader.contents.value?.canBeExpanded == true)

        loader.load(try #require(files["untracked.txt"]))
        await loader.idle()
        #expect(loader.contents.value?.oldLines == [])
        #expect(loader.contents.value?.newLines == ["fresh", ""])

        loader.load(try #require(files["added.txt"]))
        await loader.idle()
        #expect(loader.contents.value?.oldLines == ["new", ""])
        #expect(loader.contents.value?.newLines == [])
        #expect(loader.contents.value?.canBeExpanded == false)

        loader.clear()
        #expect(loader.contents == .idle)
    }

    @Test("a binary file gives no lines and doesn't expand")
    func binary() async throws {
        var commit = ""
        let fixture = try await makeHistoryFixture { repository in
            try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]).write(to: URL(filePath: POSIXPath.join(repository.path, "image.png")))
            try await runGit(["add", "image.png"], repository)
            try await runGit(["commit", "-q", "-m", "Image"], repository)
            try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x03]).write(to: URL(filePath: POSIXPath.join(repository.path, "image.png")))
            try await runGit(["commit", "-q", "-am", "Image again"], repository)
            commit = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
        }
        let file = try #require(try await changedFiles(fixture, commit)["image.png"])
        let contents = try await load(file, in: fixture)

        #expect(contents.isBinary)
        #expect(contents.oldLines.isEmpty)
        #expect(contents.newLines.isEmpty)
        #expect(contents.canBeExpanded == false)
    }

    @Test("a file over 1 MiB is cut there and doesn't expand")
    func tooLarge() async throws {
        let line = String(repeating: "x", count: 1023) + "\n"
        let large = String(repeating: line, count: 1_100)
        var commit = ""
        let fixture = try await makeHistoryFixture { repository in
            try await commitWithGit(repository, "large.txt", "small\n", message: "Small")
            commit = try await commitWithGit(repository, "large.txt", large, message: "Large")
        }
        let file = try #require(try await changedFiles(fixture, commit)["large.txt"])
        let contents = try await load(file, in: fixture)

        #expect(contents.canBeExpanded == false)
        #expect(contents.oldLines == ["small", ""])
        // 1,024 lines of 1,024 bytes fill the 1 MiB read exactly.
        #expect(contents.newLines.count == 1_025)
        #expect(contents.newLines.first == String(repeating: "x", count: 1023))
        #expect(contents.newLines.last == "")

        // Exactly one byte under the limit still expands; at the limit, it
        // doesn't (a cut file can't be told from one that size).
        let underLimit = String(repeating: "y", count: maxDiffExpansionNewContentLength)
        try fixture.write("large.txt", underLimit)
        try fixture.write("limit.txt", underLimit + "y")
        try await fixture.git(["add", "limit.txt"])
        await fixture.model.refresh(.status, reason: .user)
        await fixture.settle()
        let files = Dictionary(uniqueKeysWithValues: fixture.model.changes.workingDirectory.files.map { ($0.path, $0) })
        let loader = DiffContentsLoader(repository: fixture.model)
        loader.load(try #require(files["large.txt"]))
        await loader.idle()
        #expect(loader.contents.value?.canBeExpanded == true)
        loader.load(try #require(files["limit.txt"]))
        await loader.idle()
        #expect(loader.contents.value?.canBeExpanded == false)
    }

    @Test("a newer load replaces the one in flight")
    func latestLoadWins() async throws {
        let (fixture, commit) = try await makeRepository()
        let files = try await changedFiles(fixture, commit)
        let loader = DiffContentsLoader(repository: fixture.model)
        let modified = try #require(files["modified.txt"])
        let added = try #require(files["added.txt"])

        for _ in 0..<5 {
            loader.load(modified)
            loader.load(added)
        }
        await loader.idle()
        #expect(loader.contents.value?.fileID == added.id)
        #expect(loader.contents.value?.newLines == ["new", ""])
    }

    @Test("lines split like desktop's /\\r?\\n/")
    func splitting() {
        #expect(splitLines(Data()) == [""])
        #expect(splitLines(Data("a".utf8)) == ["a"])
        #expect(splitLines(Data("a\n".utf8)) == ["a", ""])
        #expect(splitLines(Data("a\r\nb\rc\n\r\n".utf8)) == ["a", "b\rc", "", ""])
        #expect(splitLines(Data([0x61, 0xE2, 0x0A, 0x62])) == ["a\u{FFFD}", "b"])
    }
}
