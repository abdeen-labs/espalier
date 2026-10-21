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

    @Test("a branch from the default branch doesn't track it when it's the remote's")
    func fromRemoteDefaultBranch() async throws {
        // No local main; feature tracks origin/main.
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-q", "-b", "feature", "--track", "origin/main"], local)
            try await runGit(["branch", "-D", "main"], local)
        }
        let branches = fixture.model.branches
        let base = try #require(branches.branch(for: .defaultBranch))
        #expect(base.name == "origin/main")
        #expect(base.type == .remote)

        let topic = try await branches.createBranch("topic", from: .defaultBranch, checkout: false)
        #expect(topic.tip.sha == base.tip.sha)
        #expect(topic.upstream == nil)
        await fixture.app.idle()
    }

    @Test("a branch from the default branch starts at the branch, not a tag of its name")
    func fromDefaultBranchOverTag() async throws {
        let fixture = try await makeRepository()
        let main = try fixture.branch("main")
        let featureTip = try fixture.branch("feature").tip.sha
        // A tag `main` at feature's tip, made after the last refresh: the
        // branch list names a branch that shares a tag's name `heads/main`,
        // so the default branch keeps the name it was listed by.
        try await runGit(["tag", "main", featureTip], fixture.local)

        let topic = try await fixture.model.branches.createBranch("topic", from: .defaultBranch, checkout: false)
        #expect(topic.tip.sha == main.tip.sha)
        #expect(try await resolveRef("refs/heads/topic", in: fixture.local) == main.tip.sha)
        await fixture.app.idle()
    }

    @Test("a tag's name is refused for a new branch")
    func tagNameTaken() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["tag", "v1.0"], local)
        }
        #expect(fixture.model.branches.branchNameError("v1.0") != nil)
        #expect(fixture.model.branches.branchNameError("v1.1") == nil)
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.createBranch("v1.0", startPoint: nil)
        }
        #expect(preconditionText(error) != nil)
        #expect(try await localBranchNames(fixture) == ["main"])
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
        #expect(error?.reason == .decisionRequired(.uncommittedChanges(currentBranch: "main", targetBranch: "topic")))
        let topic = try fixture.branch("topic")
        #expect(fixture.model.gitState.tip.branch?.name == "main")

        #expect(try await fixture.model.branches.checkout(topic, strategy: .moveToNewBranch) == .checkedOut(topic))
        #expect(fixture.model.changes.workingDirectory.files.map(\.path) == ["notes.txt"])
        await fixture.app.idle()
    }

    // MARK: Renaming

    @Test("renaming a branch moves its stashes along, in their order, and leaves others alone")
    func renameMovesStash() async throws {
        let fixture = try await makeRepository()
        try fixture.write("notes.txt", "notes\n")
        await fixture.model.refresh(.status, reason: .user)
        #expect(try await fixture.model.stash.stashAllChanges())
        // One made outside Espalier, then another of main's.
        try fixture.write("mine.txt", "mine\n")
        try await runGit(["stash", "push", "-q", "--include-untracked", "-m", "my own"], fixture.local)
        try fixture.write("later.txt", "later\n")
        await fixture.model.refresh(.full, reason: .user)
        #expect(try await fixture.model.stash.stashAllChanges())
        await fixture.model.refresh(.full, reason: .user)
        #expect(fixture.model.stash.currentEntries.count == 2)

        try await fixture.model.branches.rename(try fixture.branch("main"), to: "trunk")

        #expect(fixture.model.gitState.tip.branch?.name == "trunk")
        #expect(try await fixture.stashList() == ["On trunk: !!Espalier<trunk>", "On trunk: !!Espalier<trunk>", "On main: my own"])
        #expect(fixture.model.gitState.stashes.entries(onBranch: "trunk").count == 2)
        #expect(fixture.model.gitState.stashes.entries(onBranch: "main").isEmpty)
        #expect(fixture.model.stash.current?.branchName == "trunk")
        // The stashes still hold the changes, the newest on top.
        #expect(try await runGit(["stash", "show", "--name-only", "stash@{0}"], fixture.local) == "later.txt\n")
        #expect(try await runGit(["stash", "show", "--name-only", "stash@{1}"], fixture.local) == "notes.txt\n")
        #expect(try await runGit(["stash", "show", "--include-untracked", "--name-only", "stash@{2}"], fixture.local) == "mine.txt\n")
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

    @Test("deleting asks first, naming the remote branch when the branch is on the remote")
    func deleteConfirmation() async throws {
        let fixture = try await makeRepository()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.delete(try fixture.branch("feature"), includingRemote: false)
        }
        #expect(error?.reason == .confirmationRequired(.deleteBranch("feature", upstream: nil)))

        try await runGit(["push", "-q", "-u", "origin", "feature"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        let pushed = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.delete(try fixture.branch("feature"), includingRemote: true)
        }
        #expect(pushed?.reason == .confirmationRequired(.deleteBranch("feature", upstream: "origin/feature")))
        #expect(try await localBranchNames(fixture).contains("feature"))
        await fixture.app.idle()
    }

    /// `main`, and `topic` (checked out) made from `origin/develop` and
    /// tracking it. The remote has `main`, `develop`, and a `topic` of its
    /// own that `topic` doesn't track.
    private func makeRepositoryTrackingOtherName() async throws -> SelectedRepository {
        try await makeSelectedRepository { local in
            try await runGit(["checkout", "-q", "-b", "develop"], local)
            try await commitFile(local, "develop.txt", "develop\n", message: "Develop")
            try await runGit(["push", "-q", "origin", "develop", "develop:topic"], local)
            try await runGit(["checkout", "-q", "main"], local)
            try await runGit(["branch", "-q", "-D", "develop"], local)
            try await runGit(["fetch", "-q", "origin"], local)
            try await runGit(["checkout", "-q", "-b", "topic", "--track", "origin/develop"], local)
        }
    }

    @Test("a branch tracking a remote branch of another name names that one in the confirmation")
    func deleteConfirmationNamesUpstream() async throws {
        let fixture = try await makeRepositoryTrackingOtherName()
        let topic = try fixture.branch("topic")
        #expect(topic.upstream == "origin/develop")

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.delete(topic, includingRemote: true)
        }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Deleting didn't ask first")
            return
        }
        #expect(confirmation.details == .deleteBranch(name: "topic", upstream: "origin/develop"))
        #expect(try await localBranchNames(fixture).contains("topic"))
        #expect(try await remoteHasBranch(fixture, "develop"))
        await fixture.app.idle()
    }

    @Test("deleting with its upstream deletes the remote branch the confirmation named and nothing else")
    func deletesUpstreamOfOtherName() async throws {
        let fixture = try await makeRepositoryTrackingOtherName()
        let remoteBefore = try await runGit(["for-each-ref", "--format=%(refname) %(objectname)"], fixture.remote)
            .split(separator: "\n").map(String.init)

        try await fixture.model.branches.delete(try fixture.branch("topic"), includingRemote: true, confirmed: [.deleteBranch])

        let remoteAfter = try await runGit(["for-each-ref", "--format=%(refname) %(objectname)"], fixture.remote)
            .split(separator: "\n").map(String.init)
        #expect(remoteAfter == remoteBefore.filter { !$0.hasPrefix("refs/heads/develop ") })
        #expect(!(try await remoteHasBranch(fixture, "develop")))
        #expect(try await remoteHasBranch(fixture, "topic"))
        #expect(try await remoteHasBranch(fixture, "main"))
        #expect(try await localBranchNames(fixture) == ["main"])
        #expect(fixture.model.gitState.tip.branch?.name == "main")
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

    @Test("deletes a remote branch, and a branch's upstream, on a remote whose name has a slash")
    func deletesOnRemoteWithSlash() async throws {
        let team = try await makeEmptyBareRemote()
        let fixture = try await makeSelectedRepository { local in
            try await runGit(["remote", "add", "team/alice", team.path], local)
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await commitFile(local, "feature.txt", "feature\n", message: "Feature")
            try await runGit(["push", "-q", "-u", "team/alice", "feature"], local)
            try await runGit(["push", "-q", "team/alice", "feature:topic"], local)
            try await runGit(["checkout", "-q", "main"], local)
        }
        func teamHasBranch(_ name: String) async throws -> Bool {
            try await runGitAllowingFailure(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], team) == 0
        }
        let topic = try fixture.branch("team/alice/topic")
        #expect(try topic.remoteName == "team/alice")
        #expect(topic.nameWithoutRemote == "topic")

        try await fixture.model.branches.delete(topic, includingRemote: false, confirmed: [.deleteRemoteBranch])
        #expect(!(try await teamHasBranch("topic")))
        #expect(try await teamHasBranch("feature"))

        try await fixture.model.branches.delete(try fixture.branch("feature"), includingRemote: true, confirmed: [.deleteBranch])
        #expect(!(try await teamHasBranch("feature")))
        #expect(!(try await localBranchNames(fixture).contains("feature")))
        #expect(try await remoteHasBranch(fixture, "main"))
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
