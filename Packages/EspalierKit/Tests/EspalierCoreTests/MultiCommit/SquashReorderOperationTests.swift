// These drive `MultiCommitOperationsModel`'s squash and reorder against
// real git (GitKitTests/Git/Squash* and Reorder* have the git half): squash
// and reorder, their checks (merge commits, local changes, published
// commits), conflicts and continuing, aborting, undo, and hooks.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Squash and reorder", .offline) @MainActor
struct SquashReorderOperationTests {
    /// `main` (checked out) with "Number the lines" (README.md), then "Add
    /// a", "Add b", and "Add c", each adding its file. With `conflicting`,
    /// "Add a" and "Add b" also change README.md's first line, so replaying
    /// "Add b" without "Add a" conflicts. `publish` pushes all of it.
    private func makeRepository(
        conflicting: Bool = false,
        publish: Bool = false,
        responder: PromptCenter.Responder? = PromptResponder.failing(),
        git: GitRuntime? = nil
    ) async throws -> SelectedRepository {
        try await makeSelectedRepository(responder: responder, git: git) { local in
            try await commitFile(local, "README.md", numberedLines, message: "Number the lines")
            for name in ["a", "b", "c"] {
                if conflicting, name != "c" {
                    try Data(numberedLinesReplacing(1, with: "line \(name)").utf8).write(to: URL(filePath: POSIXPath.join(local.path, "README.md")))
                    try await runGit(["add", "README.md"], local)
                }
                try await commitFile(local, "\(name).txt", "\(name)\n", message: "Add \(name)")
            }
            if publish {
                try await runGit(["push", "-q", "origin", "main"], local)
            }
        }
    }

    private func commits(_ fixture: SelectedRepository) async throws -> (base: Commit, a: Commit, b: Commit, c: Commit) {
        (try await fixture.commit("HEAD~3"), try await fixture.commit("HEAD~2"), try await fixture.commit("HEAD~1"), try await fixture.commit("HEAD"))
    }

    // MARK: Squash

    @Test("squashes commits into one, with the message given, and offers an undo")
    func squashes() async throws {
        let fixture = try await makeRepository()
        let (base, a, _, c) = try await commits(fixture)
        let original = try await fixture.head()
        let operations = fixture.model.operations

        let result = try await operations.squash(
            [c],
            into: a,
            lastRetainedCommitRef: base.sha,
            message: CommitContext(summary: "Add a and c", description: "Both at once")
        )

        #expect(result == .squashed(count: 2))
        #expect(result.summary == "Squashed 2 commits.")
        #expect(try await fixture.summaries("\(base.sha)..main") == ["Add b", "Add a and c"])
        let squashed = try await fixture.commit("HEAD~1")
        #expect(JSCompat.trim(squashed.body) == "Both at once")
        #expect(try fixture.read("c.txt") == "c\n")
        #expect(operations.current == nil)
        let head = try await fixture.head()
        #expect(fixture.model.history.selection.shas == [head])
        #expect(operations.undo == MultiCommitUndo(
            kind: .squash,
            undoSha: original,
            branchName: "main",
            resultTip: head,
            commitCount: 2,
            createdBranch: nil
        ))
        // Unpublished: nothing to force push.
        #expect(operations.forcePushState == .notAvailable)
        await fixture.app.idle()
    }

    @Test("undoing a squash puts the commits back")
    func undoSquash() async throws {
        let fixture = try await makeRepository()
        let (base, a, b, c) = try await commits(fixture)
        let operations = fixture.model.operations
        _ = try await operations.squash([c, a], into: a, lastRetainedCommitRef: base.sha, message: CommitContext(summary: "Squashed", description: nil))

        let undone = try await operations.undoLastOperation()
        #expect(undone.undoneMessage == "Squash of 2 commits undone.")
        #expect(try await fixture.head() == c.sha)
        #expect(try await fixture.commit("HEAD~1").sha == b.sha)
        #expect(operations.undo == nil)
        await fixture.app.idle()
    }

    @Test("a merge commit among the commits replayed refuses squash and reorder in desktop's words")
    func mergeCommits() async throws {
        let fixture = try await makeRepository()
        let (base, a, _, c) = try await commits(fixture)
        try await runGit(["checkout", "-q", "-b", "side", base.sha], fixture.local)
        try await commitFile(fixture.local, "side.txt", "side\n", message: "Side")
        try await runGit(["checkout", "-q", "main"], fixture.local)
        try await runGit(["merge", "-q", "--no-ff", "-m", "Merge side", "side"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let operations = fixture.model.operations
        #expect(await operations.mergeCommitsExist(after: base.sha))
        #expect(!(await operations.mergeCommitsExist(after: "HEAD")))

        let squash = await #expect(throws: OperationError.self) {
            try await operations.squash([c], into: a, lastRetainedCommitRef: base.sha, message: CommitContext(summary: "x", description: nil))
        }
        #expect(squash?.reason == .precondition("Can't squash. Squashing replays every commit back to the oldest one involved, and none of them can be a merge commit."))
        let reorder = await #expect(throws: OperationError.self) {
            try await operations.reorder([c], before: a, lastRetainedCommitRef: base.sha)
        }
        #expect(reorder?.reason == .precondition("Can't reorder. Reordering replays every commit back to the oldest one involved, and none of them can be a merge commit."))
        #expect(try await fixture.summaries("-1") == ["Merge side"])
        await fixture.app.idle()
    }

    @Test("local changes refuse a squash with Stash Changes and Continue")
    func localChanges() async throws {
        let fixture = try await makeRepository()
        let (base, a, _, c) = try await commits(fixture)
        try fixture.write("a.txt", "changed\n")
        await fixture.model.refresh(.status, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.squash([c], into: a, lastRetainedCommitRef: base.sha, message: CommitContext(summary: "x", description: nil))
        }
        #expect(error?.reason == .localChangesOverwritten(files: ["a.txt"]))
        #expect(error?.message == "Can't squash while your branch has uncommitted changes. These files would be overwritten:")
        #expect(error?.retry?.kind == .squash)
        #expect(try await fixture.head() == c.sha)

        let recovery = try #require(error?.recoveries.first)
        #expect(recovery.title == "Stash Changes and Continue")
        try await recovery.perform(in: fixture.app)
        await fixture.model.idle()
        #expect(try await fixture.summaries("\(base.sha)..main") == ["Add b", "x"])
        #expect(try await fixture.stashList() == ["On main: !!Espalier<main>"])
        await fixture.app.idle()
    }

    @Test("squashing published commits asks first, then recommends a force push")
    func published() async throws {
        let fixture = try await makeRepository(publish: true)
        let (base, a, _, c) = try await commits(fixture)
        let operations = fixture.model.operations
        let message = CommitContext(summary: "Add a and c", description: nil)

        let error = await #expect(throws: OperationError.self) {
            try await operations.squash([c], into: a, lastRetainedCommitRef: base.sha, message: message)
        }
        #expect(error?.reason == .confirmationRequired(.rewritePublishedCommits(operation: "Squash")))
        #expect(error?.title == "Squash Pushed Commits?")

        // From the root, a published branch always asks.
        let fromRoot = await #expect(throws: OperationError.self) {
            try await operations.reorder([c], before: a, lastRetainedCommitRef: nil)
        }
        #expect(fromRoot?.reason == .confirmationRequired(.rewritePublishedCommits(operation: "Reorder")))

        #expect(try await operations.squash([c], into: a, lastRetainedCommitRef: base.sha, message: message, confirmed: [.rewritePublishedCommits]) == .squashed(count: 2))
        #expect(operations.forcePushState == .recommended)
        await fixture.app.idle()
    }

    @Test("squash conflicts stop it; continuing finishes it with its message")
    func squashConflicts() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let (base, a, _, c) = try await commits(fixture)
        let operations = fixture.model.operations
        let original = try await fixture.head()

        // Squashing "Add a" into "Add c" replays "Add b" first, without
        // "Add a": its README change conflicts.
        let outcome = try await operations.squash([a], into: c, lastRetainedCommitRef: base.sha, message: CommitContext(summary: "Add a and c", description: nil))
        #expect(outcome == .conflicted)
        let current = try #require(operations.current)
        #expect(current.kind == .squash)
        #expect(current.phase == .conflicted)
        #expect(current.originalBranchTip == original)
        #expect(current.conflictsMessage == "Resolve conflicts to continue squashing commits on main.")
        #expect(operations.conflictBranches == ConflictBranches(ours: "main", theirs: "squash commit"))
        #expect(operations.unresolvedFiles.map(\.path) == ["README.md"])

        // Keeping the base's line leaves "Add b" with nothing but b.txt.
        operations.setManualResolution(.ours, forPath: "README.md")
        let continued = try await operations.continueOperation()
        #expect(continued == .multiCommit(.squashed(count: 2)))
        #expect(try await fixture.summaries("\(base.sha)..main") == ["Add a and c", "Add b"])
        #expect(try fixture.read("README.md") == numberedLinesReplacing(1, with: "line a"))
        #expect(try fixture.read("b.txt") == "b\n")
        #expect(operations.current == nil)
        #expect(!fixture.hasRebaseState())
        // Still undoable after conflicts.
        #expect(operations.undo?.undoSha == original)
        try await operations.undoLastOperation()
        #expect(try await fixture.head() == original)
        await fixture.app.idle()
    }

    // MARK: Reorder

    @Test("reorders commits, before a commit or to the top, and undoes it")
    func reorders() async throws {
        let fixture = try await makeRepository()
        let (base, a, _, c) = try await commits(fixture)
        let operations = fixture.model.operations

        let result = try await operations.reorder([c], before: a, lastRetainedCommitRef: base.sha)
        #expect(result == .reordered(count: 1))
        #expect(result.summary == "Reordered 1 commit.")
        #expect(try await fixture.summaries("\(base.sha)..main") == ["Add b", "Add a", "Add c"])

        let undone = try await operations.undoLastOperation()
        #expect(undone.undoneMessage == "Reorder of 1 commit undone.")
        #expect(try await fixture.head() == c.sha)

        // To the top.
        let top = try await operations.reorder([a], before: nil, lastRetainedCommitRef: base.sha)
        #expect(top == .reordered(count: 1))
        #expect(try await fixture.summaries("\(base.sha)..main") == ["Add a", "Add c", "Add b"])
        await fixture.app.idle()
    }

    @Test("reorder conflicts stop it; aborting puts the branch back")
    func reorderConflictsAbort() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let (base, a, b, _) = try await commits(fixture)
        let operations = fixture.model.operations
        let original = try await fixture.head()

        #expect(try await operations.reorder([b], before: a, lastRetainedCommitRef: base.sha) == .conflicted)
        #expect(operations.current?.kind == .reorder)
        #expect(operations.conflictBranches == ConflictBranches(ours: "main", theirs: "reorder commit"))

        try await operations.abortOperation()
        #expect(try await fixture.head() == original)
        #expect(try await fixture.checkedOutBranch() == "main")
        #expect(!fixture.hasRebaseState())
        #expect(operations.current == nil)
        #expect(operations.undo == nil)
        await fixture.app.idle()
    }

    @Test("a reorder continued after conflicts counts its commits as one that didn't stop (desktop added one)")
    func reorderCountAfterConflicts() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let (base, a, b, _) = try await commits(fixture)
        let operations = fixture.model.operations
        #expect(try await operations.reorder([b], before: a, lastRetainedCommitRef: base.sha) == .conflicted)

        // Keep the base's line for "Add b", then "Add a" applies.
        operations.setManualResolution(.ours, forPath: "README.md")
        #expect(try await operations.continueOperation() == .multiCommit(.reordered(count: 1)))
        #expect(operations.undo?.commitCount == 1)
        await fixture.app.idle()
    }

    // MARK: Hooks

    @Test("a hook failing in a squash: Abort cancels it and the branch is as it was")
    func squashHookAborted() async throws {
        try await withIsolatedGitConfig { _ in
            try await withHooksRuntime { runtime in
                let fixture = try await makeRepository(responder: PromptResponder.hookFailures(.abort), git: runtime)
                let (base, a, _, c) = try await commits(fixture)
                try writeScript(fixture.local.path + "/.git/hooks/prepare-commit-msg", "#!/bin/sh\necho 'no squashing' >&2\nexit 1\n")

                let error = await #expect(throws: OperationError.self) {
                    try await fixture.model.operations.squash([c], into: a, lastRetainedCommitRef: base.sha, message: CommitContext(summary: "x", description: nil))
                }
                #expect(error?.reason == .cancelled(.hookAborted("prepare-commit-msg")))
                #expect(try await fixture.head() == c.sha)
                #expect(try await fixture.checkedOutBranch() == "main")
                #expect(!fixture.hasRebaseState())
                #expect(fixture.model.operations.current == nil)
                #expect(fixture.model.operations.undo == nil)
                await fixture.app.idle()
            }
        }
    }
}
