// These drive `SyncModel.pull()` against local bare remotes: pulling, the
// remote HEAD, conflicts as state (merge and rebase, the reducer naming
// the upstream), fast-forwarding other branches, local changes in the way,
// preconditions, and a hook abort, which isn't an error.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Pull", .offline) @MainActor
struct PullOperationTests {
    /// A repository whose README.md has eight numbered lines, on `main`
    /// tracking `origin/main`, with `origin` changing line `remoteLine` and
    /// the local branch line `localLine` (nil: no local commit).
    private func makeDivergedRepository(
        remoteLine: Int,
        localLine: Int?,
        responder: PromptCenter.Responder? = PromptResponder.failing(),
        git: GitRuntime? = nil,
        configure: (Repository) async throws -> Void = { _ in }
    ) async throws -> SelectedRepository {
        let fixture = try await makeSelectedRepository(responder: responder, git: git) { local in
            try await commitFile(local, "README.md", numberedLines, message: "Number the lines")
            try await runGit(["push", "-q", "origin", "main"], local)
            try await configure(local)
        }
        let other = try await cloneRepository(fixture.remote)
        try await commitFile(other, "README.md", numberedLinesReplacing(remoteLine, with: "theirs"), message: "Theirs")
        try await runGit(["push", "-q", "origin", "main"], other)
        if let localLine {
            try await commitFile(fixture.local, "README.md", numberedLinesReplacing(localLine, with: "ours"), message: "Ours")
        }
        try await runGit(["fetch", "-q", "origin"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        return fixture
    }

    @Test("pulls the remote's commits and returns after the refresh")
    func pulls() async throws {
        let fixture = try await makeDivergedRepository(remoteLine: 8, localLine: nil)
        let remoteTip = try #require(try await fixture.remoteTip("main"))
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 1))

        #expect(try await fixture.model.sync.pull() == .completed)

        #expect(try await fixture.head() == remoteTip)
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 0))
        #expect(fixture.model.gitState.tip.branch?.tip.sha == remoteTip)
        #expect(fixture.model.sync.action == .fetch(remote: "origin"))
        #expect(fixture.model.refreshScheduler.lastPassReasons.contains(.operation(.pull)))
        await fixture.app.idle()
    }

    @Test("merges diverged branches when pull.rebase is unset")
    func merges() async throws {
        let fixture = try await makeDivergedRepository(remoteLine: 8, localLine: 1)
        #expect(try await fixture.model.sync.pull() == .completed)
        #expect(try await fixture.headParentCount() == 2)
        #expect(try fixture.read("README.md") == (1...8).map { $0 == 1 ? "ours" : $0 == 8 ? "theirs" : "line \($0)" }.joined(separator: "\n") + "\n")
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 2, behind: 0))
        await fixture.app.idle()
    }

    @Test("updates the remote's HEAD after pulling")
    func updatesRemoteHEAD() async throws {
        let fixture = try await makeDivergedRepository(remoteLine: 8, localLine: nil)
        let other = try await cloneRepository(fixture.remote)
        try await runGit(["checkout", "-q", "-b", "develop"], other)
        try await runGit(["push", "-q", "origin", "develop"], other)
        try await runGit(["symbolic-ref", "HEAD", "refs/heads/develop"], fixture.remote)

        _ = try await fixture.model.sync.pull()

        #expect(try await symbolicRef("refs/remotes/origin/HEAD", in: fixture.local) == "refs/remotes/origin/develop")
        await fixture.app.idle()
    }

    @Test("conflicts end the pull as a merge waiting on them, named after the upstream")
    func mergeConflicts() async throws {
        let fixture = try await makeDivergedRepository(remoteLine: 1, localLine: 1)

        #expect(try await fixture.model.sync.pull() == .conflicted)

        let operations = fixture.model.operations
        guard case .merge(let currentBranch, _, _)? = operations.conflictState else {
            Issue.record("Unexpected conflict state \(String(describing: operations.conflictState))")
            return
        }
        #expect(currentBranch == "main")
        #expect(fixture.gitFileExists("MERGE_HEAD"))
        #expect(operations.current?.kind == .merge)
        #expect(operations.current?.phase == .conflicted)
        await operations.enrichmentIdle()
        #expect(operations.conflictBranches == ConflictBranches(ours: "main", theirs: "origin/main"))
        #expect(operations.unresolvedFiles.map(\.path) == ["README.md"])
        await fixture.app.idle()
    }

    @Test("with pull.rebase, conflicts end the pull as a rebase waiting on them")
    func rebaseConflicts() async throws {
        let fixture = try await makeDivergedRepository(remoteLine: 1, localLine: 1, configure: { local in
            try await runGit(["config", "pull.rebase", "true"], local)
        })
        #expect(fixture.model.gitState.branches.pullWithRebase == true)

        #expect(try await fixture.model.sync.pull() == .conflicted)

        let operations = fixture.model.operations
        guard case .rebase(_, let targetBranch, _, _, _, _)? = operations.conflictState else {
            Issue.record("Unexpected conflict state \(String(describing: operations.conflictState))")
            return
        }
        #expect(targetBranch == "main")
        #expect(operations.current?.kind == .rebase)
        if case .rebase? = fixture.model.gitState.inProgress {} else {
            Issue.record("No rebase in progress: \(String(describing: fixture.model.gitState.inProgress))")
        }
        await operations.enrichmentIdle()
        await fixture.app.idle()
    }

    @Test("with GIT_ADVICE=0 in git's environment, a pull with rebase still stops on its conflicts")
    func rebaseConflictsWithoutAdvice() async throws {
        var runtime = GitRuntime.current
        runtime.processEnvironment["GIT_ADVICE"] = "0"
        let fixture = try await makeDivergedRepository(remoteLine: 1, localLine: 1, git: runtime, configure: { local in
            try await runGit(["config", "pull.rebase", "true"], local)
        })

        #expect(try await fixture.model.sync.pull() == .conflicted)

        guard case .rebase? = fixture.model.operations.conflictState else {
            Issue.record("Unexpected conflict state \(String(describing: fixture.model.operations.conflictState))")
            return
        }
        await fixture.model.operations.enrichmentIdle()
        await fixture.app.idle()
    }

    @Test("fast-forwards other branches, even when the pull stops on conflicts (as desktop)")
    func fastForwardsOtherBranches() async throws {
        let fixture = try await makeDivergedRepository(remoteLine: 1, localLine: 1, configure: { local in
            try await runGit(["branch", "feature"], local)
            try await runGit(["push", "-q", "-u", "origin", "feature"], local)
        })
        let other = try await cloneRepository(fixture.remote)
        try await runGit(["checkout", "-q", "feature"], other)
        let featureTip = try await commitFile(other, "feature.txt", "feature\n")
        try await runGit(["push", "-q", "origin", "feature"], other)

        #expect(try await fixture.model.sync.pull() == .conflicted)

        #expect(try await fixture.localSHA("refs/heads/feature") == featureTip)
        await fixture.model.operations.enrichmentIdle()
        await fixture.app.idle()
    }

    @Test("local changes in the way offer to stash them and pull again")
    func localChanges() async throws {
        let fixture = try await makeDivergedRepository(remoteLine: 8, localLine: nil)
        try fixture.write("README.md", numberedLinesReplacing(8, with: "uncommitted"))
        await fixture.model.refresh(.status, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.pull()
        }
        guard case .localChangesOverwritten(let files)? = error?.reason else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
        #expect(files == ["README.md"])
        #expect(error?.gitContext == .pull(currentBranch: "main", theirBranch: "origin/main"))
        #expect(error?.retry?.kind == .pull)
        let recovery = try #require(error?.recoveries.first)
        #expect(recovery.kind == .stashChangesAndRetry)

        try await recovery.perform(in: fixture.app)
        #expect(try await fixture.head() == (try await fixture.remoteTip("main")))
        #expect(fixture.model.stash.current != nil)
        await fixture.app.idle()
    }

    @Test("staged changes in the way of a pull with rebase offer to stash them and pull again")
    func stagedChangesWithRebase() async throws {
        let fixture = try await makeDivergedRepository(remoteLine: 8, localLine: nil, configure: { local in
            try await runGit(["config", "pull.rebase", "true"], local)
        })
        try fixture.write("notes.txt", "staged\n")
        try await runGit(["add", "notes.txt"], fixture.local)
        await fixture.model.refresh(.status, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.pull()
        }
        #expect(error?.reason == .localChangesOverwritten(files: []))
        #expect(error?.gitFailure?.gitError == .rebaseWithStagedChanges)
        #expect(error?.retry?.kind == .pull)
        let recovery = try #require(error?.recoveries.first)
        #expect(recovery.kind == .stashChangesAndRetry)

        try await recovery.perform(in: fixture.app)
        #expect(try await fixture.head() == (try await fixture.remoteTip("main")))
        #expect(fixture.model.stash.current != nil)
        await fixture.app.idle()
    }

    /// A diverged repository that pulls with rebase, with an untracked file
    /// and the rebase state `leave` leaves in its git directory.
    private func makeRepositoryWithRebaseState(_ leave: (Repository) async throws -> Void) async throws -> SelectedRepository {
        let fixture = try await makeDivergedRepository(remoteLine: 8, localLine: 1, configure: { local in
            try await runGit(["config", "pull.rebase", "true"], local)
        })
        try fixture.write("untracked.txt", "untracked\n")
        try await leave(fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        return fixture
    }

    @Test("a rebase's state Espalier can't continue or abort offers Clear Old Rebase and Continue, which clears it and pulls")
    func leftoverRebase() async throws {
        let fixture = try await makeRepositoryWithRebaseState { local in
            try FileManager.default.createDirectory(atPath: POSIXPath.join(local.path, ".git/rebase-merge"), withIntermediateDirectories: false)
        }
        // Nothing shows a rebase.
        #expect(fixture.model.gitState.inProgress == nil)
        #expect(fixture.model.operations.conflictState == nil)
        let ours = try await fixture.head()

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.pull()
        }
        guard case .precondition(let message)? = error?.reason else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
        #expect(message == LeftoverRebase(hasAutostash: false).message)
        #expect(error?.gitFailure?.gitError == .rebaseAlreadyInProgress)
        let recovery = try #require(error?.recoveries.first)
        #expect(error?.recoveries.count == 1)
        #expect(recovery.kind == .clearLeftoverRebaseAndRetry)
        // Refusing changed nothing.
        #expect(try await fixture.head() == ours)
        #expect(fixture.gitFileExists("rebase-merge"))

        try await recovery.perform(in: fixture.app)

        #expect(!fixture.gitFileExists("rebase-merge"))
        #expect(!fixture.gitFileExists("REBASE_HEAD"))
        // Rebased onto the remote's commit.
        let remoteTip = try #require(try await fixture.remoteTip("main"))
        #expect(JSCompat.trim(try await runGit(["rev-parse", "HEAD~1"], fixture.local)) == remoteTip)
        #expect(try await runGit(["symbolic-ref", "HEAD"], fixture.local) == "refs/heads/main\n")
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 1, behind: 0))
        #expect(try fixture.read("untracked.txt") == "untracked\n")
        #expect(try await fixture.stashList().isEmpty)
        #expect(fixture.model.gitState.inProgress == nil)
        await fixture.app.idle()
    }

    @Test("clearing a rebase's state with an autostash says so, and saves it to the stash list")
    func leftoverRebaseWithAutostash() async throws {
        var autostash = ""
        let fixture = try await makeRepositoryWithRebaseState { local in
            try Data("set aside\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "README.md")))
            autostash = JSCompat.trim(try await runGit(["stash", "create"], local))
            try await runGit(["reset", "-q", "--hard"], local)
            let directory = POSIXPath.join(local.path, ".git/rebase-merge")
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            try Data("refs/heads/main\n".utf8).write(to: URL(filePath: POSIXPath.join(directory, "head-name")))
            try Data("\(autostash)\n".utf8).write(to: URL(filePath: POSIXPath.join(directory, "autostash")))
        }
        try #require(!autostash.isEmpty)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.pull()
        }
        #expect(error?.message == LeftoverRebase(hasAutostash: true).message)
        let recovery = try #require(error?.recoveries.first)

        try await recovery.perform(in: fixture.app)

        #expect(!fixture.gitFileExists("rebase-merge"))
        #expect(try await runGit(["stash", "list", "--format=%H %gs"], fixture.local) == "\(autostash) autostash\n")
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 1, behind: 0))
        await fixture.app.idle()
    }

    @Test("a rebase Espalier shows, interrupted between commits, isn't offered to be cleared")
    func interruptedRebaseNotCleared() async throws {
        let fixture = try await makeRepositoryWithRebaseState { local in
            let head = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))
            let directory = POSIXPath.join(local.path, ".git/rebase-merge")
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            for (name, contents) in [("head-name", "refs/heads/main"), ("orig-head", head), ("onto", head)] {
                try Data("\(contents)\n".utf8).write(to: URL(filePath: POSIXPath.join(directory, name)))
            }
        }
        guard case .rebase? = fixture.model.gitState.inProgress else {
            Issue.record("No rebase shown: \(String(describing: fixture.model.gitState.inProgress))")
            return
        }

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.pull()
        }
        #expect(error?.gitFailure?.gitError == .rebaseAlreadyInProgress)
        #expect(error?.recoveries.isEmpty == true)
        #expect(fixture.gitFileExists("rebase-merge/orig-head"))
        await fixture.app.idle()
    }

    @Test("needs a remote and a branch")
    func preconditions() async throws {
        let fixture = try await makeSelectedRepository()

        try await runGit(["checkout", "-q", "--detach", "HEAD"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        var error = await #expect(throws: OperationError.self) { try await fixture.model.sync.pull() }
        #expect(preconditionMessage(error) != nil)

        try await runGit(["checkout", "-q", "--orphan", "fresh"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        error = await #expect(throws: OperationError.self) { try await fixture.model.sync.pull() }
        #expect(preconditionMessage(error) != nil)

        try await runGit(["checkout", "-q", "main"], fixture.local)
        try await runGit(["remote", "remove", "origin"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        error = await #expect(throws: OperationError.self) { try await fixture.model.sync.pull() }
        #expect(preconditionMessage(error) != nil)
        await fixture.app.idle()
    }

    @Test("aborting a failed pull hook is a cancellation, not an error (desktop still showed the git error)")
    func hookAborted() async throws {
        try await withWiredHooks { runtime in
            let fixture = try await makeDivergedRepository(
                remoteLine: 8,
                localLine: 1,
                responder: PromptResponder.hookFailures(.abort),
                git: runtime
            )
            try writeScript(fixture.local.path + "/.git/hooks/pre-merge-commit", "#!/bin/sh\necho 'not today' >&2\nexit 1\n")
            let tip = try await fixture.head()

            let error = await #expect(throws: OperationError.self) {
                try await fixture.model.sync.pull()
            }
            #expect(error?.reason == .cancelled(.hookAborted("pre-merge-commit")))
            #expect(error?.isCancellation == true)
            #expect(try await fixture.head() == tip)
            #expect(fixture.harness.prompts.history.count == 1)
            await fixture.model.operations.enrichmentIdle()
            await fixture.app.idle()
        }
    }
}
