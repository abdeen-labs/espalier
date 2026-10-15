// These drive `MultiCommitOperationsModel`'s cherry-picks against real git
// (GitKitTests/Git/CherryPickTests has the git half): to a branch, to a new
// branch, onto a remote branch, conflicts, continuing and aborting,
// failures, local changes, ordering, undo, and a linked worktree.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Cherry-pick", .offline) @MainActor
struct CherryPickOperationTests {
    /// `main` with README.md ("First!"), `target` from it, and `feature`
    /// adding THING.md in "Cherry-picked Feature!"; then `feature` checked
    /// out, and a bare `origin` with all three. With `conflicting`, `target`
    /// and `feature` both change README.md, in "Target README" and "Feature
    /// README" (the commit to pick).
    private func makeRepository(
        conflicting: Bool = false,
        responder: PromptCenter.Responder? = PromptResponder.failing(),
        git: GitRuntime? = nil
    ) async throws -> SelectedRepository {
        let local = try await createCherryPickTestRepository("feature", "target")
        if conflicting {
            try await commitFile(local, "README.md", "# HELLO TARGET! \n", message: "Target README")
            try await runGit(["checkout", "-q", "feature"], local)
            try await commitFile(local, "README.md", "# HELLO FEATURE! \n", message: "Feature README")
        }
        try await runGit(["checkout", "-q", "feature"], local)
        let remote = try await makeBareRemote(from: local)
        try await runGit(["remote", "add", "origin", remote.path], local)
        try await runGit(["fetch", "-q", "origin"], local)
        let harness = try AppHarness(responder: responder, git: git)
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        return SelectedRepository(harness: harness, app: app, model: model, local: local, remote: remote)
    }

    // MARK: Cherry-picking

    @Test("copies a commit to a branch, stays there, selects the copy, and offers an undo")
    func toBranch() async throws {
        let fixture = try await makeRepository()
        let operations = fixture.model.operations
        let target = try fixture.branch("target")
        let commit = try await fixture.oneLine("feature")

        let result = try await operations.cherryPick([commit], onto: target)

        #expect(result == .cherryPicked(count: 1, targetBranch: "target"))
        #expect(try await fixture.checkedOutBranch() == "target")
        let head = try await fixture.commit("HEAD")
        #expect(head.summary == "Cherry-picked Feature!")
        #expect(head.sha != commit.sha)
        #expect(head.parentSHAs == [target.tip.sha])
        #expect(try fixture.read("THING.md") == "# HELLO WORLD! \nTHINGS GO HERE\n")
        // The new commit is selected.
        #expect(fixture.model.history.selection.shas == [head.sha])
        #expect(operations.current == nil)
        #expect(operations.undo == MultiCommitUndo(
            kind: .cherryPick,
            undoSha: target.tip.sha,
            branchName: "target",
            resultTip: head.sha,
            commitCount: 1,
            createdBranch: nil,
            sourceBranch: try fixture.branch("feature")
        ))
        // A cherry-pick never needs a force push.
        #expect(operations.rewrittenBranches.isEmpty)
        await fixture.app.idle()
    }

    @Test("undoing removes the copies and returns to the branch it started on")
    func undo() async throws {
        let fixture = try await makeRepository()
        let operations = fixture.model.operations
        let target = try fixture.branch("target")
        _ = try await operations.cherryPick([try await fixture.oneLine("feature")], onto: target)

        _ = try await operations.undoLastOperation()
        #expect(try await fixture.sha("target") == target.tip.sha)
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(operations.undo == nil)
        // Nothing left to undo.
        let again = await #expect(throws: OperationError.self) {
            try await operations.undoLastOperation()
        }
        #expect(preconditionText(again) != nil)
        await fixture.app.idle()
    }

    @Test("copies a commit of another branch onto the current branch, which the undo resets")
    func ontoCurrentBranch() async throws {
        let fixture = try await makeRepository()
        try await runGit(["checkout", "-q", "target"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let target = try fixture.branch("target")
        let operations = fixture.model.operations

        let result = try await operations.cherryPick([try await fixture.oneLine("feature")], onto: target)
        #expect(result == .cherryPicked(count: 1, targetBranch: "target"))
        #expect(try await fixture.summaries("main..target") == ["Cherry-picked Feature!"])
        #expect(operations.undo?.sourceBranch?.name == "target")

        try await operations.undoLastOperation()
        #expect(try await fixture.sha("target") == target.tip.sha)
        #expect(try await fixture.checkedOutBranch() == "target")
        await fixture.app.idle()
    }

    @Test("copies several commits oldest first, in one operation")
    func severalCommits() async throws {
        let fixture = try await makeRepository()
        try await commitFile(fixture.local, "OTHER.md", "other\n", message: "Second feature")
        await fixture.model.refresh(.full, reason: .user)
        let first = try await fixture.oneLine("feature~1")
        let second = try await fixture.oneLine("feature")

        let result = try await fixture.model.operations.cherryPick([first, second], onto: try fixture.branch("target"))
        #expect(result == .cherryPicked(count: 2, targetBranch: "target"))
        #expect(try await fixture.summaries("main..target") == ["Second feature", "Cherry-picked Feature!"])
        #expect(fixture.model.operations.undo?.commitCount == 2)
        await fixture.app.idle()
    }

    @Test("orders commits by the history, oldest first, when it lists them all")
    func ordering() {
        let a = CommitOneLine(sha: "a", summary: "A")
        let b = CommitOneLine(sha: "b", summary: "B")
        let c = CommitOneLine(sha: "c", summary: "C")
        // History newest first: c, b, a.
        #expect(orderCommitsByHistory([c, a, b], historySHAs: ["c", "b", "a"]) == [a, b, c])
        // A commit the history doesn't list keeps the order given.
        let d = CommitOneLine(sha: "d", summary: "D")
        #expect(orderCommitsByHistory([c, d, a], historySHAs: ["c", "b", "a"]) == [c, d, a])
        #expect(orderCommitsByHistory([b], historySHAs: []) == [b])
    }

    @Test("cherry-picks to a new branch, which undoing deletes")
    func toNewBranch() async throws {
        let fixture = try await makeRepository()
        let operations = fixture.model.operations
        let main = try await fixture.sha("main")

        let result = try await operations.cherryPick([try await fixture.oneLine("feature")], toNewBranch: "copies", startPoint: "main")
        #expect(result == .cherryPicked(count: 1, targetBranch: "copies"))
        #expect(try await fixture.checkedOutBranch() == "copies")
        #expect(try await fixture.commit("copies~1").sha == main)
        let undo = try #require(operations.undo)
        #expect(undo.createdBranch == "copies")
        #expect(undo.undoneMessage == nil)

        try await operations.undoLastOperation()
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(try await runGitAllowingFailure(["rev-parse", "--verify", "--quiet", "refs/heads/copies"], fixture.local) != 0)
        await fixture.app.idle()
    }

    @Test("refuses a new branch whose name is taken")
    func newBranchTaken() async throws {
        let fixture = try await makeRepository()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.cherryPick([try await fixture.oneLine("feature")], toNewBranch: "target")
        }
        #expect(preconditionText(error) != nil)
        #expect(try await fixture.checkedOutBranch() == "feature")
        await fixture.app.idle()
    }

    @Test("a remote branch target becomes a local branch, which the undo resets")
    func remoteTarget() async throws {
        let fixture = try await makeRepository()
        try await runGit(["push", "-q", "origin", "target"], fixture.local)
        try await runGit(["branch", "-D", "target"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let remote = try fixture.branch("origin/target")
        #expect(remote.type == .remote)
        let operations = fixture.model.operations

        let result = try await operations.cherryPick([try await fixture.oneLine("feature")], onto: remote)
        #expect(result == .cherryPicked(count: 1, targetBranch: "target"))
        #expect(try await fixture.checkedOutBranch() == "target")
        #expect(JSCompat.trim(try await runGit(["rev-parse", "--abbrev-ref", "target@{upstream}"], fixture.local)) == "origin/target")
        // The undo resets the local branch, not the remote branch's name.
        let undo = try #require(operations.undo)
        #expect(undo.branchName == "target")
        #expect(undo.undoSha == remote.tip.sha)

        _ = try await operations.undoLastOperation()
        #expect(try await fixture.sha("target") == remote.tip.sha)
        #expect(try await fixture.checkedOutBranch() == "feature")
        await fixture.app.idle()
    }

    // MARK: Local changes and failures

    @Test("any change, untracked files too, refuses it with Stash Changes and Continue")
    func localChanges() async throws {
        let fixture = try await makeRepository()
        try fixture.write("scratch.txt", "scratch\n")
        await fixture.model.refresh(.status, reason: .user)
        let target = try fixture.branch("target")
        let commit = try await fixture.oneLine("feature")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.cherryPick([commit], onto: target)
        }
        #expect(error?.reason == .localChangesOverwritten(files: ["scratch.txt"]))
        #expect(error?.retry?.kind == .cherryPick)
        #expect(try await fixture.checkedOutBranch() == "feature")

        let recovery = try #require(error?.recoveries.first)
        #expect(recovery.kind == .stashChangesAndRetry)
        try await recovery.perform(in: fixture.app)
        await fixture.model.idle()
        #expect(try await fixture.summaries("main..target") == ["Cherry-picked Feature!"])
        #expect(try await fixture.stashList() == ["On feature: !!Espalier<feature>"])
        await fixture.app.idle()
    }

    @Test("a cherry-pick to a new branch with changes offers the same, creating the branch on retry")
    func newBranchLocalChanges() async throws {
        let fixture = try await makeRepository()
        try fixture.write("THING.md", "changed\n")
        await fixture.model.refresh(.status, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.cherryPick([try await fixture.oneLine("feature")], toNewBranch: "copies", startPoint: "main")
        }
        // Nothing was created.
        #expect(try await runGitAllowingFailure(["rev-parse", "--verify", "--quiet", "refs/heads/copies"], fixture.local) != 0)
        try await #require(error?.recoveries.first).perform(in: fixture.app)
        await fixture.model.idle()
        #expect(try await fixture.checkedOutBranch() == "copies")
        #expect(try await fixture.summaries("main..copies") == ["Cherry-picked Feature!"])
        await fixture.app.idle()
    }

    @Test("a failed cherry-pick of several commits is aborted and returns to the branch it started on")
    func failureCleansUp() async throws {
        let fixture = try await makeRepository()
        try await commitFile(fixture.local, "OTHER.md", "other\n", message: "Second feature")
        await fixture.model.refresh(.full, reason: .user)
        let target = try fixture.branch("target")
        // git stops at the second commit, after copying the first.
        try writeScript(fixture.local.path + "/.git/hooks/prepare-commit-msg", """
            #!/bin/sh
            if grep -q 'Second feature' "$1"; then exit 1; fi
            exit 0
            """)

        let commits = [try await fixture.oneLine("feature~1"), try await fixture.oneLine("feature")]
        await #expect(throws: OperationError.self) {
            try await fixture.model.operations.cherryPick(commits, onto: target)
        }
        // Cleared, sequencer included: the target is as it was, and nothing is
        // in progress.
        #expect(try await fixture.sha("target") == target.tip.sha)
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(!fixture.gitFileExists("CHERRY_PICK_HEAD"))
        #expect(!fixture.gitFileExists("sequencer"))
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.model.operations.undo == nil)

        // The next attempt isn't refused.
        try FileManager.default.removeItem(atPath: fixture.local.path + "/.git/hooks/prepare-commit-msg")
        #expect(try await fixture.model.operations.cherryPick(commits, onto: target) == .cherryPicked(count: 2, targetBranch: "target"))
        await fixture.app.idle()
    }

    @Test("clearing a failed cherry-pick also aborts one blocked before a commit, which leaves only the sequencer")
    func clearsBlockedPick() async throws {
        let fixture = try await makeRepository()
        try await commitFile(fixture.local, "OTHER.md", "other\n", message: "Second feature")
        let commits = ["feature~1", "feature"]
        try await runGit(["checkout", "-q", "target"], fixture.local)
        let target = try await fixture.sha("target")
        // An untracked file in the way of the second commit: git copies the
        // first, then stops before the second.
        try fixture.write("OTHER.md", "in the way\n")
        #expect(try await runGitAllowingFailure(["cherry-pick"] + commits, fixture.local) != 0)
        #expect(!fixture.gitFileExists("CHERRY_PICK_HEAD"))
        #expect(fixture.gitFileExists("sequencer"))
        #expect(try await fixture.sha("target") != target)

        let context = OperationContext(
            repository: fixture.model.gitRepository,
            kind: .cherryPick,
            isBackgroundTask: false,
            hooks: .none,
            progress: .discarding,
            gitHubHTMLURL: nil,
            mainWorktreePath: nil
        )
        // (feature tracks OTHER.md, so the file would block going back
        // there; main doesn't.)
        await fixture.model.operations.clearCherryPickingHead(context, returningTo: try fixture.branch("main"), currentRemote: nil)
        #expect(!fixture.gitFileExists("sequencer"))
        #expect(try await fixture.sha("target") == target)
        #expect(try fixture.read("OTHER.md") == "in the way\n")
        #expect(try await fixture.checkedOutBranch() == "main")
        await fixture.app.idle()
    }

    @Test("an unknown commit fails and stays on the branch it started on")
    func unknownCommit() async throws {
        let fixture = try await makeRepository()
        let missing = CommitOneLine(sha: String(repeating: "1", count: 40), summary: "Missing")
        await #expect(throws: OperationError.self) {
            try await fixture.model.operations.cherryPick([missing], onto: try fixture.branch("target"))
        }
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(fixture.model.operations.current == nil)
        let none = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.cherryPick([], onto: try fixture.branch("target"))
        }
        #expect(preconditionText(none) != nil)
        await fixture.app.idle()
    }

    @Test("refuses to start over an operation begun since the last refresh, before checking anything out")
    func operationStartedElsewhere() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let target = try fixture.branch("target")
        let commit = try await fixture.oneLine("feature~1")
        // Not refreshed: the model still sees feature, clean.
        try await runGit(["checkout", "-q", "target"], fixture.local)
        #expect(try await runGitAllowingFailure(["cherry-pick", "feature"], fixture.local) != 0)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.cherryPick([commit], onto: try fixture.branch("main"))
        }
        #expect(preconditionText(error) != nil)
        #expect(try await fixture.checkedOutBranch() == "target")
        #expect(try await fixture.sha("target") == target.tip.sha)
        // The refresh shows the one in progress.
        await fixture.model.operations.enrichmentIdle()
        #expect(fixture.model.operations.current?.origin == .rebuilt)
        #expect(fixture.model.operations.current?.kind == .cherryPick)
        await fixture.app.idle()
    }

    // MARK: Conflicts

    @Test("conflicts stop the cherry-pick; continuing with the chosen side finishes it")
    func conflictsThenContinue() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        let target = try fixture.branch("target")
        let feature = try fixture.branch("feature")
        let commits = [try await fixture.oneLine("feature~1"), try await fixture.oneLine("feature")]

        let outcome = try await operations.cherryPick(commits, onto: target)
        #expect(outcome == .conflicted)
        #expect(try await fixture.checkedOutBranch() == "target")
        #expect(operations.conflictState == .cherryPick(targetBranchName: "target", manualResolutions: [:]))
        let current = try #require(operations.current)
        #expect(current.kind == .cherryPick)
        #expect(current.origin == .espalier)
        #expect(current.phase == .conflicted)
        #expect(current.detail == .cherryPick(sourceBranch: feature, branchCreated: false, commits: commits))
        #expect(current.originalBranchTip == target.tip.sha)
        #expect(operations.conflictBranches == ConflictBranches(ours: "target", theirs: "feature"))
        #expect(operations.unresolvedFiles.map(\.path) == ["README.md"])
        #expect(fixture.model.gitState.inProgress == .cherryPick)
        #expect(operations.undo == nil)

        operations.setManualResolution(.theirs, forPath: "README.md")
        let continued = try await operations.continueOperation()
        #expect(continued == .multiCommit(.cherryPicked(count: 2, targetBranch: "target")))
        #expect(try fixture.read("README.md") == "# HELLO FEATURE! \n")
        #expect(try await fixture.summaries("main..target") == ["Feature README", "Cherry-picked Feature!", "Target README"])
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        #expect(!fixture.gitFileExists("CHERRY_PICK_HEAD"))
        // Continued, it's still undoable, back to the target's old tip.
        #expect(operations.undo?.undoSha == target.tip.sha)
        #expect(operations.undo?.commitCount == 2)
        #expect(fixture.model.history.selection.shas == [try await fixture.head()])
        await fixture.app.idle()
    }

    @Test("conflicts git's messages don't name (rename/delete) wait for the user too (desktop aborted)")
    func renameDeleteConflict() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await commitFile(local, "README.md", numberedLines, message: "Number the lines")
            try await runGit(["branch", "target"], local)
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await runGit(["mv", "README.md", "DOC.md"], local)
            try await runGit(["commit", "-q", "-m", "Rename README"], local)
            try await runGit(["checkout", "-q", "target"], local)
            try await runGit(["rm", "-q", "README.md"], local)
            try await runGit(["commit", "-q", "-m", "Remove README"], local)
            try await runGit(["checkout", "-q", "feature"], local)
        }
        let operations = fixture.model.operations

        let outcome = try await operations.cherryPick([try await fixture.oneLine("feature")], onto: try fixture.branch("target"))
        #expect(outcome == .conflicted)
        #expect(operations.conflictState == .cherryPick(targetBranchName: "target", manualResolutions: [:]))
        #expect(operations.current?.origin == .espalier)
        #expect(operations.unresolvedFiles.map(\.path) == ["DOC.md"])

        operations.setManualResolution(.theirs, forPath: "DOC.md")
        #expect(try await operations.continueOperation() == .multiCommit(.cherryPicked(count: 1, targetBranch: "target")))
        #expect(try fixture.read("DOC.md") == numberedLines)
        #expect(try await fixture.summaries("-1") == ["Rename README"])
        await fixture.app.idle()
    }

    @Test("aborting a conflicted cherry-pick returns to the branch it started on")
    func abort() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        let target = try fixture.branch("target")
        #expect(try await operations.cherryPick([try await fixture.oneLine("feature")], onto: target) == .conflicted)

        try await operations.abortOperation()
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(try await fixture.sha("target") == target.tip.sha)
        #expect(!fixture.gitFileExists("CHERRY_PICK_HEAD"))
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        await fixture.app.idle()
    }

    @Test("aborting still aborts when the branch it started on is gone")
    func abortWithoutSource() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        let target = try fixture.branch("target")
        #expect(try await operations.cherryPick([try await fixture.oneLine("feature")], onto: target) == .conflicted)
        // Gone, also from origin (git would check it out from there).
        try await runGit(["branch", "-D", "feature"], fixture.local)
        try await runGit(["branch", "-D", "-r", "origin/feature"], fixture.local)

        try await operations.abortOperation()
        #expect(try await fixture.checkedOutBranch() == "target")
        #expect(try await fixture.sha("target") == target.tip.sha)
        #expect(!fixture.gitFileExists("CHERRY_PICK_HEAD"))
        #expect(operations.current == nil)
        await fixture.app.idle()
    }

    @Test("a cherry-pick started elsewhere is continued, without an undo")
    func externalCherryPick() async throws {
        let fixture = try await makeRepository(conflicting: true)
        try await runGit(["checkout", "-q", "target"], fixture.local)
        #expect(try await runGitAllowingFailure(["cherry-pick", "feature"], fixture.local) != 0)
        await fixture.refreshAll()
        let operations = fixture.model.operations
        #expect(operations.current?.origin == .rebuilt)

        operations.setManualResolution(.ours, forPath: "README.md")
        #expect(try await operations.continueOperation() == .multiCommit(.cherryPicked(count: 1, targetBranch: "target")))
        #expect(try fixture.read("README.md") == "# HELLO TARGET! \n")
        // An empty resolution keeps the commit in the branch's history.
        #expect(try await fixture.summaries("-1") == ["Feature README"])
        // A rebuilt cherry-pick has no undo point.
        #expect(operations.undo == nil)
        await fixture.app.idle()
    }

    // MARK: Undo

    @Test("undo is offered only while the branch is at the result and nothing changed")
    func undoValidity() async throws {
        let fixture = try await makeRepository()
        let operations = fixture.model.operations
        _ = try await operations.cherryPick([try await fixture.oneLine("feature")], onto: try fixture.branch("target"))
        let offered = try #require(operations.undo)

        // A change hides it; undoing the change brings it back.
        try fixture.write("scratch.txt", "scratch\n")
        await fixture.model.refresh(.status, reason: .fileSystem)
        #expect(operations.undo == nil)
        let dirty = await #expect(throws: OperationError.self) {
            try await operations.undoLastOperation()
        }
        #expect(preconditionText(dirty) != nil)
        try FileManager.default.removeItem(atPath: fixture.local.path + "/scratch.txt")
        await fixture.model.refresh(.status, reason: .fileSystem)
        #expect(operations.undo == offered)

        // A newer commit ends it for good, even once it's gone again.
        try await commitFile(fixture.local, "later.txt", "later\n", message: "Later")
        await fixture.model.refresh(.status, reason: .fileSystem)
        #expect(operations.undo == nil)
        try await runGit(["reset", "-q", "--hard", "HEAD~1"], fixture.local)
        await fixture.model.refresh(.status, reason: .fileSystem)
        #expect(operations.undo == nil)
        await fixture.app.idle()
    }

    @Test("undo checks again before resetting: a change made since the last refresh stops it")
    func undoRechecks() async throws {
        let fixture = try await makeRepository()
        let operations = fixture.model.operations
        _ = try await operations.cherryPick([try await fixture.oneLine("feature")], onto: try fixture.branch("target"))
        let result = try await fixture.head()
        #expect(operations.undo != nil)

        // Not refreshed yet.
        try fixture.write("THING.md", "precious\n")
        let error = await #expect(throws: OperationError.self) {
            try await operations.undoLastOperation()
        }
        #expect(preconditionText(error) != nil)
        #expect(try await fixture.head() == result)
        #expect(try fixture.read("THING.md") == "precious\n")
        await fixture.app.idle()
    }

    // MARK: Hooks

    /// Answers hook failure prompts with `answers`, in order.
    private func hookFailureResponder(_ answers: [HookFailureResolution]) -> PromptCenter.Responder {
        let remaining = Mutex(answers)
        return { prompt in
            let next = remaining.withLock { answers -> HookFailureResolution? in
                answers.isEmpty ? nil : answers.removeFirst()
            }
            guard case .hookFailed = prompt, let answer = next else {
                Issue.record("Unexpected prompt \(prompt)")
                return prompt.cancelledAnswer
            }
            return .hookFailure(answer)
        }
    }

    @Test("a hook failing halfway through asks: Abort puts the target back and returns to the branch it started on; Ignore copies the commits")
    func hookFailure() async throws {
        try await withIsolatedGitConfig { _ in
            try await withHooksRuntime { runtime in
                let fixture = try await makeRepository(responder: hookFailureResponder([.abort, .ignore]), git: runtime)
                try await commitFile(fixture.local, "OTHER.md", "other\n", message: "Second feature")
                await fixture.model.refresh(.full, reason: .user)
                // Fails for the second commit only.
                try writeScript(fixture.local.path + "/.git/hooks/prepare-commit-msg", """
                    #!/bin/sh
                    if grep -q 'Second feature' "$1"; then echo 'lint failed' >&2; exit 1; fi
                    exit 0
                    """)
                let operations = fixture.model.operations
                let target = try fixture.branch("target")
                let commits = [try await fixture.oneLine("feature~1"), try await fixture.oneLine("feature")]

                let error = await #expect(throws: OperationError.self) {
                    try await operations.cherryPick(commits, onto: target)
                }
                #expect(error?.reason == .cancelled(.hookAborted("prepare-commit-msg")))
                #expect(error?.isCancellation == true)
                #expect(try await fixture.sha("target") == target.tip.sha)
                #expect(try await fixture.checkedOutBranch() == "feature")
                #expect(!fixture.gitFileExists("CHERRY_PICK_HEAD"))
                #expect(!fixture.gitFileExists("sequencer"))
                #expect(operations.current == nil)
                guard case .hookFailed(let name, let output)? = fixture.harness.prompts.history.first else {
                    Issue.record("No hook prompt: \(fixture.harness.prompts.history)")
                    return
                }
                #expect(name == "prepare-commit-msg")
                #expect(output.contains("lint failed"))

                #expect(try await operations.cherryPick(commits, onto: target) == .cherryPicked(count: 2, targetBranch: "target"))
                #expect(try await fixture.summaries("main..target") == ["Second feature", "Cherry-picked Feature!"])
                #expect(fixture.harness.prompts.history.count == 2)
                await fixture.app.idle()
            }
        }
    }

    @Test("stopping a running hook cancels the cherry-pick and puts the target back", .hangGuard(minutes: 5))
    func hookStopped() async throws {
        try await withIsolatedGitConfig { _ in
            try await withHooksRuntime { runtime in
                let fixture = try await makeRepository(git: runtime)
                try writeScript(fixture.local.path + "/.git/hooks/prepare-commit-msg", """
                    #!/bin/sh
                    while :; do sleep 0.05; done
                    """)
                let target = try fixture.branch("target")
                let commit = try await fixture.oneLine("feature")
                let operations = fixture.model.operations

                let cherryPick = Task { @MainActor in try await operations.cherryPick([commit], onto: target) }
                await waitUntilObserved { fixture.model.localOperation?.hook?.name == "prepare-commit-msg" }
                fixture.model.abortRunningHook()

                let error = await #expect(throws: OperationError.self) { try await cherryPick.value }
                #expect(error?.reason == .cancelled(.hookAborted("prepare-commit-msg")))
                #expect(try await fixture.sha("target") == target.tip.sha)
                #expect(try await fixture.checkedOutBranch() == "feature")
                #expect(!fixture.gitFileExists("CHERRY_PICK_HEAD"))
                #expect(operations.current == nil)
                await fixture.app.idle()
            }
        }
    }

    @Test("continuing runs the commit hooks through the hooks environment; Abort keeps the cherry-pick waiting, Ignore finishes it")
    func continueHooks() async throws {
        try await withIsolatedGitConfig { _ in
            try await withHooksRuntime { runtime in
                let fixture = try await makeRepository(conflicting: true, responder: hookFailureResponder([.abort, .ignore]), git: runtime)
                let operations = fixture.model.operations
                let target = try fixture.branch("target")
                let commits = [try await fixture.oneLine("feature~1"), try await fixture.oneLine("feature")]
                #expect(try await operations.cherryPick(commits, onto: target) == .conflicted)
                try writeScript(fixture.local.path + "/.git/hooks/pre-commit", "#!/bin/sh\necho 'lint failed' >&2\nexit 1\n")
                operations.setManualResolution(.theirs, forPath: "README.md")

                let aborted = await #expect(throws: OperationError.self) {
                    try await operations.continueOperation()
                }
                #expect(aborted?.reason == .cancelled(.hookAborted("pre-commit")))
                #expect(fixture.gitFileExists("CHERRY_PICK_HEAD"))
                #expect(try await fixture.checkedOutBranch() == "target")
                #expect(try await fixture.summaries("main..target") == ["Cherry-picked Feature!", "Target README"])
                #expect(operations.current?.phase == .conflicted)
                #expect(operations.canContinue)

                #expect(try await operations.continueOperation() == .multiCommit(.cherryPicked(count: 2, targetBranch: "target")))
                #expect(try await fixture.summaries("main..target") == ["Feature README", "Cherry-picked Feature!", "Target README"])
                #expect(!fixture.gitFileExists("CHERRY_PICK_HEAD"))
                #expect(operations.current == nil)
                await fixture.app.idle()
            }
        }
    }

    // MARK: Linked worktrees

    @Test("in a linked worktree, conflicts are found in its git directory and continued")
    func linkedWorktree() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let worktreePath = POSIXPath.join(try createTempDirectory(), "linked")
        try await runGit(["worktree", "add", "-q", worktreePath, "target"], fixture.local)
        let linked = Repository(path: worktreePath)
        let model = try await fixture.harness.addAndSelect(linked, to: fixture.app)
        let gitDir = try #require(model.record.gitDir)
        #expect(gitDir != fixture.local.resolvedGitDir)
        let target = try #require(model.gitState.tip.branch)
        #expect(target.name == "target")

        let operations = model.operations
        #expect(try await operations.cherryPick([try await fixture.oneLine("feature")], onto: target) == .conflicted)
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(gitDir, "CHERRY_PICK_HEAD")))
        #expect(!fixture.gitFileExists("CHERRY_PICK_HEAD"))
        #expect(operations.conflictState == .cherryPick(targetBranchName: "target", manualResolutions: [:]))
        #expect(model.gitState.inProgress == .cherryPick)
        // The main worktree has nothing in progress.
        await fixture.refreshAll()
        #expect(fixture.model.operations.current == nil)

        operations.setManualResolution(.theirs, forPath: "README.md")
        #expect(try await operations.continueOperation() == .multiCommit(.cherryPicked(count: 1, targetBranch: "target")))
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(gitDir, "CHERRY_PICK_HEAD")))
        #expect(try String(contentsOfFile: POSIXPath.join(worktreePath, "README.md"), encoding: .utf8) == "# HELLO FEATURE! \n")
        #expect(operations.current == nil)
        await fixture.app.idle()
    }
}
