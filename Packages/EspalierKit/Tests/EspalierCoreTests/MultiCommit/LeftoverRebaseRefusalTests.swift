// The operations Espalier refuses over a rebase in progress, with git's
// state as the model hasn't seen it (the lane's checks): over a rebase's
// state Espalier can't continue or abort, each offers "Clear Old Rebase and
// Continue", which clears it and runs the operation; over a rebase stopped
// on conflicts or interrupted between commits, each keeps its refusal; over
// the `REBASE_HEAD` that `git rebase --quit` leaves, which git treats as no
// rebase, none refuses.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// What a refused operation must leave alone: HEAD, every ref (the
/// remote's too), the index, and the rebase's state files.
private struct GitSnapshot: Equatable {
    let head: String
    let headSHA: String
    let refs: String
    let remoteRefs: String
    let index: String
    let stateFiles: [String]
}

/// An operation refused over a rebase in progress, run in the repository
/// `LeftoverRebaseRefusalTests` makes.
enum RefusedOperation: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case checkoutBranch = "checking out a branch"
    case checkoutCommit = "checking out a commit"
    case createBranch = "creating a branch"
    case renameBranch = "renaming a branch"
    case deleteBranch = "deleting a branch"
    case deleteCurrentBranch = "deleting the checked-out branch"
    case deleteRemoteBranch = "deleting a remote branch"
    case rebase = "rebasing"
    case squash = "squashing"
    case reorder = "reordering"
    case cherryPick = "cherry-picking"
    case revert = "reverting"
    case undoCommit = "undoing a commit"
    case resetToCommit = "resetting to a commit"

    var testDescription: String {
        rawValue
    }

    /// The operation, as its error and its retry name it.
    var kind: OperationKind {
        switch self {
        case .checkoutBranch: .checkoutBranch
        case .checkoutCommit: .checkoutCommit
        case .createBranch: .createBranch
        case .renameBranch: .renameBranch
        case .deleteBranch, .deleteCurrentBranch: .deleteBranch
        case .deleteRemoteBranch: .deleteRemoteBranch
        case .rebase: .rebase
        case .squash: .squash
        case .reorder: .reorder
        case .cherryPick: .cherryPick
        case .revert: .revert
        case .undoCommit: .undoCommit
        case .resetToCommit: .resetToCommit
        }
    }

    /// Runs it.
    @MainActor
    func run(_ fixture: SelectedRepository) async throws {
        let branches = fixture.model.branches
        let operations = fixture.model.operations
        switch self {
        case .checkoutBranch:
            _ = try await branches.checkout(try fixture.branch("other"))
        case .checkoutCommit:
            try await branches.checkout(commit: try await fixture.oneLine("other"), confirmed: [.checkoutCommit])
        case .createBranch:
            try await branches.createBranch("topic", startPoint: nil)
        case .renameBranch:
            try await branches.rename(try fixture.branch("other"), to: "renamed")
        case .deleteBranch:
            try await branches.delete(try fixture.branch("other"), includingRemote: false, confirmed: [.deleteBranch])
        case .deleteCurrentBranch:
            try await branches.delete(try fixture.branch("feature"), includingRemote: false, confirmed: [.deleteBranch])
        case .deleteRemoteBranch:
            try await branches.delete(try fixture.branch("origin/other"), includingRemote: false, confirmed: [.deleteRemoteBranch])
        case .rebase:
            _ = try await operations.rebase(onto: try fixture.branch("base"))
        case .squash:
            _ = try await operations.squash(
                [try await fixture.commit("feature")],
                into: try await fixture.commit("feature~1"),
                lastRetainedCommitRef: try await fixture.sha("feature~2"),
                message: CommitContext(summary: "Squashed", description: nil)
            )
        case .reorder:
            _ = try await operations.reorder(
                [try await fixture.commit("feature")],
                before: try await fixture.commit("feature~1"),
                lastRetainedCommitRef: try await fixture.sha("feature~2")
            )
        case .cherryPick:
            _ = try await operations.cherryPick([try await fixture.oneLine("base")], onto: try fixture.branch("feature"))
        case .revert:
            _ = try await operations.revert(try await fixture.commit("feature"))
        case .undoCommit:
            try await fixture.model.commit.undo(try await fixture.commit("feature"))
        case .resetToCommit:
            try await fixture.model.commit.reset(to: try await fixture.commit("feature~1"), confirmed: [.resetToCommit])
        }
    }

    /// Checks what it did.
    @MainActor
    func check(_ fixture: SelectedRepository) async throws {
        switch self {
        case .checkoutBranch:
            #expect(try await fixture.checkedOutBranch() == "other")
        case .checkoutCommit:
            let other = try await fixture.sha("other")
            #expect(try await fixture.checkedOutBranch() == nil)
            #expect(try await fixture.head() == other)
        case .createBranch:
            let feature = try await fixture.sha("feature")
            #expect(try await fixture.checkedOutBranch() == "topic")
            #expect(try await fixture.sha("topic") == feature)
        case .renameBranch:
            #expect(try await runGit(["branch", "--list", "other", "renamed"], fixture.local) == "  renamed\n")
        case .deleteBranch:
            #expect(try await runGit(["branch", "--list", "other"], fixture.local).isEmpty)
            #expect(try await fixture.checkedOutBranch() == "feature")
        case .deleteCurrentBranch:
            #expect(try await runGit(["branch", "--list", "feature"], fixture.local).isEmpty)
            #expect(try await fixture.checkedOutBranch() == "main")
        case .deleteRemoteBranch:
            #expect(try await runGit(["branch", "--list", "other"], fixture.remote).isEmpty)
        case .rebase:
            #expect(try await fixture.summaries("feature") == ["Feature", "Feature README", "Base", "Number the lines", "Initial commit"])
        case .squash:
            #expect(try await fixture.summaries("feature") == ["Squashed", "Number the lines", "Initial commit"])
        case .reorder:
            #expect(try await fixture.summaries("feature") == ["Feature README", "Feature", "Number the lines", "Initial commit"])
        case .cherryPick:
            #expect(try await fixture.summaries("feature").first == "Base")
            #expect(try await fixture.checkedOutBranch() == "feature")
        case .revert:
            #expect(try await fixture.summaries("feature").first == "Revert \"Feature\"")
            #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(fixture.local.path, "feature.txt")))
        case .undoCommit:
            #expect(try await fixture.summaries("feature").first == "Feature README")
            #expect(try fixture.read("feature.txt") == "feature\n")
            #expect(fixture.model.commit.draft.summary == "Feature")
        case .resetToCommit:
            #expect(try await fixture.summaries("feature").first == "Feature README")
            #expect(try fixture.read("feature.txt") == "feature\n")
        }
    }
}

@Suite("Refusals over a rebase's state", .offline, .hangGuard(minutes: 5)) @MainActor
struct LeftoverRebaseRefusalTests {
    /// `main` (README.md's eight numbered lines, on `origin`), `other`
    /// there (on `origin` too), `base` with a commit of its own, and
    /// `feature` (checked out): "Feature README", whose first line conflicts
    /// with `main`'s next commit, then "Feature". Nothing is in progress.
    private func makeRepository() async throws -> SelectedRepository {
        let fixture = try await makeSelectedRepository { local in
            try await commitFile(local, "README.md", numberedLines, message: "Number the lines")
            try await runGit(["push", "-q", "origin", "main"], local)
            try await runGit(["branch", "other"], local)
            try await runGit(["push", "-q", "origin", "other"], local)
            try await runGit(["checkout", "-q", "-b", "base"], local)
            try await commitFile(local, "base.txt", "base\n", message: "Base")
            try await runGit(["checkout", "-q", "-b", "feature", "main"], local)
            try await commitFile(local, "README.md", numberedLinesReplacing(1, with: "line one"), message: "Feature README")
            try await commitFile(local, "feature.txt", "feature\n", message: "Feature")
            try await runGit(["checkout", "-q", "main"], local)
            try await commitFile(local, "README.md", numberedLinesReplacing(1, with: "line uno"), message: "Main README")
            try await runGit(["checkout", "-q", "feature"], local)
        }
        await fixture.refreshAll()
        return fixture
    }

    private func snapshot(_ fixture: SelectedRepository) async throws -> GitSnapshot {
        GitSnapshot(
            head: JSCompat.trim(try await runGit(["rev-parse", "--symbolic-full-name", "HEAD"], fixture.local)),
            headSHA: try await fixture.head(),
            refs: try await runGit(["for-each-ref", "--format=%(refname) %(objectname)"], fixture.local),
            remoteRefs: try await runGit(["for-each-ref", "--format=%(refname) %(objectname)"], fixture.remote),
            index: try await runGit(["ls-files", "--stage"], fixture.local),
            stateFiles: ["REBASE_HEAD", "rebase-merge", "rebase-apply"].filter(fixture.gitFileExists)
        )
    }

    @Test("over a rebase's state Espalier can't continue or abort, each offers to clear it, then runs", arguments: RefusedOperation.allCases)
    func leftover(_ operation: RefusedOperation) async throws {
        let fixture = try await makeRepository()
        try FileManager.default.createDirectory(atPath: POSIXPath.join(fixture.local.path, ".git/rebase-merge"), withIntermediateDirectories: false)
        await fixture.refreshAll()
        // Nothing shows a rebase, so only the lane's check refuses.
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.model.gitState.inProgress == nil)
        let before = try await snapshot(fixture)

        let error = await #expect(throws: OperationError.self) {
            try await operation.run(fixture)
        }
        let leftover = LeftoverRebase(hasAutostash: false)
        let message = [.rebase, .squash, .reorder].contains(operation.kind) ? leftover.message : leftover.otherOperationMessage
        #expect(error?.reason == .precondition(message), "\(String(describing: error?.reason))")
        #expect(error?.operation == operation.kind)
        #expect(error?.recoveries.map(\.kind) == [.clearLeftoverRebaseAndRetry])
        guard case .clearLeftoverRebaseAndRetry(let id, let retry)? = error?.recoveries.first else {
            Issue.record("No Clear Old Rebase and Continue: \(String(describing: error?.recoveries))")
            return
        }
        #expect(id == fixture.model.id)
        #expect(retry.kind == operation.kind)
        await fixture.app.idle()
        #expect(try await snapshot(fixture) == before)

        try await error?.recoveries.first?.perform(in: fixture.app)
        await fixture.app.idle()
        #expect(!fixture.hasRebaseState())
        try await operation.check(fixture)
    }

    @Test("over a rebase stopped on conflicts, each keeps its refusal, offering nothing, and leaves the rebase", arguments: RefusedOperation.allCases)
    func stoppedRebase(_ operation: RefusedOperation) async throws {
        let fixture = try await makeRepository()
        // Outside Espalier, and not refreshed: the model still has feature
        // checked out, with nothing in progress.
        #expect(try await runGitAllowingFailure(["rebase", "main"], fixture.local) != 0)
        let before = try await snapshot(fixture)
        try #require(before.stateFiles == ["REBASE_HEAD", "rebase-merge"])
        try await expectRefusalKept(operation, fixture: fixture, before: before)
    }

    @Test("over a rebase interrupted between commits, each keeps its refusal, offering nothing, and leaves the rebase", arguments: RefusedOperation.allCases)
    func interruptedRebase(_ operation: RefusedOperation) async throws {
        let fixture = try await makeRepository()
        try await interruptRebase(of: "feature", onto: "base", in: fixture.local)
        let before = try await snapshot(fixture)
        try #require(before.stateFiles == ["rebase-merge"])
        try await expectRefusalKept(operation, fixture: fixture, before: before)
    }

    /// Expects `operation` refused as before, with nothing to recover with,
    /// git's state as `before`, and the rebase shown once refreshed.
    private func expectRefusalKept(_ operation: RefusedOperation, fixture: SelectedRepository, before: GitSnapshot) async throws {
        let error = await #expect(throws: OperationError.self) {
            try await operation.run(fixture)
        }
        #expect(preconditionText(error) != nil, "\(String(describing: error?.reason))")
        #expect(error?.recoveries.isEmpty == true)
        await fixture.app.idle()
        #expect(try await snapshot(fixture) == before)
        // The refresh shows the rebase, to continue or abort.
        await fixture.model.operations.enrichmentIdle()
        #expect(fixture.model.operations.current?.kind == .rebase)
    }

    @Test("over the REBASE_HEAD git rebase --quit leaves, none refuses", arguments: RefusedOperation.allCases)
    func strayRebaseHead(_ operation: RefusedOperation) async throws {
        let fixture = try await makeRepository()
        try await leaveRebaseHead(fixture)
        await fixture.refreshAll()
        #expect(fixture.model.operations.current == nil)
        #expect(fixture.model.operations.conflictState == nil)
        #expect(fixture.model.gitState.inProgress == nil)
        #expect(fixture.model.operations.checkoutRefusal == nil)
        #expect(!fixture.model.capabilitiesState.isOperationInProgress)

        try await operation.run(fixture)
        await fixture.app.idle()
        try await operation.check(fixture)
    }

    /// Stops a rebase of feature onto main on conflicts, quits it, and puts
    /// feature back as it was: git keeps only `REBASE_HEAD`.
    private func leaveRebaseHead(_ fixture: SelectedRepository) async throws {
        #expect(try await runGitAllowingFailure(["rebase", "main"], fixture.local) != 0)
        try await runGit(["rebase", "--quit"], fixture.local)
        try await runGit(["reset", "-q", "--hard"], fixture.local)
        try await runGit(["checkout", "-q", "feature"], fixture.local)
        try #require(["REBASE_HEAD", "rebase-merge", "rebase-apply"].filter(fixture.gitFileExists) == ["REBASE_HEAD"])
        // Git shows no rebase, and has none to abort.
        #expect(!(try await runGit(["status"], fixture.local)).contains("rebas"))
        #expect(try await runGitAllowingFailure(["rebase", "--abort"], fixture.local) == 128)
    }

    @Test("a rebase's state beside an operation git began keeps the refusals that operation causes")
    func leftoverBesideCherryPick() async throws {
        /// feature with a cherry-pick of main's conflicting commit stopped
        /// outside Espalier, and an empty `rebase-merge`; not refreshed.
        func makeFixture() async throws -> SelectedRepository {
            let fixture = try await makeRepository()
            #expect(try await runGitAllowingFailure(["cherry-pick", "main"], fixture.local) != 0)
            try #require(fixture.gitFileExists("CHERRY_PICK_HEAD"))
            try FileManager.default.createDirectory(atPath: POSIXPath.join(fixture.local.path, ".git/rebase-merge"), withIntermediateDirectories: false)
            return fixture
        }

        // A checkout and a revert stay refused as before: clearing the
        // rebase's state wouldn't let them run.
        let checkingOut = try await makeFixture()
        let checkout = await #expect(throws: OperationError.self) {
            _ = try await checkingOut.model.branches.checkout(try checkingOut.branch("other"))
        }
        #expect(preconditionText(checkout) != nil)
        #expect(checkout?.recoveries.isEmpty == true)
        await checkingOut.app.idle()

        let reverting = try await makeFixture()
        let revert = await #expect(throws: OperationError.self) {
            _ = try await reverting.model.operations.revert(try await reverting.commit("feature"))
        }
        #expect(preconditionText(revert) != nil)
        #expect(revert?.recoveries.isEmpty == true)
        await reverting.app.idle()

        // A cherry-pick doesn't stop renaming: clearing lets it run.
        let renaming = try await makeFixture()
        let rename = await #expect(throws: OperationError.self) {
            try await renaming.model.branches.rename(try renaming.branch("other"), to: "renamed")
        }
        #expect(rename?.reason == .precondition(LeftoverRebase(hasAutostash: false).otherOperationMessage))
        try await rename?.recoveries.first?.perform(in: renaming.app)
        await renaming.app.idle()
        #expect(try await runGit(["branch", "--list", "renamed"], renaming.local) == "  renamed\n")
        #expect(renaming.gitFileExists("CHERRY_PICK_HEAD"))
        #expect(!renaming.hasRebaseState())
    }
}
