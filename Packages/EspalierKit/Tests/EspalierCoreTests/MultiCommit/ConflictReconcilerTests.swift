// These drive the conflict reducer (`operations.reconcile`) through status
// passes over real git: operations rebuilt after a relaunch or a command
// run elsewhere, a pull's conflicts, operations ending outside Espalier,
// manual resolutions across passes, and conflicts resolved outside
// Espalier. Plus the hooks operations plug into `continueOperation` and
// `abortOperation`.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Conflict reconciler", .offline) @MainActor
struct ConflictReconcilerTests {
    /// `main` (checked out) and `feature`, which both change README.md's
    /// first line; `feature` also adds feature.txt.
    private func makeConflictingRepository() async throws -> SelectedRepository {
        try await makeSelectedRepository { local in
            try await commitFile(local, "README.md", numberedLines, message: "Number the lines")
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "README.md", numberedLinesReplacing(1, with: "line one"), message: "One")
            try await commitFile(local, "feature.txt", "feature\n", message: "Feature")
            try await runGit(["checkout", "-q", "main"], local)
            try await commitFile(local, "README.md", numberedLinesReplacing(1, with: "line uno"), message: "Uno")
        }
    }

    /// Adds `repository` to a new app and selects it.
    private func select(_ repository: Repository) async throws -> (AppHarness, AppModel, RepositoryModel) {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(repository, to: app)
        await model.operations.enrichmentIdle()
        return (harness, app, model)
    }

    @Test("rebuilds a merge Espalier didn't start, and finds the branch it merges")
    func rebuildsMerge() async throws {
        // 'other-branch' merging 'master', conflicting in foo.
        let repository = try await setupConflictedRepo()
        let (_, app, model) = try await select(repository)
        let operations = model.operations

        let current = try #require(operations.current)
        let master = try #require(model.gitState.branches.all.first { $0.name == "master" })
        #expect(current.kind == .merge)
        #expect(current.origin == .rebuilt)
        #expect(current.phase == .conflicted)
        #expect(current.targetBranch?.name == "other-branch")
        #expect(current.detail == .merge(sourceBranch: master, isSquash: false))
        #expect(operations.conflictBranches == ConflictBranches(ours: "other-branch", theirs: "master"))
        #expect(operations.unresolvedFiles.map(\.path) == ["foo"])

        // It can be finished like one Espalier started.
        operations.setManualResolution(.theirs, forPath: "foo")
        #expect(try await operations.continueOperation() == .merge(.merged(ours: "other-branch", theirs: "master")))
        #expect(try await getTipOrError(repository).parentSHAs.count == 2)
        #expect(operations.current == nil)
        await app.idle()
    }

    @Test("an operation stopped on conflicts is rebuilt after a relaunch")
    func rebuiltAfterRelaunch() async throws {
        let fixture = try await makeConflictingRepository()
        let feature = try fixture.branch("feature")
        #expect(try await fixture.model.operations.merge(feature) == .conflicted)
        fixture.model.operations.setManualResolution(.theirs, forPath: "README.md")
        await fixture.app.idle()

        let relaunched = await fixture.harness.loadedApp()
        await relaunched.idle()
        let model = try #require(relaunched.repository(fixture.model.id))
        await model.operations.enrichmentIdle()
        let operations = model.operations

        let current = try #require(operations.current)
        #expect(current.origin == .rebuilt)
        #expect(current.kind == .merge)
        #expect(current.phase == .conflicted)
        #expect(current.detail == .merge(sourceBranch: feature, isSquash: false))
        #expect(current.targetBranch?.name == "main")
        // Choices made before quitting are lost, as all in-memory state is.
        #expect(operations.conflictState?.manualResolutions == [:])

        try await operations.abortOperation()
        #expect(operations.current == nil)
        #expect(!fixture.gitFileExists("MERGE_HEAD"))
        await relaunched.idle()
    }

    @Test("rebuilds a squash merge started elsewhere, which aborts as one")
    func rebuildsSquashMerge() async throws {
        let fixture = try await makeConflictingRepository()
        let tip = try await fixture.head()
        #expect(try await runGitAllowingFailure(["merge", "--squash", "feature"], fixture.local) != 0)
        await fixture.model.refresh(.full, reason: .user)

        let current = try #require(fixture.model.operations.current)
        #expect(current.origin == .rebuilt)
        #expect(current.isSquashMerge)
        // No MERGE_HEAD to find the branch with.
        await fixture.model.operations.enrichmentIdle()
        #expect(fixture.model.operations.conflictBranches == ConflictBranches(ours: "main", theirs: nil))

        try await fixture.model.operations.abortOperation()
        #expect(try await fixture.head() == tip)
        #expect(!fixture.gitFileExists("SQUASH_MSG"))
        #expect(fixture.model.operations.current == nil)
        await fixture.app.idle()
    }

    @Test("a pull's merge conflicts name the upstream it merged")
    func pullConflicts() async throws {
        let fixture = try await makeConflictingRepository()
        try await runGit(["push", "-q", "origin", "main"], fixture.local)
        try await pushCommitFromAnotherClone(fixture.remote, path: "README.md", contents: numberedLinesReplacing(1, with: "line from the remote"))
        try await commitFile(fixture.local, "README.md", numberedLinesReplacing(1, with: "line from here"), message: "Here")
        #expect(try await runGitAllowingFailure(["pull", "--no-rebase", "origin", "main"], fixture.local) != 0)
        await fixture.model.refresh(.full, reason: .user)
        await fixture.model.operations.enrichmentIdle()

        let current = try #require(fixture.model.operations.current)
        #expect(current.origin == .rebuilt)
        guard case .merge(let source?, false) = current.detail else {
            Issue.record("Unexpected detail \(current.detail)")
            return
        }
        #expect(source.name == "origin/main")
        #expect(source.type == .remote)
        #expect(fixture.model.operations.conflictBranches == ConflictBranches(ours: "main", theirs: "origin/main"))
        await fixture.app.idle()
    }

    @Test("rebuilds a rebase started elsewhere, with its commits")
    func rebuildsRebase() async throws {
        let repository = try await createRebaseTestRepository("base-branch", "feature-branch")
        try await runGit(["checkout", "-q", "feature-branch"], repository)
        let original = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
        #expect(try await runGitAllowingFailure(["rebase", "base-branch"], repository) != 0)
        let (_, app, model) = try await select(repository)

        let current = try #require(model.operations.current)
        #expect(current.kind == .rebase)
        #expect(current.origin == .rebuilt)
        #expect(current.targetBranch?.name == "feature-branch")
        #expect(current.originalBranchTip == original)
        guard case .rebase(nil, let commits, _) = current.detail else {
            Issue.record("Unexpected detail \(current.detail)")
            return
        }
        #expect(commits.map(\.summary) == ["Feature Branch!"])
        #expect(model.operations.conflictBranches == ConflictBranches(ours: nil, theirs: "feature-branch"))
        #expect(model.gitState.inProgress.map { if case .rebase = $0 { true } else { false } } == true)
        await app.idle()
    }

    @Test("rebuilds a cherry-pick started elsewhere, with its commits")
    func rebuildsCherryPick() async throws {
        let fixture = try await makeConflictingRepository()
        let featureOne = JSCompat.trim(try await runGit(["rev-parse", "feature~1"], fixture.local))
        #expect(try await runGitAllowingFailure(["cherry-pick", featureOne], fixture.local) != 0)
        await fixture.model.refresh(.full, reason: .user)
        await fixture.model.operations.enrichmentIdle()

        let current = try #require(fixture.model.operations.current)
        #expect(current.kind == .cherryPick)
        #expect(current.origin == .rebuilt)
        #expect(current.targetBranch?.name == "main")
        #expect(current.originalBranchTip == nil)
        guard case .cherryPick(nil, false, let commits) = current.detail else {
            Issue.record("Unexpected detail \(current.detail)")
            return
        }
        #expect(commits.map(\.summary) == ["One"])
        #expect(fixture.model.operations.conflictState == .cherryPick(targetBranchName: "main", manualResolutions: [:]))
        await fixture.app.idle()
    }

    @Test("an operation finished or aborted elsewhere ends")
    func endsElsewhere() async throws {
        let fixture = try await makeConflictingRepository()
        #expect(try await fixture.model.operations.merge(try fixture.branch("feature")) == .conflicted)
        fixture.model.operations.setManualResolution(.ours, forPath: "README.md")

        try await runGit(["merge", "--abort"], fixture.local)
        await fixture.model.refresh(.status, reason: .fileSystem)
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.model.operations.conflictState == nil)

        // A new merge starts without the old choices.
        #expect(try await fixture.model.operations.merge(try fixture.branch("feature")) == .conflicted)
        #expect(fixture.model.operations.conflictState?.manualResolutions == [:])
        await fixture.app.idle()
    }

    @Test("notices conflicts resolved and staged elsewhere, so aborting asks first")
    func resolvedElsewhere() async throws {
        let fixture = try await makeConflictingRepository()
        let operations = fixture.model.operations
        #expect(try await operations.merge(try fixture.branch("feature")) == .conflicted)
        #expect(operations.current?.userHasResolvedConflicts == false)

        try fixture.write("README.md", numberedLinesReplacing(1, with: "line resolved"))
        try await runGit(["add", "README.md"], fixture.local)
        await fixture.model.refresh(.status, reason: .fileSystem)

        #expect(operations.current?.userHasResolvedConflicts == true)
        #expect(operations.resolvedFiles.isEmpty)
        #expect(operations.canContinue)
        let error = await #expect(throws: OperationError.self) {
            try await operations.abortOperation()
        }
        #expect(error?.reason == .confirmationRequired(.abortWithResolvedConflicts(operation: "Merge")))
        await fixture.app.idle()
    }

    @Test("marking conflicts resolved makes aborting ask first")
    func markResolved() async throws {
        let fixture = try await makeConflictingRepository()
        let operations = fixture.model.operations
        // Nothing to mark without an operation.
        try await operations.markConflictsResolved()
        #expect(operations.current == nil)

        #expect(try await operations.merge(try fixture.branch("feature")) == .conflicted)
        try await operations.markConflictsResolved()
        #expect(operations.current?.userHasResolvedConflicts == true)
        // It sticks across passes.
        await fixture.model.refresh(.status, reason: .user)
        #expect(operations.current?.userHasResolvedConflicts == true)
        await fixture.app.idle()
    }

    @Test("continuing and aborting a rebase or cherry-pick go to D2's operations")
    func d2Hooks() async throws {
        let repository = try await createRebaseTestRepository("base-branch", "feature-branch")
        try await runGit(["checkout", "-q", "feature-branch"], repository)
        #expect(try await runGitAllowingFailure(["rebase", "base-branch"], repository) != 0)
        let (_, app, model) = try await select(repository)
        for path in ["OTHER.md", "THING.md"] {
            model.operations.setManualResolution(.ours, forPath: path)
        }

        let aborted = await #expect(throws: OperationError.self) {
            try await model.operations.abortOperation()
        }
        #expect(aborted?.reason == .confirmationRequired(.abortWithResolvedConflicts(operation: "Rebase")))
        #expect(aborted?.operation == .abortRebase)
        // A rebase started elsewhere: its base isn't known.
        let continued = try await model.operations.continueOperation()
        #expect(continued == .multiCommit(.rebased(targetBranch: "feature-branch", baseBranch: nil)))
        #expect(model.operations.current == nil)
        await app.idle()
    }
}
