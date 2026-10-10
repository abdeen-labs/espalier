// Tests for GitMergeTree.swift.

import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/merge-tree")
struct MergeTreeTests {
    /// `master` and `feature` both change `shared` from the first commit and
    /// each add files of their own.
    func setupDivergedRepository(conflictingFiles: [String]) async throws -> Repository {
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(
            entries: [TreeEntry(path: "shared", contents: "base\n")] + conflictingFiles.map { TreeEntry(path: $0, contents: "base\n") },
            commitMessage: "base"
        ))
        try await createBranch(repository, "feature", "HEAD")

        try await makeCommit(repository, Tree(
            entries: [TreeEntry(path: "master-only", contents: "master\n")]
                + conflictingFiles.map { TreeEntry(path: $0, contents: "master\n") },
            commitMessage: "master changes"
        ))

        try await switchTo(repository, "feature")
        try await makeCommit(repository, Tree(
            entries: [TreeEntry(path: "feature-only", contents: "feature\n")]
                + conflictingFiles.map { TreeEntry(path: $0, contents: "feature\n") },
            commitMessage: "feature changes"
        ))
        try await switchTo(repository, "master")
        return repository
    }

    @Test("reports a clean merge")
    func clean() async throws {
        let repository = try await setupDivergedRepository(conflictingFiles: [])
        let ours = try await getBranchOrError(repository, "master")
        let theirs = try await getBranchOrError(repository, "feature")

        let result = try await determineMergeability(repository, ours, theirs)
        #expect(result == .clean)
        #expect(result.kind == .clean)
    }

    @Test("reports conflicts with the number of conflicted files")
    func conflicts() async throws {
        let repository = try await setupDivergedRepository(conflictingFiles: ["one", "two", "three"])
        let ours = try await getBranchOrError(repository, "master")
        let theirs = try await getBranchOrError(repository, "feature")

        let result = try await determineMergeability(repository, ours, theirs)
        #expect(result == .conflicts(conflictedFiles: 3))
        #expect(result.kind == .conflicts)
    }

    @Test("counts a file with conflicts in several stages once")
    func modifyDelete() async throws {
        let repository = try await setupDivergedRepository(conflictingFiles: ["changed"])
        try await switchTo(repository, "feature")
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "changed", contents: nil)], commitMessage: "delete"))
        try await switchTo(repository, "master")
        let ours = try await getBranchOrError(repository, "master")
        let theirs = try await getBranchOrError(repository, "feature")

        #expect(try await determineMergeability(repository, ours, theirs) == .conflicts(conflictedFiles: 1))
    }

    @Test("reports unrelated histories as invalid")
    func unrelated() async throws {
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "a", contents: "a\n")], commitMessage: "on master"))
        _ = try await Dugite.exec(["checkout", "--orphan", "orphan"], repository.path)
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "b", contents: "b\n")], commitMessage: "on orphan"))

        let ours = try await getBranchOrError(repository, "master")
        let theirs = try await getBranchOrError(repository, "orphan")

        let result = try await determineMergeability(repository, ours, theirs)
        #expect(result == .invalid)
        #expect(result.kind == .invalid)
    }

    @Test("leaves the branches, the index, and the working tree alone")
    func readOnly() async throws {
        let repository = try await setupDivergedRepository(conflictingFiles: ["one"])
        let ours = try await getBranchOrError(repository, "master")
        let theirs = try await getBranchOrError(repository, "feature")

        _ = try await determineMergeability(repository, ours, theirs)

        #expect(try await getBranchOrError(repository, "master").tip == ours.tip)
        #expect(try await getBranchOrError(repository, "feature").tip == theirs.tip)
        #expect(try await getStatusOrThrow(repository).workingDirectory.files.isEmpty)
        #expect(!(await isMergeHeadSet(repository)))
    }

    // Not a clean merge: git exits with 1, as for conflicts, and writes
    // nothing on stdout.
    @Test("throws when git can't merge a tip at all")
    func unmergeableTip() async throws {
        let repository = try await setupDivergedRepository(conflictingFiles: [])
        let ours = try await getBranchOrError(repository, "master")
        let missing = Branch(
            name: "missing",
            upstream: nil,
            tip: BranchTip(sha: String(repeating: "1", count: 40)),
            type: .local,
            ref: "refs/heads/missing"
        )

        let error = await #expect(throws: GitError.self) {
            try await determineMergeability(repository, ours, missing)
        }
        #expect(error?.result.exitCode == 1)
        #expect(error?.message.contains("not something we can merge") == true)
    }
}
