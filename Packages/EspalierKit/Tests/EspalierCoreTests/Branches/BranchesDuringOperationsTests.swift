// These drive the branch intents against real git while a merge,
// cherry-pick, revert, rebase, or interrupted rebase is in progress:
// checking out (a branch or a commit) and creating a branch that is
// checked out are refused during any of them, renaming and deleting during
// a rebase, all before anything is written, so HEAD and the operation's
// state files stay as they were. Also for an operation git began since the
// last refresh (with the lane held), and the capabilities.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// What a refused branch change must leave alone: HEAD, the branches, the
/// index, and the operation's state files.
private struct GitSnapshot: Equatable {
    let head: String
    let headSHA: String
    let branches: String
    let index: String
    let stateFiles: [String]
}

private let stateFileNames = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "rebase-merge", "rebase-apply"]

@Suite("Branches during operations", .offline) @MainActor
struct BranchesDuringOperationsTests {
    /// `main` (README.md's eight numbered lines), `other`, and `feature`
    /// (checked out), whose first line conflicts with `main`'s: `feature`
    /// says "line one", `main` "line uno". `feature` also adds feature.txt;
    /// `twin` is where `feature` is, so git alone checks it out over a
    /// staged merge, dropping `MERGE_HEAD` (checked with the bundled git).
    private func makeRepository() async throws -> SelectedRepository {
        try await makeSelectedRepository { local in
            try await commitFile(local, "README.md", numberedLines, message: "Number the lines")
            try await runGit(["push", "-q", "origin", "main"], local)
            try await runGit(["branch", "other"], local)
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "README.md", numberedLinesReplacing(1, with: "line one"), message: "Feature README")
            try await commitFile(local, "feature.txt", "feature\n", message: "Feature")
            try await runGit(["branch", "twin"], local)
            try await runGit(["checkout", "-q", "main"], local)
            try await commitFile(local, "README.md", numberedLinesReplacing(1, with: "line uno"), message: "Main README")
            try await runGit(["checkout", "-q", "feature"], local)
        }
    }

    private func snapshot(_ fixture: SelectedRepository) async throws -> GitSnapshot {
        GitSnapshot(
            head: JSCompat.trim(try await runGit(["rev-parse", "--symbolic-full-name", "HEAD"], fixture.local)),
            headSHA: try await fixture.head(),
            branches: try await runGit(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"], fixture.local),
            index: try await runGit(["ls-files", "--stage"], fixture.local),
            stateFiles: stateFileNames.filter(fixture.gitFileExists)
        )
    }

    /// Resolves README.md's conflict and stages it: nothing is unmerged, so
    /// git itself would check out.
    private func stageResolution(_ fixture: SelectedRepository) async throws {
        try fixture.write("README.md", numberedLinesReplacing(1, with: "line one and uno"))
        try await runGit(["add", "README.md"], fixture.local)
    }

    /// Expects `body` to be refused.
    private func expectRefused(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> Void
    ) async {
        let error = await #expect(throws: OperationError.self, sourceLocation: sourceLocation) {
            try await body()
        }
        #expect(preconditionText(error) != nil, "\(String(describing: error?.reason))", sourceLocation: sourceLocation)
    }

    /// Expects every way of checking out to be refused: a branch (with
    /// every strategy), a commit, and a new branch (which isn't created).
    private func expectCheckoutsRefused(in fixture: SelectedRepository) async throws {
        let branches = fixture.model.branches
        let other = try fixture.branch("other")
        let twin = try fixture.branch("twin")
        await expectRefused { _ = try await branches.checkout(twin) }
        await expectRefused { _ = try await branches.checkout(other, strategy: .stashOnCurrentBranch) }
        await expectRefused { _ = try await branches.checkout(other) }
        await expectRefused { _ = try await branches.checkout(other, strategy: .moveToNewBranch) }
        // HEAD is never at `other` here.
        #expect(fixture.model.gitState.tip.sha != other.tip.sha)
        await expectRefused {
            try await branches.checkout(commit: CommitOneLine(sha: other.tip.sha, summary: "Number the lines"), confirmed: [.checkoutCommit])
        }
        await expectRefused { try await branches.createBranch("topic", startPoint: nil) }
        await expectRefused { try await branches.createBranch("topic", from: .defaultBranch) }
        await expectRefused { try branches.requireCheckoutAllowed(.createBranch) }
        #expect(fixture.model.operations.checkoutRefusal != nil)
    }

    // MARK: Merge, cherry-pick, revert

    @Test("a conflicted merge with everything staged refuses checkouts, keeping MERGE_HEAD; other branches can be renamed and deleted")
    func mergeStaged() async throws {
        let fixture = try await makeRepository()
        #expect(try await runGitAllowingFailure(["merge", "main"], fixture.local) != 0)
        try await stageResolution(fixture)
        await fixture.refreshAll()
        #expect(fixture.model.operations.current?.kind == .merge)
        #expect(fixture.model.changes.workingDirectory.files.allSatisfy { $0.status.kind != .conflicted })
        let before = try await snapshot(fixture)
        #expect(before.stateFiles == ["MERGE_HEAD"])

        try await expectCheckoutsRefused(in: fixture)
        // Deleting the current branch checks out another: refused before
        // asking.
        let feature = try fixture.branch("feature")
        await expectRefused {
            try await fixture.model.branches.delete(feature, includingRemote: false)
        }
        await expectRefused {
            try await fixture.model.branches.delete(feature, includingRemote: false, confirmed: [.deleteBranch])
        }
        #expect(try await snapshot(fixture) == before)
        #expect(fixture.model.operations.rebaseRefusal == nil)

        // Only a rebase stops renaming and deleting other branches.
        try await fixture.model.branches.rename(try fixture.branch("other"), to: "renamed")
        try await fixture.model.branches.delete(try fixture.branch("renamed"), includingRemote: false, confirmed: [.deleteBranch])
        #expect(try await runGit(["branch", "--list", "other", "renamed"], fixture.local).isEmpty)
        #expect(fixture.gitFileExists("MERGE_HEAD"))
        #expect(try await fixture.checkedOutBranch() == "feature")

        // Once the merge is committed, checking out works again.
        _ = try await fixture.model.operations.continueOperation()
        #expect(fixture.model.operations.checkoutRefusal == nil)
        #expect(try await fixture.model.branches.checkout(try fixture.branch("main")) == .checkedOut(try fixture.branch("main")))
        await fixture.app.idle()
    }

    @Test("a conflicted cherry-pick with everything staged refuses checkouts, keeping CHERRY_PICK_HEAD")
    func cherryPickStaged() async throws {
        let fixture = try await makeRepository()
        #expect(try await runGitAllowingFailure(["cherry-pick", "main"], fixture.local) != 0)
        try await stageResolution(fixture)
        await fixture.refreshAll()
        #expect(fixture.model.operations.current?.kind == .cherryPick)
        let before = try await snapshot(fixture)
        #expect(before.stateFiles == ["CHERRY_PICK_HEAD"])

        try await expectCheckoutsRefused(in: fixture)
        await expectRefused {
            try await fixture.model.branches.delete(try fixture.branch("feature"), includingRemote: false, confirmed: [.deleteBranch])
        }
        #expect(try await snapshot(fixture) == before)
        await fixture.app.idle()
    }

    @Test("a conflicted revert with everything staged refuses checkouts, keeping REVERT_HEAD")
    func revertStaged() async throws {
        let fixture = try await makeRepository()
        // Reverting "Feature README" conflicts with a later change to the
        // same line.
        try await commitFile(fixture.local, "README.md", numberedLinesReplacing(1, with: "line ONE"), message: "Feature README again")
        #expect(try await runGitAllowingFailure(["revert", "--no-edit", "HEAD~2"], fixture.local) != 0)
        try await stageResolution(fixture)
        await fixture.refreshAll()
        #expect(fixture.model.operations.current?.kind == .revert)
        let before = try await snapshot(fixture)
        #expect(before.stateFiles == ["REVERT_HEAD"])

        try await expectCheckoutsRefused(in: fixture)
        #expect(try await snapshot(fixture) == before)
        await fixture.app.idle()
    }

    // MARK: Rebases

    @Test("a conflicted rebase with everything staged refuses checkouts, renames, and deletes, keeping its state")
    func rebaseStaged() async throws {
        let fixture = try await makeRepository()
        let operations = fixture.model.operations
        #expect(try await operations.rebase(onto: try fixture.branch("main")) == .conflicted)
        try await stageResolution(fixture)
        await fixture.refreshAll()
        guard case .rebase? = operations.conflictState else {
            Issue.record("No rebase conflicts: \(String(describing: operations.conflictState))")
            return
        }
        let before = try await snapshot(fixture)
        #expect(before.head == "HEAD")
        #expect(before.stateFiles == ["REBASE_HEAD", "rebase-merge"])

        try await expectCheckoutsRefused(in: fixture)
        #expect(operations.rebaseRefusal != nil)
        let branches = fixture.model.branches
        await expectRefused { try await branches.rename(try fixture.branch("feature"), to: "renamed") }
        await expectRefused { try await branches.rename(try fixture.branch("other"), to: "renamed") }
        // Refused before asking.
        await expectRefused { try await branches.delete(try fixture.branch("feature"), includingRemote: false) }
        await expectRefused {
            try await branches.delete(try fixture.branch("other"), includingRemote: false, confirmed: [.deleteBranch])
        }
        let remoteMain = ModelFixtures.branch("origin/main", sha: try await fixture.sha("origin/main"), type: .remote)
        await expectRefused {
            try await branches.delete(remoteMain, includingRemote: false, confirmed: [.deleteRemoteBranch])
        }
        #expect(try await snapshot(fixture) == before)
        #expect(try await runGit(["branch", "--list", "main"], fixture.remote).contains("main"))

        // Continuing finishes the rebase on feature, which can then switch.
        #expect(try await operations.continueOperation() == .multiCommit(.rebased(targetBranch: "feature", baseBranch: "main")))
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(operations.checkoutRefusal == nil)
        #expect(try await fixture.model.branches.checkout(try fixture.branch("other")) == .checkedOut(try fixture.branch("other")))
        await fixture.app.idle()
    }

    @Test("an interrupted rebase refuses checkouts, renames, and deletes, keeping its state, and counts as a rebase")
    func interruptedRebase() async throws {
        let fixture = try await makeRepository()
        fixture.app.preferences.hasShownWelcomeFlow = true
        try await commitFile(fixture.local, "feature-2.txt", "two\n", message: "Feature two")
        // Onto `other`, where feature starts: no conflicts on the way.
        try await interruptRebase(of: "feature", onto: "other", in: fixture.local)
        await fixture.refreshAll()
        let operations = fixture.model.operations
        #expect(operations.current?.phase == .interrupted)
        #expect(operations.conflictState == nil)
        let before = try await snapshot(fixture)
        #expect(before.head == "HEAD")
        #expect(before.stateFiles == ["rebase-merge"])
        // Nothing is unmerged: git alone would check out.
        #expect(fixture.model.changes.workingDirectory.files.isEmpty)

        try await expectCheckoutsRefused(in: fixture)
        let branches = fixture.model.branches
        await expectRefused { try await branches.rename(try fixture.branch("feature"), to: "renamed") }
        await expectRefused {
            try await branches.delete(try fixture.branch("feature"), includingRemote: false, confirmed: [.deleteBranch])
        }
        await expectRefused { try await branches.delete(try fixture.branch("main"), includingRemote: false) }
        #expect(try await snapshot(fixture) == before)

        // The menus: a rebase in progress, nothing that checks out.
        #expect(fixture.model.capabilitiesState.isRebaseInProgress)
        #expect(fixture.model.capabilitiesState.isOperationInProgress)
        let capabilities = fixture.app.capabilities
        #expect(capabilities.isRepositoryActive)
        #expect(!capabilities.canCreateBranch)
        #expect(!capabilities.canShowBranchesList)
        #expect(!capabilities.canDeleteBranch)
        #expect(!capabilities.canRenameBranch)

        // Aborting puts feature back, and branches can change again.
        try await operations.abortOperation()
        #expect(try await fixture.checkedOutBranch() == "feature")
        #expect(operations.checkoutRefusal == nil)
        #expect(operations.rebaseRefusal == nil)
        #expect(fixture.app.capabilities.canCreateBranch)
        #expect(fixture.app.capabilities.canShowBranchesList)
        try await branches.rename(try fixture.branch("other"), to: "renamed")
        await fixture.app.idle()
    }

    // MARK: Since the last refresh

    @Test("an operation git began since the last refresh is refused with the lane held, before anything is written")
    func sinceLastRefresh() async throws {
        let fixture = try await makeRepository()
        let branches = fixture.model.branches
        // No refresh applies meanwhile, so the model never learns of the
        // operations: every refusal is the lane's.
        let hold = fixture.model.refreshScheduler.hold()

        // A merge outside Espalier.
        #expect(try await runGitAllowingFailure(["merge", "main"], fixture.local) != 0)
        try await stageResolution(fixture)
        let merging = try await snapshot(fixture)
        await expectRefused { try await branches.createBranch("topic", startPoint: nil) }
        await expectRefused { _ = try await branches.checkout(try fixture.branch("other")) }
        await expectRefused {
            try await branches.checkout(commit: CommitOneLine(sha: try fixture.branch("other").tip.sha, summary: ""), confirmed: [.checkoutCommit])
        }
        // Deleting the current branch would check out main first.
        await expectRefused {
            try await branches.delete(try fixture.branch("feature"), includingRemote: false, confirmed: [.deleteBranch])
        }
        #expect(fixture.model.operations.current == nil)
        #expect(try await snapshot(fixture) == merging)
        try await runGit(["merge", "--abort"], fixture.local)

        // A rebase interrupted outside Espalier, while the model still has
        // feature checked out.
        try await interruptRebase(of: "feature", onto: "other", in: fixture.local)
        let rebasing = try await snapshot(fixture)
        await expectRefused { try await branches.rename(try fixture.branch("other"), to: "renamed") }
        await expectRefused {
            try await branches.delete(try fixture.branch("other"), includingRemote: false, confirmed: [.deleteBranch])
        }
        let remoteMain = ModelFixtures.branch("origin/main", sha: try await fixture.sha("origin/main"), type: .remote)
        await expectRefused {
            try await branches.delete(remoteMain, includingRemote: false, confirmed: [.deleteRemoteBranch])
        }
        await expectRefused { _ = try await branches.checkout(try fixture.branch("other")) }
        await expectRefused { try await branches.createBranch("topic", startPoint: nil) }
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.model.gitState.tip.branch?.name == "feature")
        #expect(try await snapshot(fixture) == rebasing)
        #expect(try await runGit(["branch", "--list", "main"], fixture.remote).contains("main"))

        fixture.model.refreshScheduler.release(hold)
        await fixture.refreshAll()
        #expect(fixture.model.operations.current?.phase == .interrupted)
        await fixture.app.idle()
    }

    // MARK: The refusals

    @Test("each operation in progress refuses checkouts, and rebases refuse renames and deletes; one whose git runs is busy")
    func refusals() async throws {
        let fixture = try await makeRepository()
        let operations = fixture.model.operations
        let commit = makeTestCommit(sha: "abc", summary: "A")
        let cases: [(MultiCommitOperationKind, MultiCommitOperationDetail, Bool)] = [
            (.merge, .merge(sourceBranch: nil, isSquash: false), false),
            (.merge, .merge(sourceBranch: nil, isSquash: true), false),
            (.rebase, .rebase(sourceBranch: nil, commits: [], currentTip: "abc"), true),
            (.cherryPick, .cherryPick(sourceBranch: nil, branchCreated: false, commits: []), false),
            (.squash, .squash(commits: [commit], currentTip: "abc", lastRetainedCommitRef: nil, targetCommit: commit, commitContext: CommitContext(summary: "A", description: nil)), true),
            (.reorder, .reorder(commits: [commit], currentTip: "abc", lastRetainedCommitRef: nil, beforeCommit: nil), true),
            (.revert, .revert(commit: nil), false),
        ]
        for (kind, detail, isRebase) in cases {
            operations.current = MultiCommitOperation(kind: kind, detail: detail, phase: .conflicted, origin: .espalier)
            #expect(operations.checkoutRefusal != nil)
            #expect((operations.rebaseRefusal != nil) == isRebase)
            await expectRefused { try fixture.model.branches.requireCheckoutAllowed(.createBranch) }

            // While its git runs, the repository is busy.
            operations.current?.phase = .running(MultiCommitOperationProgress(value: 0, currentCommitSummary: "", position: 1, totalCommitCount: 1))
            let busy = #expect(throws: OperationError.self) {
                try fixture.model.branches.requireCheckoutAllowed(.createBranch)
            }
            #expect(busy?.reason == .busy(.createBranch))
        }
        operations.current = nil
        #expect(operations.checkoutRefusal == nil)
        #expect(operations.rebaseRefusal == nil)
        await fixture.app.idle()
    }
}
