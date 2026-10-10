// `getRebaseStep` and `getCherryPickStep`, for the operation bar's
// "Stopped at commit 2 of 4", read from git's own state.

import EspalierSupport
import Foundation
@testable import GitKit
import Testing
import TestSupport

@Suite("Operation steps")
struct OperationStepTests {
    /// Runs git in `repository`; with `succeeds`, requires it to.
    @discardableResult
    private func run(_ args: [String], _ repository: Repository, succeeds: Bool = true) async throws -> String {
        let result = try await Dugite.exec(args, repository.path)
        if succeeds {
            try #require(result.exitCode == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func commit(_ path: String, _ contents: String, _ message: String, in repository: Repository) async throws -> String {
        try writeFileExactly(path, contents, in: repository.path)
        try await run(["add", "--", path], repository)
        try await run(["commit", "-q", "-m", message], repository)
        return try await run(["rev-parse", "HEAD"], repository)
    }

    /// `main` with a change to f.txt, and `feature` with four commits from
    /// before it, the second of which changes f.txt too: replaying them on
    /// `main` stops at the second. Returns the feature's commits, `feature`
    /// checked out.
    private func conflictingBranches() async throws -> (Repository, [String]) {
        let repository = try setupEmptyRepository("main")
        try await commit("f.txt", "base\n", "Base", in: repository)
        try await run(["checkout", "-q", "-b", "feature"], repository)
        var commits: [String] = []
        commits.append(try await commit("a.txt", "a\n", "Add a", in: repository))
        commits.append(try await commit("f.txt", "feature\n", "Change f on feature", in: repository))
        commits.append(try await commit("b.txt", "b\n", "Add b", in: repository))
        commits.append(try await commit("c.txt", "c\n", "Add c", in: repository))
        try await run(["checkout", "-q", "main"], repository)
        try await commit("f.txt", "main\n", "Change f on main", in: repository)
        try await run(["checkout", "-q", "feature"], repository)
        return (repository, commits)
    }

    @Test("a rebase stopped on conflicts is at its commit of all of them, with either backend")
    func rebase() async throws {
        for backend in ["merge", "apply"] {
            let (repository, _) = try await conflictingBranches()
            #expect(await getRebaseStep(repository) == nil)
            try await run(["-c", "rebase.backend=\(backend)", "rebase", "main"], repository, succeeds: false)
            #expect(isRebaseStateDirectoryPresent(repository), "\(backend)")
            #expect(await getRebaseStep(repository) == OperationStep(position: 2, total: 4), "\(backend)")

            try await run(["rebase", "--abort"], repository)
            #expect(await getRebaseStep(repository) == nil, "\(backend)")
        }
    }

    @Test("a cherry-pick of several commits stopped on conflicts is at its commit; one commit has no step")
    func cherryPick() async throws {
        let (repository, commits) = try await conflictingBranches()
        try await run(["checkout", "-q", "main"], repository)
        #expect(await getCherryPickStep(repository) == nil)

        try await run(["cherry-pick"] + commits, repository, succeeds: false)
        #expect(await isCherryPickHeadFound(repository))
        #expect(await getCherryPickStep(repository) == OperationStep(position: 2, total: 4))
        try await run(["cherry-pick", "--abort"], repository)
        #expect(await getCherryPickStep(repository) == nil)

        // One commit: git picks it without the sequencer, so there are no
        // steps to show.
        try await run(["cherry-pick", commits[1]], repository, succeeds: false)
        #expect(await isCherryPickHeadFound(repository))
        #expect(await getCherryPickStep(repository) == nil)
    }

    @Test("a rebase's step reads only numbers from 1 to the total; git am's state has none")
    func rebaseStateFiles() async throws {
        let repository = try setupEmptyRepository()
        let rebaseMerge = POSIXPath.join(repository.resolvedGitDir, "rebase-merge")
        try FileManager.default.createDirectory(atPath: rebaseMerge, withIntermediateDirectories: true)
        func write(_ name: String, _ contents: String) throws {
            try writeFileExactly(name, contents, in: rebaseMerge)
        }

        try write("msgnum", "1\n")
        // No total yet.
        #expect(await getRebaseStep(repository) == nil)
        try write("end", "3\n")
        #expect(await getRebaseStep(repository) == OperationStep(position: 1, total: 3))
        try write("msgnum", "4\n")
        #expect(await getRebaseStep(repository) == nil)
        try write("msgnum", "0\n")
        #expect(await getRebaseStep(repository) == nil)
        try write("msgnum", "two\n")
        #expect(await getRebaseStep(repository) == nil)

        // `git am` keeps its state in rebase-apply too, without `rebasing`.
        try FileManager.default.removeItem(atPath: rebaseMerge)
        let rebaseApply = POSIXPath.join(repository.resolvedGitDir, "rebase-apply")
        try FileManager.default.createDirectory(atPath: rebaseApply, withIntermediateDirectories: true)
        try writeFileExactly("next", "2\n", in: rebaseApply)
        try writeFileExactly("last", "5\n", in: rebaseApply)
        #expect(await getRebaseStep(repository) == nil)
        try writeFileExactly("rebasing", "", in: rebaseApply)
        #expect(await getRebaseStep(repository) == OperationStep(position: 2, total: 5))
    }
}
