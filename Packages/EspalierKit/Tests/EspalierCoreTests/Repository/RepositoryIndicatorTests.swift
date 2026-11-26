// What a repository's indicator says about its HEAD and the operation git
// stopped in, from real repositories selected in an app (every status a
// refresh pass loads makes the indicator, the selected repository's too).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// Where a case leaves HEAD.
enum ExpectedHead: Sendable {
    case branch(String)
    /// Detached at the commit this revision names.
    case detached(at: String)
    case unborn(String)
}

/// What a case does to the repository, and the indicator that follows.
struct IndicatorCase: Sendable {
    /// Git commands run in order; one that stops on a conflict fails, which
    /// is what the case is after.
    var commands: [[String]]
    /// Written to `file.txt` after the commands, unstaged.
    var resolution: String? = nil
    var head: ExpectedHead
    var stoppedOperation: RepositoryIndicator.StoppedOperation? = nil
    var changedFilesCount = 0
    var conflictedFilesCount = 0
}

@Suite("Repository indicator", .offline, .hangGuard(minutes: 5)) @MainActor
struct RepositoryIndicatorTests {
    /// A repository whose `main` and `feature` both changed `file.txt`
    /// since their common first commit (`feature` in two commits), with
    /// `feature` checked out: merging, rebasing onto, or cherry-picking
    /// `main` conflicts, and so does reverting `feature`'s first commit.
    private func divergedRepository() async throws -> Repository {
        let repository = try setupEmptyRepository("main")
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file.txt", contents: "base\n")], commitMessage: "Base"))
        try await runGit(["branch", "feature"], repository)
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file.txt", contents: "main\n")], commitMessage: "Main"))
        try await runGit(["checkout", "-q", "feature"], repository)
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file.txt", contents: "feature 1\n")], commitMessage: "Feature 1"))
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "file.txt", contents: "feature 2\n")], commitMessage: "Feature 2"))
        return repository
    }

    @Test("says where HEAD is, the operation git stopped in, and how many files have conflicts left", arguments: [
        NamedCase("a branch", IndicatorCase(
            commands: [],
            head: .branch("feature")
        )),
        NamedCase("a detached HEAD", IndicatorCase(
            commands: [["checkout", "-q", "--detach", "main"]],
            head: .detached(at: "main")
        )),
        // The orphan branch keeps the index: its file is new again.
        NamedCase("an unborn branch", IndicatorCase(
            commands: [["checkout", "-q", "--orphan", "fresh"]],
            head: .unborn("fresh"),
            changedFilesCount: 1
        )),
        NamedCase("a merge stopped on a conflict", IndicatorCase(
            commands: [["merge", "main"]],
            head: .branch("feature"),
            stoppedOperation: .merge,
            changedFilesCount: 1,
            conflictedFilesCount: 1
        )),
        // A squash merge leaves no MERGE_HEAD, only its message.
        NamedCase("a squash merge stopped on a conflict", IndicatorCase(
            commands: [["merge", "--squash", "main"]],
            head: .branch("feature"),
            stoppedOperation: .merge,
            changedFilesCount: 1,
            conflictedFilesCount: 1
        )),
        // A rebase detaches HEAD at the commit it replays onto.
        NamedCase("a rebase stopped on a conflict", IndicatorCase(
            commands: [["rebase", "main"]],
            head: .detached(at: "main"),
            stoppedOperation: .rebase,
            changedFilesCount: 1,
            conflictedFilesCount: 1
        )),
        NamedCase("a cherry-pick stopped on a conflict", IndicatorCase(
            commands: [["cherry-pick", "main"]],
            head: .branch("feature"),
            stoppedOperation: .cherryPick,
            changedFilesCount: 1,
            conflictedFilesCount: 1
        )),
        NamedCase("a revert stopped on a conflict", IndicatorCase(
            commands: [["revert", "--no-edit", "HEAD~1"]],
            head: .branch("feature"),
            stoppedOperation: .revert,
            changedFilesCount: 1,
            conflictedFilesCount: 1
        )),
        // The file is still unmerged in the index, with no marker left.
        NamedCase("a merge whose conflict was resolved in the file and not staged", IndicatorCase(
            commands: [["merge", "main"]],
            resolution: "main and feature\n",
            head: .branch("feature"),
            stoppedOperation: .merge,
            changedFilesCount: 1,
            conflictedFilesCount: 0
        )),
    ])
    func values(_ testCase: NamedCase<IndicatorCase>) async throws {
        let expected = testCase.value
        let repository = try await divergedRepository()
        for command in expected.commands {
            _ = try await runGitAllowingFailure(command, repository)
        }
        let harness = try AppHarness()
        if let resolution = expected.resolution {
            try harness.write("file.txt", resolution, in: repository)
        }
        let head: RepositoryIndicator.Head = switch expected.head {
        case .branch(let name):
            .branch(name: name)
        case .detached(let revision):
            .detached(sha: JSCompat.trim(try await runGit(["rev-parse", revision], repository)))
        case .unborn(let name):
            .unborn(branch: name)
        }

        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(repository, to: app)

        #expect(app.indicators[model.id] == RepositoryIndicator(
            head: head,
            aheadBehind: nil,
            changedFilesCount: expected.changedFilesCount,
            stoppedOperation: expected.stoppedOperation,
            conflictedFilesCount: expected.conflictedFilesCount
        ))
        await app.idle()
    }

    @Test("the selected repository's indicator follows its status: an operation aborted outside the app is gone from it")
    func followsTheStatus() async throws {
        let repository = try await divergedRepository()
        _ = try await runGitAllowingFailure(["merge", "main"], repository)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(repository, to: app)
        #expect(app.indicators[model.id]?.stoppedOperation == .merge)

        try await runGit(["merge", "--abort"], repository)
        await model.refresh(.status, reason: .user)

        #expect(app.indicators[model.id] == RepositoryIndicator(head: .branch(name: "feature"), aheadBehind: nil, changedFilesCount: 0))
        await app.idle()
    }

    @Test("names that differ only in Unicode normalization are different heads, as they are different branches")
    func exactNames() {
        let precomposed = RepositoryIndicator.Head.branch(name: "caf\u{E9}")
        let decomposed = RepositoryIndicator.Head.branch(name: "cafe\u{301}")
        #expect(precomposed != decomposed)
        #expect(precomposed == .branch(name: "caf\u{E9}"))
        // The same name on a branch with no commit yet is another state.
        #expect(precomposed != .unborn(branch: "caf\u{E9}"))
    }
}
