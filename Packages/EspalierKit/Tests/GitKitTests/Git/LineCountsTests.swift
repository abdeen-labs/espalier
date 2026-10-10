// `getWorkingDirectoryLineCounts`, for Changes, which shows each file's
// lines added and removed.

import Darwin
import EspalierSupport
import Foundation
@testable import GitKit
import Testing
import TestSupport

@Suite("getWorkingDirectoryLineCounts")
struct LineCountsTests {
    /// Runs git in `repository` and requires success.
    private func run(_ args: [String], _ repository: Repository) async throws {
        let result = try await Dugite.exec(args, repository.path)
        try #require(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
    }

    private func write(_ path: String, _ contents: String, in repository: Repository) throws {
        let fullPath = POSIXPath.join(repository.path, path)
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
        try writeFileExactly(path, contents, in: repository.path)
    }

    private func commitAll(_ message: String, in repository: Repository) async throws {
        try await run(["add", "-A"], repository)
        try await run(["commit", "-q", "-m", message], repository)
    }

    /// The counts for the repository's status, by path.
    private func counts(_ repository: Repository) async throws -> [String: FileLineCount] {
        let status = try await getStatusOrThrow(repository)
        let files = status.workingDirectory.files
        let counts = try await getWorkingDirectoryLineCounts(repository, files, against: status.currentTip)
        var byPath: [String: FileLineCount] = [:]
        for file in files {
            if let count = counts[ExactString(file.id)] {
                byPath[file.path] = count
            }
        }
        return byPath
    }

    private func count(_ added: Int, _ deleted: Int) -> FileLineCount {
        FileLineCount(added: added, deleted: deleted)
    }

    @Test("a file's staged and unstaged changes count together, against HEAD")
    func stagedAndUnstaged() async throws {
        let repository = try setupEmptyRepository()
        try write("a.txt", "one\ntwo\nthree\n", in: repository)
        try write("b.txt", "keep\n", in: repository)
        try write("gone.txt", "1\n2\n3\n4\n", in: repository)
        try await commitAll("Initial", in: repository)

        // Staged: two replaced by TWO. Unstaged: a line added.
        try write("a.txt", "one\nTWO\nthree\n", in: repository)
        try await run(["add", "a.txt"], repository)
        try write("a.txt", "one\nTWO\nthree\nfour\n", in: repository)
        // A line staged and then taken out again changes nothing in all:
        // git reports no change against HEAD, so it has no counts.
        try write("b.txt", "keep\nadded\n", in: repository)
        try await run(["add", "b.txt"], repository)
        try write("b.txt", "keep\n", in: repository)
        // Deleted, and new and staged.
        try FileManager.default.removeItem(atPath: POSIXPath.join(repository.path, "gone.txt"))
        try write("new.txt", "a\nb\n", in: repository)
        try await run(["add", "new.txt"], repository)

        let counts = try await counts(repository)
        #expect(counts["a.txt"] == count(2, 1))
        #expect(try await getStatusOrThrow(repository).workingDirectory.files.contains { $0.path == "b.txt" })
        #expect(counts["b.txt"] == nil)
        #expect(counts["gone.txt"] == count(0, 4))
        #expect(counts["new.txt"] == count(2, 0))
    }

    @Test("untracked files count their lines; a last line without a newline counts")
    func untracked() async throws {
        let repository = try setupEmptyRepository()
        try write("README.md", "hello\n", in: repository)
        try await commitAll("Initial", in: repository)

        try write("three.txt", "1\n2\n3\n", in: repository)
        try write("no-newline.txt", "1\n2", in: repository)
        try write("empty.txt", "", in: repository)
        try write("crlf.txt", "1\r\n2\r\n", in: repository)
        try write("nested/deep.txt", "x\n", in: repository)
        try Data([0x61, 0x00, 0x62, 0x0A]).write(to: URL(filePath: POSIXPath.join(repository.path, "binary.bin")))
        #expect(symlink("three.txt", POSIXPath.join(repository.path, "link")) == 0)

        let counts = try await counts(repository)
        #expect(counts["three.txt"] == count(3, 0))
        #expect(counts["no-newline.txt"] == count(2, 0))
        #expect(counts["empty.txt"] == count(0, 0))
        #expect(counts["crlf.txt"] == count(2, 0))
        #expect(counts["nested/deep.txt"] == count(1, 0))
        // A symbolic link is its target, one line, as git counts it.
        #expect(counts["link"] == count(1, 0))
        #expect(counts["binary.bin"] == nil)
    }

    @Test("an untracked file over the size limit, a binary one, and anything but a file or a link count nothing")
    func untrackedLimits() throws {
        let directory = try createTempDirectory()
        let path = POSIXPath.join(directory, "file.txt")
        try writeFileExactly("file.txt", "1\n2\n3\n", in: directory)
        #expect(countUntrackedLines(path, limit: 6) == FileLineCount(added: 3, deleted: 0))
        #expect(countUntrackedLines(path, limit: 5) == nil)

        // A NUL past the first 8,000 bytes is text, as git reads it.
        let late = String(repeating: "a", count: binaryDetectionLength) + "\0\n"
        try writeFileExactly("late.txt", late, in: directory)
        #expect(countUntrackedLines(POSIXPath.join(directory, "late.txt")) == FileLineCount(added: 1, deleted: 0))
        let early = String(repeating: "a", count: binaryDetectionLength - 1) + "\0\n"
        try writeFileExactly("early.txt", early, in: directory)
        #expect(countUntrackedLines(POSIXPath.join(directory, "early.txt")) == nil)

        // A FIFO is never opened (reading one would wait for a writer).
        let fifo = POSIXPath.join(directory, "fifo")
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(countUntrackedLines(fifo) == nil)
        #expect(countUntrackedLines(directory) == nil)
        #expect(countUntrackedLines(POSIXPath.join(directory, "missing")) == nil)
    }

    @Test("a rename counts its changes only; one git doesn't pair counts the new file added and the old removed")
    func renames() async throws {
        let repository = try setupEmptyRepository()
        // Different contents, so git pairs each rename with its own file.
        func lines(_ name: String) -> String {
            (1...20).map { "\(name) line \($0)" }.joined(separator: "\n") + "\n"
        }
        try write("moved.txt", lines("moved"), in: repository)
        try write("edited.txt", lines("edited"), in: repository)
        try write("rewritten.txt", "a\nb\nc\n", in: repository)
        try await commitAll("Initial", in: repository)

        try await run(["mv", "moved.txt", "moved-to.txt"], repository)
        try await run(["mv", "edited.txt", "edited-to.txt"], repository)
        try write("edited-to.txt", lines("edited") + "edited line 21\n", in: repository)
        try await run(["mv", "rewritten.txt", "rewritten-to.txt"], repository)
        try await run(["add", "-A"], repository)
        // Rewritten past git's similarity once it's in the working tree.
        try write("rewritten-to.txt", "a\nb\nc\nx\ny\nz\nw\n", in: repository)

        let status = try await getStatusOrThrow(repository)
        try #require(status.workingDirectory.files.filter { $0.status.kind == .renamed }.count == 3)
        let counts = try await counts(repository)
        #expect(counts["moved-to.txt"] == count(0, 0))
        #expect(counts["edited-to.txt"] == count(1, 0))
        #expect(counts["rewritten-to.txt"] == count(7, 3))
    }

    @Test("binary files, conflicted files, and submodules count nothing")
    func excluded() async throws {
        let repository = try setupEmptyRepository()
        try Data([0, 1, 2, 3]).write(to: URL(filePath: POSIXPath.join(repository.path, "image.png")))
        try write("text.txt", "a\n", in: repository)
        try await commitAll("Initial", in: repository)
        try Data([0, 1, 2, 3, 4]).write(to: URL(filePath: POSIXPath.join(repository.path, "image.png")))
        try write("text.txt", "b\n", in: repository)

        let counts = try await counts(repository)
        #expect(counts["image.png"] == nil)
        #expect(counts["text.txt"] == count(1, 1))

        // The same file, conflicted or a submodule, is left out.
        let conflicted = WorkingDirectoryFileChange(
            path: "text.txt",
            status: .conflicted(.conflictsWithMarkers(entry: UnmergedEntry(action: .bothModified), conflictMarkerCount: 1)),
            selection: DiffSelection.fromInitialSelection(.all)
        )
        let submodule = WorkingDirectoryFileChange(
            path: "text.txt",
            status: .modified(submoduleStatus: SubmoduleStatus(commitChanged: true, modifiedChanges: false, untrackedChanges: false)),
            selection: DiffSelection.fromInitialSelection(.all)
        )
        let tip = try await getStatusOrThrow(repository).currentTip
        #expect(try await getWorkingDirectoryLineCounts(repository, [conflicted, submodule], against: tip).isEmpty)
    }

    @Test("with HEAD unborn, files count against the empty tree")
    func unborn() async throws {
        let repository = try setupEmptyRepository()
        try write("staged.txt", "1\n2\n", in: repository)
        try await run(["add", "staged.txt"], repository)
        try write("staged.txt", "1\n2\n3\n", in: repository)
        try write("untracked.txt", "1\n", in: repository)

        let status = try await getStatusOrThrow(repository)
        #expect(status.currentTip == nil)
        let counts = try await counts(repository)
        #expect(counts["staged.txt"] == count(3, 0))
        #expect(counts["untracked.txt"] == count(1, 0))
    }

    @Test("names git would read as patterns count only their own file", arguments: PatternPath.representative)
    func patternNames(_ path: PatternPath) async throws {
        let repository = try setupEmptyRepository()
        try writeFileExactly(path.name, "a\n", in: repository.path)
        try writeFileExactly(path.decoy, "a\n", in: repository.path)
        try await commitAll("Initial", in: repository)
        try writeFileExactly(path.name, "a\nb\n", in: repository.path)

        let status = try await getStatusOrThrow(repository)
        let file = try #require(status.workingDirectory.files.first { $0.path == path.name })
        let counts = try await getWorkingDirectoryLineCounts(repository, [file], against: status.currentTip)
        #expect(counts == [ExactString(file.id): count(1, 0)])
    }

    @Test("counting never writes the index")
    func readOnly() async throws {
        let repository = try setupEmptyRepository()
        try write("a.txt", "a\n", in: repository)
        try write("b.txt", "b\n", in: repository)
        try await commitAll("Initial", in: repository)
        // b.txt's content is the same but its file is newer: git would
        // refresh the index's stat data if it were allowed to.
        try write("a.txt", "a\nchanged\n", in: repository)
        try write("b.txt", "b\n", in: repository)
        var times = [timespec(tv_sec: 1, tv_nsec: 0), timespec(tv_sec: 1, tv_nsec: 0)]
        #expect(utimensat(AT_FDCWD, POSIXPath.join(repository.path, "b.txt"), &times, 0) == 0)

        let index = POSIXPath.join(repository.path, ".git/index")
        let before = try Data(contentsOf: URL(filePath: index))
        let counts = try await counts(repository)
        #expect(counts["a.txt"] == count(1, 0))
        #expect(try Data(contentsOf: URL(filePath: index)) == before)
        #expect(!FileManager.default.fileExists(atPath: index + ".lock"))
    }

    @Test("numstat output parses exactly: renames, binary files, and tabs in names")
    func parsesNumstat() {
        let output = Data("3\t1\t\0old.txt\0new.txt\0-\t-\timage.png\012\t0\tname\twith tab\0".utf8)
        #expect(parseNumstatEntries(output) == [
            NumstatEntry(added: 3, deleted: 1, path: "new.txt", oldPath: "old.txt"),
            NumstatEntry(added: nil, deleted: nil, path: "image.png"),
            NumstatEntry(added: 12, deleted: 0, path: "name\twith tab"),
        ])
        #expect(parseNumstatEntries(Data()).isEmpty)
    }
}
