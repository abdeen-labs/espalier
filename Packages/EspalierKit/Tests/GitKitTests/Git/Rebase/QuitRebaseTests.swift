// quitRebase (GitRebase.swift) on rebase state left behind with files
// missing: git 2.53's `git rebase --quit` removes it, leaves HEAD, the
// index, and the working tree as they are, and saves an autostash to the
// stash list; `REBASE_HEAD` goes too. `git am`'s directory stays.

import EspalierSupport
import Foundation
@testable import GitKit
import Testing
import TestSupport

@Suite("git/rebase quitRebase")
struct QuitRebaseTests {
    /// HEAD, the index, the working tree, and the stash list, as git
    /// reports them.
    struct Snapshot: Equatable {
        let head: String
        let branch: String
        let status: String
        let stashes: String
    }

    static func snapshot(_ repository: Repository) async throws -> Snapshot {
        Snapshot(
            head: try await RebaseTesting.revParse(repository, "HEAD"),
            branch: try await RebaseTesting.git(repository, ["symbolic-ref", "-q", "HEAD"]),
            status: try await RebaseTesting.git(repository, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]),
            stashes: try await RebaseTesting.git(repository, ["stash", "list", "--format=%H %gs"])
        )
    }

    /// `feature` checked out, with a staged file, an unstaged change, and an
    /// untracked file.
    static func makeRepository() async throws -> Repository {
        let repository = try await RebaseTesting.makeRepository(
            base: [TreeEntry(path: "base.txt", contents: "base\n")],
            feature: [("feature", [TreeEntry(path: "feature.txt", contents: "feature\n")])]
        )
        try write(repository, "staged.txt", "staged\n")
        try await RebaseTesting.git(repository, ["add", "staged.txt"])
        try write(repository, "feature.txt", "unstaged\n")
        try write(repository, "untracked.txt", "untracked\n")
        return repository
    }

    static func write(_ repository: Repository, _ path: String, _ contents: String) throws {
        let full = POSIXPath.join(repository.path, path)
        try FileManager.default.createDirectory(atPath: POSIXPath.dirname(full), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(filePath: full))
    }

    static func exists(_ repository: Repository, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: POSIXPath.join(repository.resolvedGitDir, name))
    }

    /// The files of each state directory left behind, relative to the git
    /// directory, with their contents; `REBASE_HEAD` at HEAD's commit when
    /// the name says so.
    static let leftovers: [NamedCase<[String: String]>] = [
        NamedCase("an empty rebase-merge", ["rebase-merge/": ""]),
        NamedCase("rebase-merge missing some files, with REBASE_HEAD", [
            "rebase-merge/head-name": "refs/heads/feature\n",
            "rebase-merge/interactive": "",
            "REBASE_HEAD": "HEAD",
        ]),
        NamedCase("an empty rebase-apply", ["rebase-apply/": ""]),
        NamedCase("rebase-apply missing some files, marked as a rebase's", [
            "rebase-apply/rebasing": "",
            "rebase-apply/head-name": "refs/heads/feature\n",
        ]),
        NamedCase("both directories", ["rebase-merge/": "", "rebase-apply/": ""]),
    ]

    static func leave(_ files: [String: String], in repository: Repository) async throws {
        for (name, contents) in files {
            let path = POSIXPath.join(repository.resolvedGitDir, name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(atPath: POSIXPath.dirname(path), withIntermediateDirectories: true)
            let value = contents == "HEAD" ? try await RebaseTesting.revParse(repository, "HEAD") + "\n" : contents
            try Data(value.utf8).write(to: URL(filePath: path))
        }
    }

    @Test("clears what's left, leaving HEAD, the index, and the working tree as they are", arguments: leftovers)
    func clears(_ leftover: NamedCase<[String: String]>) async throws {
        let repository = try await Self.makeRepository()
        let before = try await Self.snapshot(repository)
        try await Self.leave(leftover.value, in: repository)
        try #require(isRebaseStateDirectoryPresent(repository))
        let feature = try await getBranchOrError(repository, "feature")
        let base = try await getBranchOrError(repository, "base")
        let refused = await #expect(throws: GitError.self) {
            try await rebase(repository, base, feature)
        }
        try #require(refused?.result.gitError == .rebaseAlreadyInProgress)

        try await quitRebase(repository)

        #expect(!isRebaseStateDirectoryPresent(repository))
        #expect(!Self.exists(repository, "REBASE_HEAD"))
        #expect(try await Self.snapshot(repository) == before)
        // And git starts a rebase again (refusing only the changes).
        let next = await #expect(throws: GitError.self) {
            try await rebase(repository, base, feature)
        }
        #expect(next?.result.gitError == .rebaseWithStagedChanges)
    }

    @Test("saves an autostash to the stash list", arguments: ["rebase-merge", "rebase-apply"])
    func autostash(_ directory: String) async throws {
        let repository = try await Self.makeRepository()
        let autostash = JSCompat.trim(try await RebaseTesting.git(repository, ["stash", "create"]))
        try #require(!autostash.isEmpty)
        try await RebaseTesting.git(repository, ["reset", "-q", "--hard"])
        let before = try await Self.snapshot(repository)
        try await Self.leave(["\(directory)/autostash": autostash + "\n"], in: repository)

        try await quitRebase(repository)

        #expect(!isRebaseStateDirectoryPresent(repository))
        let after = try await Self.snapshot(repository)
        #expect(after.head == before.head)
        #expect(after.branch == before.branch)
        #expect(after.status == before.status)
        #expect(after.stashes == "\(autostash) autostash\n")
        // The stash has the changes the rebase set aside.
        try await RebaseTesting.git(repository, ["stash", "pop", "-q", "--index"])
        #expect(try String(contentsOfFile: POSIXPath.join(repository.path, "feature.txt"), encoding: .utf8) == "unstaged\n")
        #expect(try await RebaseTesting.git(repository, ["diff", "--cached", "--name-only"]) == "staged.txt\n")
    }

    @Test("leaves git am's rebase-apply alone, as ApplyingPatchesInProgress")
    func gitAm() async throws {
        let repository = try await Self.makeRepository()
        try await Self.leave(["rebase-apply/applying": "", "rebase-apply/next": "1\n", "rebase-apply/last": "1\n"], in: repository)
        let before = try await Self.snapshot(repository)

        let error = await #expect(throws: GitError.self) {
            try await quitRebase(repository)
        }
        #expect(error?.result.gitError == .applyingPatchesInProgress)
        #expect(Self.exists(repository, "rebase-apply/applying"))
        #expect(try await Self.snapshot(repository) == before)
    }

    @Test("with nothing left, does nothing")
    func nothingLeft() async throws {
        let repository = try await Self.makeRepository()
        let before = try await Self.snapshot(repository)
        try await quitRebase(repository)
        #expect(try await Self.snapshot(repository) == before)
    }
}
