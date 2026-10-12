// Odd paths and non-UTF-8 text end to end through the models: NFC and NFD
// names (macOS), names with newlines, tabs, quotes, backslashes, and
// leading dashes, with `core.quotePath` on and off; staging (whole files
// and lines), discarding, committing, and the Changes and History diffs of
// each; and Latin-1 text and paths.

@testable import EspalierCore
import Darwin
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Edge states: odd paths and non-UTF-8 text", .offline) @MainActor
struct OddPathsTests {
    /// The names, as git reports them (NFC; macOS's git precomposes).
    nonisolated static let names = [
        "caf\u{E9}.txt",
        "new\nline.txt",
        "tab\tname.txt",
        "a \"quoted\" name.txt",
        "back\\slash.txt",
        "--option-like.txt",
        "trailing space .txt",
        "emoji \u{1F600}.txt",
        "dir with space/inner \u{E9}.txt",
    ]

    /// Writes `bytes` to `name` in the repository with `open(2)`, exactly as
    /// given (Foundation's file system representation decomposes names).
    private func writeExactly(_ name: [UInt8], _ contents: [UInt8], in repository: Repository) throws {
        let path = Array(repository.path.utf8) + [UInt8(ascii: "/")] + name
        let directory = path[..<(path.lastIndex(of: UInt8(ascii: "/")) ?? path.endIndex)]
        _ = (Array(directory) + [0]).withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { mkdir($0, 0o755) }
        }
        let fd = (path + [0]).withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        }
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        let written = contents.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        #expect(written == contents.count)
    }

    private func numbered(_ count: Int, replacing: [Int: String] = [:]) -> String {
        (1...count).map { replacing[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    @Test("a file with an odd name is added, partly committed, discarded, and shown in History", arguments: names, [true, false])
    func oddName(_ name: String, quotePath: Bool) async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        if !quotePath {
            try await fixture.git(["config", "core.quotePath", "false"])
        }
        try writeExactly(Array(name.utf8), Array(numbered(20).utf8), in: fixture.local)
        await fixture.refresh()
        #expect(fixture.paths == [name])
        try await fixture.select(name)
        #expect(addedLines(try fixture.shownText()).count == 20)

        // Committed whole.
        try fixture.include([name])
        _ = try await fixture.commitIncluded("Add \(name)")
        #expect(fixture.paths.isEmpty)
        #expect(try await fixture.git(["ls-files", "-z"]).split(separator: "\0").map(String.init).contains(name))

        // Two hunks, the first committed alone.
        try writeExactly(Array(name.utf8), Array(numbered(20, replacing: [2: "line two", 15: "line fifteen"]).utf8), in: fixture.local)
        await fixture.refresh()
        try await fixture.select(name)
        #expect(fixture.changes.canSelectLines)
        let fifteen = try fixture.lineIndex(.add, "line fifteen")
        #expect(fixture.changes.setLines(.hunk(containing: fifteen), included: false))
        let partial = try await fixture.commitIncluded("Change line two of \(name)")
        let committed = try await fixture.git(["show", "HEAD:./\(name)"])
        #expect(committed == numbered(20, replacing: [2: "line two"]))
        #expect(fixture.paths == [name])

        // The rest discarded: the file is back to the commit.
        try await fixture.changes.discard([try fixture.file(name)], confirmed: [.discardChanges])
        await fixture.settle()
        #expect(fixture.paths.isEmpty)
        let path = POSIXPath.join(fixture.local.path, name)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == numbered(20, replacing: [2: "line two"]))

        // History lists the file and diffs it.
        await fixture.activateHistory()
        fixture.history.select(shas: [partial.sha], contiguous: true)
        await fixture.settleHistory()
        let file = try #require(fixture.history.selection.changeset.value?.files.first)
        #expect(file.path == name)
        fixture.history.selectFile(file)
        await fixture.settleHistory()
        let diff = try #require(textDiffData(fixture.history.selection.diff.value), "\(fixture.history.selection.diff)")
        #expect(addedLines(diff) == ["line two"])
    }

    @Test("a name created decomposed (NFD) is the precomposed name to git, and stages, commits, and discards")
    func decomposedName() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        let decomposed = "cafe\u{301}-nfd.txt"
        let precomposed = "caf\u{E9}-nfd.txt"
        try writeExactly(Array(decomposed.utf8), Array("one\n".utf8), in: fixture.local)
        await fixture.refresh()
        #expect(fixture.paths.map { Array($0.utf8) } == [Array(precomposed.utf8)])

        try fixture.include([precomposed])
        _ = try await fixture.commitIncluded("Add a decomposed name")
        #expect(fixture.paths.isEmpty)
        #expect(try await fixture.git(["ls-files", "-z"]).utf8.split(separator: 0).contains { Array($0) == Array(precomposed.utf8) })

        try writeExactly(Array(decomposed.utf8), Array("two\n".utf8), in: fixture.local)
        await fixture.refresh()
        try await fixture.select(precomposed)
        #expect(addedLines(try fixture.shownText()) == ["two"])
        try await fixture.changes.discard([try fixture.file(precomposed)], confirmed: [.discardChanges])
        await fixture.settle()
        #expect(fixture.paths.isEmpty)
    }

    @Test("Latin-1 text diffs, but its lines can't be committed or discarded alone; the whole file keeps its bytes")
    func latin1Text() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        func contents(_ replacing: [Int: [UInt8]] = [:]) -> [UInt8] {
            (1...20).flatMap { index -> [UInt8] in
                (replacing[index] ?? Array("line \(index)".utf8)) + [0x0A]
            }
        }
        try writeExactly(Array("latin1.txt".utf8), contents(), in: fixture.local)
        try await fixture.git(["add", "latin1.txt"])
        try await fixture.git(["commit", "-q", "-m", "Latin-1"])

        // Line 2 gains "caf\u{E9}" in ISO-8859-1, which reads as U+FFFD;
        // line 15 changes too.
        let latin1: [UInt8] = Array("caf".utf8) + [0xE9]
        let changed = contents([2: latin1, 15: Array("line fifteen".utf8)])
        try writeExactly(Array("latin1.txt".utf8), changed, in: fixture.local)
        await fixture.refresh()
        try await fixture.select("latin1.txt")
        let shown = try fixture.shownText()
        #expect(shown.hunks.count == 2)
        #expect(addedLines(shown).contains("caf\u{FFFD}"))
        #expect(!fixture.changes.canSelectLines)

        // A partial selection made anyway isn't committed: committing only
        // the first hunk would have written U+FFFD's bytes for 0xE9.
        let fifteen = try fixture.lineIndex(.add, "line fifteen")
        let file = try fixture.file("latin1.txt")
        let selectable = file.selection.withSelectableLines(Set(shown.hunks.flatMap { hunk in
            hunk.lines.indices.filter { hunk.lines[$0].type == .add || hunk.lines[$0].type == .delete }.map { hunk.unifiedDiffStart + $0 }
        }))
        fixture.changes.setLineSelection(selectable.withLineSelection(fifteen, selected: false), forFile: file.id)
        fixture.commit.draft.summary = "Line two"
        let error = await #expect(throws: OperationError.self) {
            try await fixture.commit.commit()
        }
        #expect(error?.message == notByteExactMessage("latin1.txt", "committed"))
        #expect(try await fixture.commitCount() == 2)
        #expect(Array(try await Dugite.exec(["diff", "--cached", "--name-only"], fixture.local.path).stdout).isEmpty)

        // Discarding a line is refused the same way.
        let discardError = await #expect(throws: OperationError.self) {
            try await fixture.changes.discardLines(.line(fifteen), confirmed: [.discardLines])
        }
        #expect(discardError?.reason == .precondition(notByteExactMessage("latin1.txt", "discarded")))

        // The whole file commits with its bytes.
        fixture.changes.setIncluded([file.id], true)
        _ = try await fixture.commitIncluded("Latin-1 line")
        #expect(Array(try await Dugite.exec(["show", "HEAD:latin1.txt"], fixture.local.path).stdout) == changed)
        let working = try Data(contentsOf: URL(filePath: POSIXPath.join(fixture.local.path, "latin1.txt")))
        #expect(Array(working) == changed)

        // History shows it, with the same U+FFFD.
        await fixture.activateHistory()
        let head = try await fixture.head()
        fixture.history.select(shas: [head], contiguous: true)
        await fixture.settleHistory()
        let committed = try #require(fixture.history.selection.changeset.value?.files.first)
        fixture.history.selectFile(committed)
        await fixture.settleHistory()
        #expect(addedLines(textDiffData(fixture.history.selection.diff.value)).contains("caf\u{FFFD}"))
    }

    @Test("a commit message in Latin-1 reads as UTF-8 in History, whatever the log encoding (desktop showed U+FFFD)")
    func latin1CommitMessage() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        try await fixture.git(["config", "i18n.commitEncoding", "ISO-8859-1"])
        try fixture.write("a.txt", "a\n")
        try await fixture.git(["add", "a.txt"])
        let message = Data(Array("Caf".utf8) + [0xE9, 0x0A])
        let result = try await Dugite.exec(
            ["commit", "-q", "-F", "-"],
            fixture.local.path,
            options: Dugite.ExecutionOptions(stdin: message)
        )
        #expect(result.exitCode == 0)
        await fixture.refresh(.full)
        await fixture.activateHistory()
        #expect(fixture.historySummaries.first == "Caf\u{E9}")
    }

    @Test("a Latin-1 path, which APFS can't hold, lists in History from a commit made elsewhere")
    func latin1Path() async throws {
        let (fixture, _) = try await ChangesFixture.withRemote()
        let latin1Name: [UInt8] = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)
        #expect(throws: POSIXError.self) {
            try writeExactly(latin1Name, Array("one\n".utf8), in: fixture.local)
        }

        // A commit on another branch, as from Linux.
        let blob = try await Dugite.exec(["hash-object", "-w", "--stdin"], fixture.local.path, options: Dugite.ExecutionOptions(stdin: Data("one\n".utf8)))
        let blobSHA = JSCompat.trim(String(decoding: blob.stdout, as: UTF8.self))
        let entry = Data(Array("100644 blob \(blobSHA)\t".utf8) + latin1Name + [0x0A])
        let tree = try await Dugite.exec(["mktree"], fixture.local.path, options: Dugite.ExecutionOptions(stdin: entry))
        let treeSHA = JSCompat.trim(String(decoding: tree.stdout, as: UTF8.self))
        let commitSHA = JSCompat.trim(try await fixture.git(["commit-tree", treeSHA, "-p", "HEAD", "-m", "From Linux"]))
        try await fixture.git(["update-ref", "refs/heads/linux", commitSHA])
        await fixture.refresh(.full)

        await fixture.activateHistory()
        #expect(fixture.history.commitSHAs.contains(commitSHA))
        fixture.history.select(shas: [commitSHA], contiguous: true)
        await fixture.settleHistory()
        let files = try #require(fixture.history.selection.changeset.value?.files)
        #expect(files.contains { $0.path == "caf\u{FFFD}.txt" })
        #expect(fixture.history.selection.changeset.failure == nil)
    }
}
