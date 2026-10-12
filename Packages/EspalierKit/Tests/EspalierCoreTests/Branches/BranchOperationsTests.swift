// These drive `BranchesModel`'s branch flows against real git, including
// the checkout target after deleting a branch, and renaming a branch with
// its stash.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Branch operations", .offline) @MainActor
struct BranchOperationsTests {
    /// `main` (checked out, tracking `origin/main`) and `feature`, one
    /// commit ahead of it.
    private func makeRepository() async throws -> SelectedRepository {
        try await makeSelectedRepository { local in
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n", message: "Feature")
            try await runGit(["checkout", "-q", "main"], local)
        }
    }

    private func localBranchNames(_ fixture: SelectedRepository) async throws -> [String] {
        try await runGit(["branch", "--format=%(refname:short)"], fixture.local).split(separator: "\n").map(String.init)
    }

    private func remoteHasBranch(_ fixture: SelectedRepository, _ name: String) async throws -> Bool {
        try await runGitAllowingFailure(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], fixture.remote) == 0
    }

    // MARK: Creating

    @Test("creates a branch from HEAD and checks it out")
    func createsAndChecksOut() async throws {
        let fixture = try await makeRepository()
        let head = try await fixture.head()
        let branch = try await fixture.model.branches.createBranch("topic", startPoint: nil)

        #expect(branch.name == "topic")
        #expect(branch.type == .local)
        #expect(branch.tip.sha == head)
        #expect(fixture.model.gitState.tip.branch?.name == "topic")
        #expect(fixture.model.gitState.branches.all.contains { $0.name == "topic" })
        await fixture.app.idle()
    }

    @Test("creates a branch from a commit without checking it out")
    func createsWithoutCheckout() async throws {
        let fixture = try await makeRepository()
        let featureTip = try fixture.branch("feature").tip.sha
        let branch = try await fixture.model.branches.createBranch("from-commit", startPoint: featureTip, checkout: false)

        #expect(branch.tip.sha == featureTip)
        #expect(fixture.model.gitState.tip.branch?.name == "main")
        #expect(try await localBranchNames(fixture).contains("from-commit"))
        await fixture.app.idle()
    }

    @Test("offers the default branch as the start point, and HEAD on a detached HEAD")
    func startPoints() async throws {
        let fixture = try await makeRepository()
        let branches = fixture.model.branches
        // Not a fork, so no upstream default branch.
        #expect(branches.startPoint() == .defaultBranch)
        #expect(branches.startPoint(preferring: .currentBranch) == .currentBranch)
        #expect(branches.branch(for: .defaultBranch)?.name == "main")
        #expect(branches.branch(for: .upstreamDefaultBranch) == nil)
        #expect(branches.branch(for: .head) == nil)

        // From the default branch while on another.
        _ = try await branches.checkout(try fixture.branch("feature"))
        let fromDefault = try await branches.createBranch("from-default", from: .defaultBranch, checkout: false)
        #expect(fromDefault.tip.sha == (try fixture.branch("main").tip.sha))
        // A fork's upstream default branch doesn't exist here.
        let error = await #expect(throws: OperationError.self) {
            try await branches.createBranch("from-upstream", from: .upstreamDefaultBranch)
        }
        #expect(preconditionText(error) != nil)

        try await runGit(["checkout", "-q", "--detach", "HEAD"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        #expect(branches.startPoint(preferring: .defaultBranch) == .head)
        await fixture.app.idle()
    }

    @Test("a taken name is refused")
    func nameTaken() async throws {
        let fixture = try await makeRepository()
        #expect(fixture.model.branches.branchNameError("feature") != nil)
        #expect(fixture.model.branches.branchNameError("new") == nil)
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.createBranch("feature", startPoint: nil)
        }
        #expect(preconditionText(error) != nil)
        await fixture.app.idle()
    }

    @Test("with changes and the ask strategy, the branch exists and its checkout asks")
    func createAsksForCheckout() async throws {
        let fixture = try await makeRepository()
        try fixture.write("notes.txt", "notes\n")
        await fixture.model.refresh(.status, reason: .user)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.createBranch("topic", startPoint: nil)
        }
        #expect(error?.operation == .checkoutBranch)
        #expect(error?.reason == .decisionRequired(.uncommittedChanges(currentBranch: "main", targetBranch: "topic", currentBranchHasStash: false)))
        let topic = try fixture.branch("topic")
        #expect(fixture.model.gitState.tip.branch?.name == "main")

        #expect(try await fixture.model.branches.checkout(topic, strategy: .moveToNewBranch) == .checkedOut(topic))
        #expect(fixture.model.changes.workingDirectory.files.map(\.path) == ["notes.txt"])
        await fixture.app.idle()
    }

    // MARK: Renaming

    @Test("renaming a branch moves its stash along")
    func renameMovesStash() async throws {
        let fixture = try await makeRepository()
        try fixture.write("notes.txt", "notes\n")
        await fixture.model.refresh(.status, reason: .user)
        #expect(try await fixture.model.stash.stashAllChanges())
        await fixture.model.refresh(.full, reason: .user)
        #expect(fixture.model.stash.current?.branchName == "main")

        try await fixture.model.branches.rename(try fixture.branch("main"), to: "trunk")

        #expect(fixture.model.gitState.tip.branch?.name == "trunk")
        #expect(try await fixture.stashList() == ["On trunk: !!Espalier<trunk>"])
        #expect(fixture.model.gitState.stashes.entriesByBranch["trunk"] != nil)
        #expect(fixture.model.gitState.stashes.entriesByBranch["main"] == nil)
        #expect(fixture.model.stash.current?.branchName == "trunk")
        // The stash still holds the changes.
        let files = try await runGit(["stash", "show", "--include-untracked", "--name-only", "stash@{0}"], fixture.local)
        #expect(files.contains("notes.txt"))
        // The upstream keeps its name.
        #expect(fixture.model.gitState.tip.branch?.upstream == "origin/main")
        await fixture.app.idle()
    }

    @Test("renames a branch without a stash, and only local branches")
    func renameWithoutStash() async throws {
        let fixture = try await makeRepository()
        try await fixture.model.branches.rename(try fixture.branch("feature"), to: "renamed")
        #expect(try await localBranchNames(fixture).sorted() == ["main", "renamed"])
        #expect(try await fixture.stashList().isEmpty)

        let remote = ModelFixtures.branch("origin/main", type: .remote)
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.rename(remote, to: "other")
        }
        #expect(preconditionText(error) != nil)
        await fixture.app.idle()
    }

    // MARK: Deleting

    @Test("deleting asks first, saying whether the branch is on the remote")
    func deleteConfirmation() async throws {
        let fixture = try await makeRepository()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.delete(try fixture.branch("feature"), includingRemote: false)
        }
        #expect(error?.reason == .confirmationRequired(.deleteBranch("feature", existsOnRemote: false)))

        try await runGit(["push", "-q", "-u", "origin", "feature"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let pushed = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.delete(try fixture.branch("feature"), includingRemote: true)
        }
        #expect(pushed?.reason == .confirmationRequired(.deleteBranch("feature", existsOnRemote: true)))
        #expect(try await localBranchNames(fixture).contains("feature"))
        await fixture.app.idle()
    }

    @Test("deletes a branch that isn't checked out")
    func deletesOtherBranch() async throws {
        let fixture = try await makeRepository()
        try await fixture.model.branches.delete(try fixture.branch("feature"), includingRemote: false, confirmed: [.deleteBranch])
        #expect(try await localBranchNames(fixture) == ["main"])
        #expect(!fixture.model.gitState.branches.all.contains { $0.name == "feature" })
        #expect(fixture.model.gitState.tip.branch?.name == "main")
        await fixture.app.idle()
    }

    @Test("deleting the checked-out branch checks out the default branch first")
    func deletesCurrentBranch() async throws {
        let fixture = try await makeRepository()
        let feature = try fixture.branch("feature")
        _ = try await fixture.model.branches.checkout(feature)

        try await fixture.model.branches.delete(try fixture.branch("feature"), includingRemote: false, confirmed: [.deleteBranch])
        #expect(fixture.model.gitState.tip.branch?.name == "main")
        #expect(try await localBranchNames(fixture) == ["main"])
        await fixture.app.idle()
    }

    @Test("deleting the checked-out default branch checks out a recent branch")
    func deletesDefaultBranch() async throws {
        let fixture = try await makeRepository()
        // feature becomes a recent branch.
        _ = try await fixture.model.branches.checkout(try fixture.branch("feature"))
        _ = try await fixture.model.branches.checkout(try fixture.branch("main"))
        #expect(fixture.model.gitState.branches.defaultBranch?.name == "main")
        #expect(fixture.model.gitState.branches.recent.map(\.name) == ["feature"])

        // The default branch is the one being deleted, so a recent branch is
        // checked out instead.
        try await fixture.model.branches.delete(try fixture.branch("main"), includingRemote: false, confirmed: [.deleteBranch])
        #expect(fixture.model.gitState.tip.branch?.name == "feature")
        #expect(try await localBranchNames(fixture) == ["feature"])
        await fixture.app.idle()
    }

    @Test("deleting a branch on a detached HEAD checks nothing out")
    func deletesWhileDetached() async throws {
        let fixture = try await makeRepository()
        try await runGit(["checkout", "-q", "--detach", "HEAD"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let head = try await fixture.head()

        // A detached HEAD stays where it is.
        try await fixture.model.branches.delete(try fixture.branch("feature"), includingRemote: false, confirmed: [.deleteBranch])
        #expect(fixture.model.gitState.tip == .detached(currentSha: head))
        #expect(try await localBranchNames(fixture).contains("main"))
        #expect(!(try await localBranchNames(fixture).contains("feature")))
        await fixture.app.idle()
    }

    @Test("deleting the only branch is refused")
    func deletesOnlyBranch() async throws {
        let fixture = try await makeSelectedRepository()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.delete(try fixture.branch("main"), includingRemote: false, confirmed: [.deleteBranch])
        }
        #expect(preconditionText(error) != nil)
        #expect(try await localBranchNames(fixture) == ["main"])
        await fixture.app.idle()
    }

    @Test("deletes a branch and its upstream")
    func deletesUpstream() async throws {
        let fixture = try await makeRepository()
        try await runGit(["push", "-q", "-u", "origin", "feature"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        #expect(try await remoteHasBranch(fixture, "feature"))

        try await fixture.model.branches.delete(try fixture.branch("feature"), includingRemote: true, confirmed: [.deleteBranch])
        #expect(!(try await remoteHasBranch(fixture, "feature")))
        #expect(!(try await localBranchNames(fixture).contains("feature")))
        #expect(!fixture.model.gitState.branches.all.contains { $0.name.hasSuffix("feature") })
        await fixture.app.idle()
    }

    @Test("deletes a branch that's only on the remote, asking first")
    func deletesRemoteBranch() async throws {
        let fixture = try await makeRepository()
        try await runGit(["push", "-q", "origin", "feature:topic"], fixture.local)
        try await runGit(["fetch", "-q", "origin"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let topic = try fixture.branch("origin/topic")
        #expect(topic.type == .remote)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.delete(topic, includingRemote: false)
        }
        #expect(error?.reason == .confirmationRequired(.deleteRemoteBranch("origin/topic")))

        try await fixture.model.branches.delete(topic, includingRemote: false, confirmed: [.deleteRemoteBranch])
        #expect(!(try await remoteHasBranch(fixture, "topic")))
        #expect(!fixture.model.gitState.branches.all.contains { $0.name == "origin/topic" })
        #expect(fixture.model.gitState.tip.branch?.name == "main")
        await fixture.app.idle()
    }

    @Test("deleting a remote branch already gone there removes the remote-tracking branch")
    func deletesRemoteBranchAlreadyGone() async throws {
        let fixture = try await makeRepository()
        try await runGit(["push", "-q", "origin", "feature:topic"], fixture.local)
        try await runGit(["fetch", "-q", "origin"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let topic = try fixture.branch("origin/topic")
        try await runGit(["branch", "-D", "topic"], fixture.remote)

        try await fixture.model.branches.delete(topic, includingRemote: false, confirmed: [.deleteRemoteBranch])
        #expect(!fixture.model.gitState.branches.all.contains { $0.name == "origin/topic" })
        await fixture.app.idle()
    }

    // MARK: Checking out a commit

    @Test("checks out a commit, asking first while the preference says so")
    func checksOutCommit() async throws {
        let fixture = try await makeRepository()
        let feature = try fixture.branch("feature")
        let commit = CommitOneLine(sha: feature.tip.sha, summary: "Feature")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.checkout(commit: commit)
        }
        #expect(error?.reason == .confirmationRequired(.checkoutCommit(sha: feature.tip.sha)))

        try await fixture.model.branches.checkout(commit: commit, confirmed: [.checkoutCommit])
        #expect(fixture.model.gitState.tip == .detached(currentSha: feature.tip.sha))
        #expect(fixture.model.refreshScheduler.lastPassReasons.contains(.operation(.checkoutCommit)))

        // Checking out the commit HEAD is at does nothing.
        let passes = fixture.model.refreshScheduler.passCount
        try await fixture.model.branches.checkout(commit: commit)
        #expect(fixture.model.refreshScheduler.passCount == passes)

        // Without the preference, nothing asks.
        fixture.app.preferences.confirmCheckoutCommit = false
        let main = try fixture.branch("main")
        try await fixture.model.branches.checkout(commit: CommitOneLine(sha: main.tip.sha, summary: "Initial commit"))
        #expect(fixture.model.gitState.tip == .detached(currentSha: main.tip.sha))
        await fixture.app.idle()
    }

    // MARK: Ahead and behind

    @Test("compares a local branch with its upstream")
    func aheadBehindOfBranch() async throws {
        let fixture = try await makeRepository()
        try await commitFile(fixture.local, "local.txt", "local\n")
        await fixture.model.refresh(.full, reason: .user)

        #expect(await fixture.model.branches.aheadBehind(of: try fixture.branch("main")) == AheadBehind(ahead: 1, behind: 0))
        // No upstream.
        #expect(await fixture.model.branches.aheadBehind(of: try fixture.branch("feature")) == nil)
        // A remote branch.
        #expect(await fixture.model.branches.aheadBehind(of: ModelFixtures.branch("origin/main", type: .remote)) == nil)
        // An upstream that's gone.
        let gone = ModelFixtures.branch("feature", upstream: "origin/gone")
        #expect(await fixture.model.branches.aheadBehind(of: gone) == nil)
        await fixture.app.idle()
    }

    @Test("groups the branches for the branch list")
    func groups() async throws {
        let fixture = try await makeRepository()
        _ = try await fixture.model.branches.createBranch("other", startPoint: nil, checkout: false)
        _ = try await fixture.model.branches.checkout(try fixture.branch("feature"))
        _ = try await fixture.model.branches.checkout(try fixture.branch("main"))

        let groups = fixture.model.branches.groups
        #expect(groups.map(\.identifier) == [.defaultBranch, .recent, .other])
        #expect(groups.map { $0.branches.map(\.name) } == [["main"], ["feature"], ["other"]])
        await fixture.app.idle()
    }
}
