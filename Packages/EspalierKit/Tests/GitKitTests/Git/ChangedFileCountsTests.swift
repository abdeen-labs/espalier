// `getCommitsWithChangedFileCounts`, for History's simple mode, which shows
// how many files each commit changed.

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("getCommitsWithChangedFileCounts")
struct ChangedFileCountsTests {
    /// Runs git in `repository` and requires success; returns the trimmed
    /// output.
    @discardableResult
    private func run(_ args: [String], _ repository: Repository) async throws -> String {
        let result = try await Dugite.exec(args, repository.path)
        try #require(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ path: String, _ contents: String, in repository: Repository) throws {
        let fullPath = POSIXPath.join(repository.path, path)
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(filePath: fullPath))
    }

    @discardableResult
    private func commitAll(_ message: String, in repository: Repository) async throws -> String {
        try await run(["add", "-A"], repository)
        try await run(["commit", "-q", "--allow-empty", "-m", message], repository)
        return try await run(["rev-parse", "HEAD"], repository)
    }

    @Test("counts the files each commit changed, a rename once, a root against the empty tree")
    func counts() async throws {
        let repository = try setupEmptyRepository("main")
        try write("a.txt", "a\n", in: repository)
        try write("dir/b.txt", "b\n", in: repository)
        try await commitAll("Root", in: repository)
        try write("a.txt", "a2\n", in: repository)
        try await commitAll("Modify", in: repository)
        try await commitAll("Empty", in: repository)
        try await run(["mv", "a.txt", "renamed.txt"], repository)
        try await commitAll("Rename", in: repository)
        try write(":colon.txt", "c\n", in: repository)
        try write("dir/b.txt", "b2\n", in: repository)
        try write("caf\u{E9}.txt", "e\n", in: repository)
        try await commitAll("Three files\n\nA body with\n:100644 a line like a raw entry\n", in: repository)
        try await run(["rm", "-q", "dir/b.txt"], repository)
        try await commitAll("Delete", in: repository)

        let result = try await getCommitsWithChangedFileCounts(repository, revisions: ["HEAD"])
        #expect(result.map(\.commit.summary) == ["Delete", "Three files", "Rename", "Empty", "Modify", "Root"])
        #expect(result.map(\.changedFileCount) == [1, 3, 1, 0, 1, 2])
        #expect(result[1].commit.body == "A body with\n:100644 a line like a raw entry\n")

        // The commits are the ones `getCommits` reads.
        let commits = try await getCommits(repository, revisions: ["HEAD"])
        #expect(result.map(\.commit) == commits)
    }

    @Test("counts a merge against its first parent, and follows first parents when asked")
    func merges() async throws {
        let repository = try setupEmptyRepository("main")
        try write("base.txt", "base\n", in: repository)
        let base = try await commitAll("Base", in: repository)
        try await run(["checkout", "-q", "-b", "side"], repository)
        try write("side1.txt", "1\n", in: repository)
        try await commitAll("Side 1", in: repository)
        try write("side2.txt", "2\n", in: repository)
        try write("base.txt", "base, from side\n", in: repository)
        try await commitAll("Side 2", in: repository)
        try await run(["checkout", "-q", "main"], repository)
        try write("main.txt", "main\n", in: repository)
        try await commitAll("Main", in: repository)
        try await run(["merge", "-q", "--no-ff", "-m", "Merge side", "side"], repository)
        let merge = try await run(["rev-parse", "HEAD"], repository)

        let firstParents = try await getCommitsWithChangedFileCounts(
            repository,
            revisions: [merge],
            additionalArgs: ["--first-parent"]
        )
        #expect(firstParents.map(\.commit.summary) == ["Merge side", "Main", "Base"])
        #expect(firstParents.map(\.changedFileCount) == [3, 1, 1])
        #expect(firstParents[0].commit.isMergeCommit)

        // The commits a merge brought in.
        let brought = try await getCommitsWithChangedFileCounts(
            repository,
            revisions: ["\(merge)^2", "^\(merge)^1"],
            additionalArgs: ["--topo-order"]
        )
        #expect(brought.map(\.commit.summary) == ["Side 2", "Side 1"])
        #expect(brought.map(\.changedFileCount) == [2, 1])

        let limited = try await getCommitsWithChangedFileCounts(
            repository,
            revisions: [merge, "^\(base)"],
            limit: 1,
            additionalArgs: ["--first-parent"]
        )
        #expect(limited.map(\.commit.summary) == ["Merge side"])
    }

    @Test("counts the same whatever the log and diff configuration says")
    func ignoresConfiguration() async throws {
        let repository = try setupEmptyRepository("main")
        try write("a.txt", "a\n", in: repository)
        try await commitAll("Root", in: repository)
        try await run(["mv", "a.txt", "b.txt"], repository)
        try await commitAll("Rename", in: repository)
        try await run(["checkout", "-q", "-b", "side", "HEAD~1"], repository)
        try write("side.txt", "s\n", in: repository)
        try await commitAll("Side", in: repository)
        try await run(["checkout", "-q", "main"], repository)
        try await run(["merge", "-q", "--no-ff", "-m", "Merge side", "side"], repository)
        for (key, value) in [
            ("log.showRoot", "false"),
            ("diff.renames", "false"),
            ("log.diffMerges", "separate"),
            ("log.showSignature", "true"),
        ] {
            try await run(["config", key, value], repository)
        }

        let result = try await getCommitsWithChangedFileCounts(repository, revisions: ["HEAD"], additionalArgs: ["--first-parent"])
        #expect(result.map(\.commit.summary) == ["Merge side", "Rename", "Root"])
        #expect(result.map(\.changedFileCount) == [1, 1, 1])
    }

    @Test("no revisions, no commits")
    func noRevisions() async throws {
        let repository = try setupEmptyRepository("main")
        try write("a.txt", "a\n", in: repository)
        try await commitAll("Root", in: repository)
        #expect(try await getCommitsWithChangedFileCounts(repository, revisions: []).isEmpty)
    }
}
