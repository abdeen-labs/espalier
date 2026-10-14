// These drive `MultiCommitOperationsModel`'s rebases against real git
// (GitKitTests/Git/Rebase* has the git half): rebasing, the force-push
// warning (and the branch it examines), conflicts, continuing and
// aborting, local changes, hooks, a rebase started elsewhere, and rebases
// interrupted between commits, found at launch.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Rebase", .offline) @MainActor
struct RebaseOperationTests {
    /// `main` and `feature` (checked out), both from "Number the lines".
    /// `feature` adds feature.txt and, when `conflicting`, changes
    /// README.md's first line, as `main` does; `main` adds main.txt.
    /// `publishFeature` pushes `feature` to `origin` with tracking first.
    private func makeRepository(
        conflicting: Bool = false,
        publishFeature: Bool = false,
        responder: PromptCenter.Responder? = PromptResponder.failing(),
        git: GitRuntime? = nil
    ) async throws -> SelectedRepository {
        try await makeSelectedRepository(responder: responder, git: git) { local in
            try await commitFile(local, "README.md", numberedLines, message: "Number the lines")
            try await runGit(["push", "-q", "origin", "main"], local)
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            if conflicting {
                try await commitFile(local, "README.md", numberedLinesReplacing(1, with: "line one"), message: "Feature README")
            }
            try await commitFile(local, "feature.txt", "feature\n", message: "Feature")
            if publishFeature {
                try await runGit(["push", "-q", "-u", "origin", "feature"], local)
            }
            try await runGit(["checkout", "-q", "main"], local)
            if conflicting {
                try await commitFile(local, "README.md", numberedLinesReplacing(1, with: "line uno"), message: "Main README")
            }
            try await commitFile(local, "main.txt", "main\n", message: "Main")
            try await runGit(["checkout", "-q", "feature"], local)
        }
    }

    // MARK: Rebasing

    @Test("rebases the current branch onto a branch")
    func rebases() async throws {
        let fixture = try await makeRepository()
        let main = try fixture.branch("main")
        let operations = fixture.model.operations

        let result = try await operations.rebase(onto: main)

        #expect(result == .rebased(targetBranch: "feature", baseBranch: "main"))
        #expect(result.outcome == .completed)
        #expect(try await fixture.summaries("main..feature") == ["Feature"])
        #expect(try await fixture.sha("feature~1") == main.tip.sha)
        #expect(try await fixture.checkedOutBranch() == "feature")
        // Returns after the refresh, with nothing in progress.
        #expect(fixture.model.gitState.tip.branch?.tip.sha == (try await fixture.head()))
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        #expect(operations.undo == nil)
        #expect(fixture.model.refreshScheduler.lastPassReasons.contains(.operation(.rebase)))
        await fixture.app.idle()
    }

    @Test("rebases onto a remote branch")
    func ontoRemoteBranch() async throws {
        let fixture = try await makeRepository()
        try await runGit(["push", "-q", "origin", "main"], fixture.local)
        let remoteMain = ModelFixtures.branch("origin/main", sha: try await fixture.sha("origin/main"), type: .remote)

        let result = try await fixture.model.operations.rebase(onto: remoteMain)
        #expect(result == .rebased(targetBranch: "feature", baseBranch: "origin/main"))
        #expect(try await fixture.sha("feature~1") == remoteMain.tip.sha)
        await fixture.app.idle()
    }

    @Test("a branch that already has the base's commits is up to date")
    func upToDate() async throws {
        let fixture = try await makeRepository()
        _ = try await fixture.model.operations.rebase(onto: try fixture.branch("main"))
        let tip = try await fixture.head()

        let result = try await fixture.model.operations.rebase(onto: try fixture.branch("main"))
        #expect(result == .alreadyUpToDate(ours: "feature", theirs: "main"))
        #expect(result.outcome == .alreadyUpToDate)
        #expect(try await fixture.head() == tip)
        #expect(fixture.model.operations.current == nil)
        await fixture.app.idle()
    }

    @Test("rebasing a branch onto itself, or with no branch checked out, is refused")
    func refused() async throws {
        let fixture = try await makeRepository()
        let operations = fixture.model.operations
        let itself = await #expect(throws: OperationError.self) {
            try await operations.rebase(onto: try fixture.branch("feature"))
        }
        #expect(preconditionText(itself) != nil)

        try await runGit(["checkout", "-q", "--detach", "HEAD"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let detached = await #expect(throws: OperationError.self) {
            try await operations.rebase(onto: try fixture.branch("main"))
        }
        #expect(preconditionText(detached) != nil)
        #expect(operations.current == nil)
        await fixture.app.idle()
    }

    @Test("a base branch that's gone fails, and leaves nothing behind")
    func invalidBase() async throws {
        let fixture = try await makeRepository()
        let original = try await fixture.head()
        let gone = ModelFixtures.branch("gone", sha: String(repeating: "1", count: 40))
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.rebase(onto: gone)
        }
        #expect(error?.gitFailure != nil)
        #expect(try await fixture.head() == original)
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(fixture.model.operations.current == nil)
        #expect(!fixture.hasRebaseState())
        await fixture.app.idle()
    }

    // MARK: Rewriting published commits

    @Test("rebasing a published branch asks first, then rewrites it and recommends a force push")
    func publishedAsksFirst() async throws {
        let fixture = try await makeRepository(publishFeature: true)
        let operations = fixture.model.operations
        let main = try fixture.branch("main")
        let original = try await fixture.head()

        let error = await #expect(throws: OperationError.self) {
            try await operations.rebase(onto: main)
        }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Expected a confirmation, got \(String(describing: error))")
            return
        }
        #expect(confirmation.kind == .rewritePublishedCommits)
        #expect(try await fixture.head() == original)
        #expect(operations.forcePushState == .notAvailable)

        let result = try await operations.rebase(onto: main, confirmed: [.rewritePublishedCommits])
        #expect(result == .rebased(targetBranch: "feature", baseBranch: "main"))
        // Diverged from its upstream, rewritten by Espalier: force push.
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 2, behind: 1))
        #expect(operations.rewrittenBranches["feature"] == (try await fixture.sha("feature@{upstream}")))
        #expect(operations.forcePushState == .recommended)
        await fixture.app.idle()
    }

    @Test("doesn't ask when the setting is off")
    func publishedWithoutSetting() async throws {
        let fixture = try await makeRepository(publishFeature: true)
        fixture.app.preferences.confirmForcePush = false
        let result = try await fixture.model.operations.rebase(onto: try fixture.branch("main"))
        #expect(result == .rebased(targetBranch: "feature", baseBranch: "main"))
        await fixture.app.idle()
    }

    @Test("examines the branch being rebased, not the base branch (desktop's check asked here)")
    func examinesTheRebasedBranch() async throws {
        // main is published and has a commit feature lacks; feature isn't
        // published, so no commit of the rebase was pushed.
        let fixture = try await makeRepository()
        try await runGit(["push", "-q", "origin", "main"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)

        let result = try await fixture.model.operations.rebase(onto: try fixture.branch("main"))
        #expect(result == .rebased(targetBranch: "feature", baseBranch: "main"))
        #expect(fixture.model.operations.forcePushState == .notAvailable)
        await fixture.app.idle()
    }

    // MARK: Conflicts

    @Test("conflicts stop the rebase; continuing with the chosen sides finishes it")
    func conflictsThenContinue() async throws {
        let fixture = try await makeRepository(conflicting: true, publishFeature: true)
        let operations = fixture.model.operations
        let main = try fixture.branch("main")
        let original = try await fixture.head()

        let outcome = try await operations.rebase(onto: main, confirmed: [.rewritePublishedCommits])
        #expect(outcome == .conflicted)
        #expect(outcome.outcome == .conflicted)
        #expect(outcome.summary == nil)
        let current = try #require(operations.current)
        #expect(current.kind == .rebase)
        #expect(current.origin == .espalier)
        #expect(current.phase == .conflicted)
        #expect(current.originalBranchTip == original)
        #expect(current.targetBranch?.name == "feature")
        guard case .rebase(let source, let commits, _) = current.detail else {
            Issue.record("Unexpected detail \(current.detail)")
            return
        }
        #expect(source?.name == "main")
        #expect(commits.map(\.summary) == ["Feature README", "Feature"])
        guard case .rebase(_, "feature", nil, original, main.tip.sha, [:])? = operations.conflictState else {
            Issue.record("Unexpected conflict state \(String(describing: operations.conflictState))")
            return
        }
        #expect(operations.conflictBranches == ConflictBranches(ours: "main", theirs: "feature"))
        #expect(operations.unresolvedFiles.map(\.path) == ["README.md"])
        #expect(!operations.canContinue)
        #expect(fixture.model.gitState.inProgress == .rebase(RebaseInternalState(targetBranch: "feature", baseBranchTip: main.tip.sha, originalBranchTip: original)))

        // Another operation can't start meanwhile.
        let blocked = await #expect(throws: OperationError.self) {
            try await operations.merge(main)
        }
        #expect(blocked?.reason == .precondition(current.conflictsMessage))

        operations.setManualResolution(.theirs, forPath: "README.md")
        #expect(operations.canContinue)
        let continued = try await operations.continueOperation()
        #expect(continued == .multiCommit(.rebased(targetBranch: "feature", baseBranch: "main")))
        #expect(try fixture.read("README.md") == numberedLinesReplacing(1, with: "line one"))
        #expect(try await fixture.summaries("main..feature") == ["Feature", "Feature README"])
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        #expect(!fixture.hasRebaseState())
        #expect(operations.forcePushState == .recommended)
        // Continuing selects the new tip in history.
        #expect(fixture.model.history.selection.shas == [try await fixture.head()])
        await fixture.app.idle()
    }

    @Test("a collaborator's push fetched while the rebase waits on its conflicts: no force push is recommended afterwards")
    func remoteMovedDuringRebase() async throws {
        let fixture = try await makeRepository(conflicting: true, publishFeature: true)
        let operations = fixture.model.operations
        let published = try await fixture.sha("origin/feature")
        #expect(try await operations.rebase(onto: try fixture.branch("main"), confirmed: [.rewritePublishedCommits]) == .conflicted)

        // A collaborator pushes to feature, and a fetch brings it in.
        let other = try await cloneRepository(fixture.remote)
        try await runGit(["checkout", "-q", "feature"], other)
        try await commitFile(other, "theirs.txt", "theirs\n")
        try await runGit(["push", "-q", "origin", "feature"], other)
        try await runGit(["fetch", "-q"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)

        operations.setManualResolution(.theirs, forPath: "README.md")
        _ = try await operations.continueOperation()

        let aheadBehind = try #require(fixture.model.gitState.aheadBehind)
        #expect(aheadBehind.ahead > 0 && aheadBehind.behind > 0)
        #expect(operations.rewrittenBranches == ["feature": published])
        #expect(operations.forcePushState == .available)
        if case .pull = fixture.model.sync.action {} else {
            Issue.record("Unexpected action \(fixture.model.sync.action)")
        }
        // The next load of the branches forgets the rewrite.
        await fixture.model.refresh(.full, reason: .user)
        #expect(operations.rewrittenBranches.isEmpty)
        await fixture.app.idle()
    }

    @Test("rebases desktop's rebase builder, its two conflicted files resolved with a side each")
    func desktopBuilder() async throws {
        let local = try await createRebaseTestRepository("base-branch", "feature-branch")
        try await runGit(["checkout", "-q", "feature-branch"], local)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        let operations = model.operations
        let base = try #require(model.gitState.branches.all.first { $0.name == "base-branch" })

        #expect(try await operations.rebase(onto: base) == .conflicted)
        #expect(Set(operations.unresolvedFiles.map(\.path)) == ["OTHER.md", "THING.md"])
        // During a rebase "ours" is the base and "theirs" the commit replayed.
        operations.setManualResolution(.ours, forPath: "OTHER.md")
        operations.setManualResolution(.theirs, forPath: "THING.md")
        #expect(try await operations.continueOperation() == .multiCommit(.rebased(targetBranch: "feature-branch", baseBranch: "base-branch")))
        let read = { (name: String) in try String(contentsOfFile: POSIXPath.join(local.path, name), encoding: .utf8) }
        #expect(try read("OTHER.md") == "# HELLO WORLD! \nTHINGS GO HERE\nALSO BASE BRANCH UNDERWAY\n")
        #expect(try read("THING.md") == "# HELLO WORLD! \nTHINGS GO HERE\nFEATURE BRANCH UNDERWAY\n")
        #expect(try await getRefOrError(local, "feature-branch~1").sha == base.tip.sha)
        #expect(operations.current == nil)
        await app.idle()
    }

    @Test("aborting a conflicted rebase puts the branch back; after resolving, it asks first")
    func abort() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        let original = try await fixture.head()
        #expect(try await operations.rebase(onto: try fixture.branch("main")) == .conflicted)

        operations.setManualResolution(.ours, forPath: "README.md")
        let ask = await #expect(throws: OperationError.self) {
            try await operations.abortOperation()
        }
        #expect(ask?.reason == .confirmationRequired(.abortWithResolvedConflicts(operation: "Rebase")))
        #expect(ask?.operation == .abortRebase)

        try await operations.abortOperation(confirmed: [.abortWithResolvedConflicts])
        #expect(try await fixture.head() == original)
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(!fixture.hasRebaseState())
        #expect(operations.current == nil)
        #expect(operations.conflictState == nil)
        #expect(fixture.model.gitState.inProgress == nil)
        await fixture.app.idle()
    }

    @Test("continuing is refused while a conflict is unresolved, and stages nothing")
    func continueRefused() async throws {
        let fixture = try await makeRepository(conflicting: true)
        let operations = fixture.model.operations
        #expect(try await operations.rebase(onto: try fixture.branch("main")) == .conflicted)

        let error = await #expect(throws: OperationError.self) {
            try await operations.continueOperation()
        }
        #expect(preconditionText(error) != nil)
        #expect(error?.operation == .continueRebase)
        #expect(operations.current?.phase == .conflicted)
        #expect(fixture.gitFileExists("REBASE_HEAD"))
        await fixture.app.idle()
    }

    // MARK: Local changes

    @Test("local changes refuse the rebase with Stash Changes and Continue")
    func localChanges() async throws {
        let fixture = try await makeRepository()
        try fixture.write("feature.txt", "changed\n")
        // Staged changes too.
        try await runGit(["add", "feature.txt"], fixture.local)
        await fixture.model.refresh(.status, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.operations.rebase(onto: try fixture.branch("main"))
        }
        #expect(error?.reason == .localChangesOverwritten(files: []))
        #expect(error?.retry?.kind == .rebase)
        #expect(fixture.model.operations.current == nil)

        let recovery = try #require(error?.recoveries.first)
        #expect(recovery.kind == .stashChangesAndRetry)
        try await recovery.perform(in: fixture.app)
        await fixture.model.idle()
        #expect(try await fixture.summaries("main..feature") == ["Feature"])
        #expect(try await fixture.sha("feature~1") == (try await fixture.sha("main")))
        #expect(try await fixture.stashList() == ["On feature: !!Espalier<feature>"])
        await fixture.app.idle()
    }

    @Test("with rebase.autoStash, git stashes local changes, rebases, and puts them back, as in desktop")
    func autoStash() async throws {
        try await withIsolatedGitConfig { config in
            try Data("[rebase]\n\tautoStash = true\n".utf8).write(to: URL(filePath: config))
            let fixture = try await makeRepository()
            // An unstaged change and a staged one.
            try fixture.write("feature.txt", "changed\n")
            try fixture.write("README.md", numberedLinesReplacing(8, with: "line eight"))
            try await runGit(["add", "README.md"], fixture.local)
            await fixture.model.refresh(.status, reason: .user)

            #expect(try await fixture.model.operations.rebase(onto: try fixture.branch("main")) == .rebased(targetBranch: "feature", baseBranch: "main"))
            #expect(try await fixture.summaries("main..feature") == ["Feature"])
            #expect(try await fixture.sha("feature~1") == (try await fixture.sha("main")))
            // The changes are back, and git's stash is gone.
            #expect(try fixture.read("feature.txt") == "changed\n")
            #expect(try fixture.read("README.md") == numberedLinesReplacing(8, with: "line eight"))
            #expect(try await fixture.stashList().isEmpty)
            #expect(Set(fixture.model.changes.workingDirectory.files.map(\.path)) == ["README.md", "feature.txt"])
            #expect(fixture.model.operations.current == nil)

            // With it off (in the repository), the changes refuse it again.
            try await runGit(["config", "rebase.autoStash", "false"], fixture.local)
            try await runGit(["reset", "-q", "--hard", "HEAD~1"], fixture.local)
            try fixture.write("README.md", "changed again\n")
            await fixture.model.refresh(reason: .user)
            let error = await #expect(throws: OperationError.self) {
                try await fixture.model.operations.rebase(onto: try fixture.branch("main"))
            }
            #expect(error?.reason == .localChangesOverwritten(files: []))
            await fixture.app.idle()
        }
    }

    @Test("untracked files don't stop a rebase they're not in the way of")
    func untrackedFiles() async throws {
        let fixture = try await makeRepository()
        try fixture.write("scratch.txt", "scratch\n")
        await fixture.model.refresh(.status, reason: .user)
        #expect(try await fixture.model.operations.rebase(onto: try fixture.branch("main")) == .rebased(targetBranch: "feature", baseBranch: "main"))
        #expect(try fixture.read("scratch.txt") == "scratch\n")
        await fixture.app.idle()
    }

    // MARK: Rebases started elsewhere

    @Test("takes over a rebase started elsewhere and finishes it, recommending a force push")
    func externalRebase() async throws {
        let fixture = try await makeRepository(conflicting: true, publishFeature: true)
        let original = try await fixture.head()
        #expect(try await runGitAllowingFailure(["rebase", "main"], fixture.local) != 0)
        await fixture.refreshAll()
        let operations = fixture.model.operations

        let current = try #require(operations.current)
        #expect(current.origin == .rebuilt)
        #expect(current.kind == .rebase)
        #expect(current.phase == .conflicted)
        #expect(current.originalBranchTip == original)
        #expect(current.targetBranch?.name == "feature")

        try fixture.write("README.md", numberedLinesReplacing(1, with: "line one and uno"))
        await fixture.model.refresh(.status, reason: .fileSystem)
        #expect(operations.canContinue)
        #expect(try await operations.continueOperation() == .multiCommit(.rebased(targetBranch: "feature", baseBranch: nil)))
        #expect(try fixture.read("README.md") == numberedLinesReplacing(1, with: "line one and uno"))
        #expect(try await fixture.summaries("main..feature") == ["Feature", "Feature README"])
        // orig-head is a SHA, so the branch counts as rewritten.
        #expect(operations.forcePushState == .recommended)
        #expect(operations.undo == nil)
        await fixture.app.idle()
    }

    @Test("a rebase interrupted between commits is found at launch, and continues")
    func interruptedAtLaunchContinues() async throws {
        let fixture = try await makeRepository()
        try await commitFile(fixture.local, "feature-2.txt", "two\n", message: "Feature two")
        let original = try await fixture.head()
        let main = try await fixture.sha("main")
        try await interruptRebase(of: "feature", onto: "main", in: fixture.local)
        #expect(!fixture.gitFileExists("REBASE_HEAD"))
        #expect(try await fixture.checkedOutBranch() == nil)

        let relaunched = await fixture.harness.loadedApp()
        await relaunched.idle()
        let model = try #require(relaunched.repository(fixture.model.id))
        await model.operations.enrichmentIdle()
        let operations = model.operations

        let current = try #require(operations.current)
        #expect(current.phase == .interrupted)
        #expect(current.origin == .rebuilt)
        #expect(current.kind == .rebase)
        #expect(current.originalBranchTip == original)
        #expect(current.targetBranch?.name == "feature")
        #expect(operations.conflictState == nil)
        #expect(operations.canContinue)
        #expect(model.gitState.inProgress == .rebase(RebaseInternalState(targetBranch: "feature", baseBranchTip: main, originalBranchTip: original)))
        // Nothing else starts meanwhile.
        let blocked = await #expect(throws: OperationError.self) {
            try await operations.merge(try #require(model.gitState.branches.all.first { $0.name == "main" }))
        }
        #expect(blocked?.reason == .precondition(current.interruptedMessage))

        #expect(try await operations.continueOperation() == .multiCommit(.rebased(targetBranch: "feature", baseBranch: nil)))
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(try await fixture.summaries("main..feature") == ["Feature two", "Feature"])
        #expect(!fixture.hasRebaseState())
        #expect(operations.current == nil)
        #expect(model.gitState.inProgress == nil)
        await relaunched.idle()
    }

    @Test("a rebase interrupted between commits can be aborted, putting the branch back")
    func interruptedAborts() async throws {
        let fixture = try await makeRepository()
        try await commitFile(fixture.local, "feature-2.txt", "two\n", message: "Feature two")
        let original = try await fixture.head()
        try await interruptRebase(of: "feature", onto: "main", in: fixture.local)
        await fixture.refreshAll()
        let operations = fixture.model.operations
        #expect(operations.current?.phase == .interrupted)

        // Nothing was resolved: no confirmation.
        try await operations.abortOperation()
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(try await fixture.head() == original)
        #expect(!fixture.hasRebaseState())
        #expect(operations.current == nil)
        await fixture.app.idle()
    }

    @Test("an interrupted rebase that continues into conflicts waits on them, then finishes")
    func interruptedThenConflicts() async throws {
        let fixture = try await makeRepository()
        // feature's second commit conflicts with main's.
        try await commitFile(fixture.local, "README.md", numberedLinesReplacing(1, with: "line one"), message: "Feature README")
        try await runGit(["checkout", "-q", "main"], fixture.local)
        try await commitFile(fixture.local, "README.md", numberedLinesReplacing(1, with: "line uno"), message: "Main README")
        try await runGit(["checkout", "-q", "feature"], fixture.local)
        try await interruptRebase(of: "feature", onto: "main", in: fixture.local)
        await fixture.refreshAll()
        let operations = fixture.model.operations
        #expect(operations.current?.phase == .interrupted)

        #expect(try await operations.continueOperation() == .multiCommit(.conflicted))
        let current = try #require(operations.current)
        #expect(current.phase == .conflicted)
        #expect(current.origin == .rebuilt)
        #expect(current.targetBranch?.name == "feature")
        #expect(operations.unresolvedFiles.map(\.path) == ["README.md"])
        // Continuing an interruption resolved nothing: aborting doesn't ask.
        #expect(current.userHasResolvedConflicts == false)

        operations.setManualResolution(.theirs, forPath: "README.md")
        #expect(try await operations.continueOperation() == .multiCommit(.rebased(targetBranch: "feature", baseBranch: nil)))
        #expect(try fixture.read("README.md") == numberedLinesReplacing(1, with: "line one"))
        #expect(try await fixture.summaries("main..feature") == ["Feature README", "Feature"])
        #expect(operations.current == nil)
        await fixture.app.idle()
    }

    @Test("in a linked worktree, a rebase interrupted between commits is found in its git directory")
    func interruptedInLinkedWorktree() async throws {
        let fixture = try await makeRepository()
        try await commitFile(fixture.local, "feature-2.txt", "two\n", message: "Feature two")
        // feature moves to a linked worktree.
        try await runGit(["checkout", "-q", "main"], fixture.local)
        let worktreePath = POSIXPath.join(try createTempDirectory(), "linked")
        try await runGit(["worktree", "add", "-q", worktreePath, "feature"], fixture.local)
        let linked = Repository(path: worktreePath)
        try await interruptRebase(of: "feature", onto: "main", in: linked)

        let model = try await fixture.harness.addAndSelect(linked, to: fixture.app)
        await model.operations.enrichmentIdle()
        let gitDir = try #require(model.record.gitDir)
        #expect(FileManager.default.fileExists(atPath: POSIXPath.join(gitDir, "rebase-merge")))
        #expect(!fixture.hasRebaseState())
        #expect(model.operations.current?.phase == .interrupted)
        #expect(model.operations.current?.targetBranch?.name == "feature")
        // The main worktree has nothing in progress.
        await fixture.refreshAll()
        #expect(fixture.model.operations.current == nil)

        #expect(try await model.operations.continueOperation() == .multiCommit(.rebased(targetBranch: "feature", baseBranch: nil)))
        #expect(try await currentBranchName(linked) == "feature")
        #expect(try await fixture.summaries("main..feature") == ["Feature two", "Feature"])
        #expect(model.operations.current == nil)
        await fixture.app.idle()
    }

    // MARK: Rebases interrupted while finishing

    /// `makeRepository()` with a second commit on `feature`, rebased onto
    /// `main` by git killed while finishing: `feature` is at the rebased
    /// commits with HEAD on it, and `rebase-merge` is still there. Then a
    /// `post-rewrite` hook that records its runs.
    private func makeRebaseInterruptedWhileFinishing() async throws -> (fixture: SelectedRepository, original: String, rebased: String) {
        let fixture = try await makeRepository()
        try await commitFile(fixture.local, "feature-2.txt", "two\n", message: "Feature two")
        let original = try await fixture.head()
        try await killRebaseWhileFinishing(["rebase", "main", "feature"], in: fixture.local)
        try writeScript(fixture.local.path + "/.git/hooks/post-rewrite", """
            #!/bin/sh
            echo "post-rewrite $*" >> '\(fixture.local.path)/.git/post-rewrite.log'
            cat >> '\(fixture.local.path)/.git/post-rewrite.log'
            """)
        let rebased = try await fixture.head()
        return (fixture, original, rebased)
    }

    @Test("a rebase interrupted while finishing, with HEAD back on its branch, is found, and continuing finishes it as git would")
    func interruptedWhileFinishingContinues() async throws {
        let (fixture, original, rebased) = try await makeRebaseInterruptedWhileFinishing()
        let main = try await fixture.sha("main")
        // git moved the branch and put HEAD back on it; its own continue
        // can't finish.
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(rebased != original)
        #expect(try await fixture.sha("HEAD~2") == main)
        #expect(fixture.gitFileExists("rebase-merge"))
        #expect(!fixture.gitFileExists("REBASE_HEAD"))
        let refused = try await Dugite.exec(["rebase", "--continue"], fixture.local.path)
        #expect(refused.exitCode != 0)
        #expect(String(decoding: refused.stderr, as: UTF8.self).contains("could not update refs/heads/feature"))

        await fixture.refreshAll()
        let operations = fixture.model.operations
        let current = try #require(operations.current)
        #expect(current.phase == .interrupted)
        #expect(current.origin == .rebuilt)
        #expect(current.kind == .rebase)
        #expect(current.originalBranchTip == original)
        #expect(current.targetBranch?.name == "feature")
        #expect(operations.canContinue)
        #expect(fixture.model.gitState.inProgress == .rebase(RebaseInternalState(targetBranch: "feature", baseBranchTip: main, originalBranchTip: original)))
        #expect(fixture.model.gitState.tip.branch?.name == "feature")

        #expect(try await operations.continueOperation() == .multiCommit(.rebased(targetBranch: "feature", baseBranch: nil)))
        #expect(try await fixture.checkedOutBranch() == "feature")
        // The rebased commits, as git made them.
        #expect(try await fixture.head() == rebased)
        #expect(try await fixture.summaries("main..feature") == ["Feature two", "Feature"])
        #expect(!fixture.hasRebaseState())
        // git finished as it does: the post-rewrite hook ran, with the
        // commits it rewrote.
        let log = try String(contentsOfFile: fixture.local.path + "/.git/post-rewrite.log", encoding: .utf8)
        #expect(log.hasPrefix("post-rewrite rebase\n"))
        #expect(log.split(separator: "\n").count == 3)
        #expect(log.contains(" \(rebased)\n"))
        #expect(operations.current == nil)
        #expect(fixture.model.gitState.inProgress == nil)
        await fixture.app.idle()
    }

    @Test("a rebase interrupted while finishing can be aborted, putting the branch back")
    func interruptedWhileFinishingAborts() async throws {
        let (fixture, original, _) = try await makeRebaseInterruptedWhileFinishing()
        await fixture.refreshAll()
        let operations = fixture.model.operations
        #expect(operations.current?.phase == .interrupted)

        try await operations.abortOperation()
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(try await fixture.head() == original)
        #expect(!fixture.hasRebaseState())
        #expect(operations.current == nil)
        await fixture.app.idle()
    }

    @Test("with rebase.autoStash, a rebase interrupted while finishing puts the stashed changes back when continued")
    func interruptedWhileFinishingAutoStash() async throws {
        try await withIsolatedGitConfig { config in
            try Data("[rebase]\n\tautoStash = true\n".utf8).write(to: URL(filePath: config))
            let fixture = try await makeRepository()
            try fixture.write("feature.txt", "changed\n")
            try await killRebaseWhileFinishing(["rebase", "main", "feature"], in: fixture.local)
            // git stashed the change and hadn't put it back yet.
            #expect(try fixture.read("feature.txt") == "feature\n")
            await fixture.refreshAll()
            let operations = fixture.model.operations
            #expect(operations.current?.phase == .interrupted)

            #expect(try await operations.continueOperation() == .multiCommit(.rebased(targetBranch: "feature", baseBranch: nil)))
            #expect(try fixture.read("feature.txt") == "changed\n")
            #expect(try await fixture.stashList().isEmpty)
            #expect(try await fixture.summaries("main..feature") == ["Feature"])
            #expect(try await fixture.checkedOutBranch() == "feature")
            #expect(!fixture.hasRebaseState())
            await fixture.app.idle()
        }
    }

    @Test("a rebase whose last commit conflicted, interrupted while finishing after continuing, finishes when continued")
    func interruptedWhileFinishingAfterConflicts() async throws {
        let fixture = try await makeRepository()
        // feature's last commit conflicts with main's.
        try await commitFile(fixture.local, "README.md", numberedLinesReplacing(1, with: "line one"), message: "Feature README")
        try await runGit(["checkout", "-q", "main"], fixture.local)
        try await commitFile(fixture.local, "README.md", numberedLinesReplacing(1, with: "line uno"), message: "Main README")
        try await runGit(["checkout", "-q", "feature"], fixture.local)
        #expect(try await runGitAllowingFailure(["rebase", "main"], fixture.local) != 0)
        try fixture.write("README.md", numberedLinesReplacing(1, with: "line one and uno"))
        try await runGit(["add", "README.md"], fixture.local)
        try await killRebaseWhileFinishing(["rebase", "--continue"], in: fixture.local, environment: ["GIT_EDITOR": ":"])
        // git leaves REBASE_HEAD behind, so the status sees the rebase.
        #expect(fixture.gitFileExists("REBASE_HEAD"))
        #expect(try await fixture.checkedOutBranch() == "feature")
        let rebased = try await fixture.head()

        await fixture.refreshAll()
        let operations = fixture.model.operations
        #expect(operations.current?.kind == .rebase)
        #expect(operations.unresolvedFiles.isEmpty)
        #expect(operations.canContinue)

        #expect(try await operations.continueOperation() == .multiCommit(.rebased(targetBranch: "feature", baseBranch: nil)))
        #expect(try await fixture.head() == rebased)
        #expect(try await fixture.summaries("main..feature") == ["Feature README", "Feature"])
        #expect(try fixture.read("README.md") == numberedLinesReplacing(1, with: "line one and uno"))
        #expect(try await fixture.checkedOutBranch() == "feature")
        // git leaves REBASE_HEAD behind when the last commit conflicted, as
        // it does when nothing interrupts it; without its state directory,
        // it's no rebase.
        #expect(!fixture.hasRebaseState())
        #expect(operations.current == nil)
        #expect(fixture.model.gitState.inProgress == nil)
        await fixture.app.idle()
    }

    @Test("killed again after detaching HEAD to finish, the rebase is found on the detached HEAD and finishes")
    func interruptedWhileFinishingDetached() async throws {
        let (fixture, original, rebased) = try await makeRebaseInterruptedWhileFinishing()
        // The first of the two steps that put back where git finishes from.
        try await runGit(["update-ref", "--no-deref", "HEAD", rebased], fixture.local)
        #expect(try await fixture.checkedOutBranch() == nil)
        #expect(try await fixture.sha("feature") == rebased)

        await fixture.refreshAll()
        let operations = fixture.model.operations
        #expect(operations.current?.phase == .interrupted)
        #expect(operations.current?.originalBranchTip == original)

        #expect(try await operations.continueOperation() == .multiCommit(.rebased(targetBranch: "feature", baseBranch: nil)))
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(try await fixture.head() == rebased)
        #expect(!fixture.hasRebaseState())
        await fixture.app.idle()
    }

    @Test("continuing leaves the rebase's branch alone while HEAD is on another branch")
    func interruptedWhileFinishingOtherBranch() async throws {
        let (fixture, _, rebased) = try await makeRebaseInterruptedWhileFinishing()
        try await runGit(["checkout", "-q", "main"], fixture.local)
        let main = try await fixture.sha("main")
        await fixture.refreshAll()
        let operations = fixture.model.operations
        #expect(operations.current?.phase == .interrupted)

        // git's continue refuses to move feature, which isn't where it
        // started.
        await #expect(throws: OperationError.self) {
            try await operations.continueOperation()
        }
        #expect(try await fixture.sha("feature") == rebased)
        #expect(try await fixture.checkedOutBranch() == "main")
        #expect(try await fixture.sha("main") == main)
        #expect(fixture.hasRebaseState())
        #expect(operations.current?.phase == .interrupted)
        await fixture.app.idle()
    }

    // MARK: Hooks

    @Test("a failing pre-rebase hook asks first; Abort cancels the rebase, which changes nothing")
    func preRebaseHookAborted() async throws {
        try await withIsolatedGitConfig { _ in
            try await withHooksRuntime { runtime in
                let fixture = try await makeRepository(responder: PromptResponder.hookFailures(.abort), git: runtime)
                try writeScript(fixture.local.path + "/.git/hooks/pre-rebase", "#!/bin/sh\necho 'not on a Friday' >&2\nexit 1\n")
                let original = try await fixture.head()

                let error = await #expect(throws: OperationError.self) {
                    try await fixture.model.operations.rebase(onto: try fixture.branch("main"))
                }
                #expect(error?.reason == .cancelled(.hookAborted("pre-rebase")))
                #expect(error?.isCancellation == true)
                #expect(try await fixture.head() == original)
                #expect(!fixture.hasRebaseState())
                #expect(fixture.model.operations.current == nil)
                guard case .hookFailed(let name, let output)? = fixture.harness.prompts.history.first else {
                    Issue.record("No hook prompt: \(fixture.harness.prompts.history)")
                    return
                }
                #expect(name == "pre-rebase")
                #expect(output.contains("not on a Friday"))
                await fixture.app.idle()
            }
        }
    }

    @Test("a hook failing halfway through: Abort puts the branch back; Ignore finishes")
    func midRebaseHook() async throws {
        try await withIsolatedGitConfig { _ in
            try await withHooksRuntime { runtime in
                let answers = Mutex([HookFailureResolution.abort, .ignore])
                let responder: PromptCenter.Responder = { prompt in
                    guard case .hookFailed = prompt else {
                        Issue.record("Unexpected prompt \(prompt)")
                        return prompt.cancelledAnswer
                    }
                    return .hookFailure(answers.withLock { $0.removeFirst() })
                }
                let fixture = try await makeRepository(responder: responder, git: runtime)
                try await commitFile(fixture.local, "feature-2.txt", "two\n", message: "Feature two")
                await fixture.model.refresh(.full, reason: .user)
                // Fails for the second commit only.
                try writeScript(fixture.local.path + "/.git/hooks/prepare-commit-msg", """
                    #!/bin/sh
                    if grep -q 'Feature two' "$1"; then echo 'lint failed' >&2; exit 1; fi
                    exit 0
                    """)
                let original = try await fixture.head()

                let error = await #expect(throws: OperationError.self) {
                    try await fixture.model.operations.rebase(onto: try fixture.branch("main"))
                }
                #expect(error?.reason == .cancelled(.hookAborted("prepare-commit-msg")))
                #expect(try await fixture.head() == original)
                #expect(try await fixture.checkedOutBranch() == "feature")
                #expect(!fixture.hasRebaseState())
                #expect(fixture.model.operations.current == nil)

                #expect(try await fixture.model.operations.rebase(onto: try fixture.branch("main")) == .rebased(targetBranch: "feature", baseBranch: "main"))
                #expect(try await fixture.summaries("main..feature") == ["Feature two", "Feature"])
                await fixture.app.idle()
            }
        }
    }

    // MARK: Preview

    @Test("previews the commits a rebase applies and the ones it brings in")
    func preview() async throws {
        let fixture = try await makeRepository()
        let preview = await fixture.model.operations.rebasePreview(onto: try fixture.branch("main"))
        guard case .clean(let ahead, let behind) = preview else {
            Issue.record("Unexpected preview \(preview)")
            return
        }
        #expect(ahead.map(\.summary) == ["Feature"])
        #expect(behind.map(\.summary) == ["Main"])
        let invalid = await fixture.model.operations.rebasePreview(onto: ModelFixtures.branch("gone", sha: String(repeating: "1", count: 40)))
        #expect(invalid == .invalid)
        await fixture.app.idle()
    }
}
