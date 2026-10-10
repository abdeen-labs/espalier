// A detached HEAD end to end through the models: a commit, a tag, and a
// remote branch checked out; committing there, undoing, branching from it,
// and History and Compare there.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Edge states: detached HEAD", .offline) @MainActor
struct DetachedHeadTests {
    /// `main` with three commits, all pushed to `origin`, and a tag `v1` on
    /// the second.
    private func makeFixture() async throws -> (fixture: ChangesFixture, remote: Repository, shas: [String]) {
        let (local, remote) = try await setupRepositoryWithRemote()
        let fixture = try await ChangesFixture.make(local)
        let first = try await fixture.sha("HEAD")
        let second = try await fixture.gitCommit("two.txt", "two\n", message: "Two")
        let third = try await fixture.gitCommit("three.txt", "three\n", message: "Three")
        try await fixture.git(["tag", "v1", second])
        try await fixture.git(["push", "-q", "origin", "main"])
        await fixture.refresh(.full)
        return (fixture, remote, [first, second, third])
    }

    @Test("a checked-out commit is detached: desktop's commands, History with HEAD, no Compare, and no push or pull")
    func checkedOutCommit() async throws {
        let (fixture, _, shas) = try await makeFixture()
        try await fixture.model.branches.checkout(commit: CommitOneLine(sha: shas[1], summary: "Two"), confirmed: [.checkoutCommit])
        await fixture.settle()

        #expect(fixture.gitState.tip == .detached(currentSha: shas[1]))
        #expect(fixture.gitState.aheadBehind == nil)
        #expect(fixture.gitState.localCommitSHAs.isEmpty)
        #expect(fixture.paths.isEmpty)
        #expect(fixture.exists("two.txt"))
        #expect(!fixture.exists("three.txt"))

        let capabilities = fixture.capabilities
        #expect(capabilities.canCreateBranch)
        #expect(!capabilities.canRenameBranch)
        #expect(!capabilities.canDeleteBranch)
        #expect(!capabilities.canPush)
        #expect(!capabilities.canPull)
        #expect(capabilities.canFetch)
        #expect(!capabilities.canMergeBranch)
        #expect(!capabilities.canSquashAndMergeBranch)
        #expect(!capabilities.canRebaseBranch)
        #expect(!capabilities.canCompareToBranch)
        #expect(!capabilities.canUpdateFromContributionTarget)
        #expect(capabilities.canShowBranchesList)
        #expect(fixture.commit.canStartAmending)
        #expect(fixture.commit.undoableCommitSHA == nil)

        // History shows HEAD's commit among the local branches' (main is
        // ahead of it), with the tag.
        await fixture.activateHistory()
        #expect(fixture.historySummaries == ["Three", "Two", "Initial commit"])
        #expect(fixture.history.loadError == nil)

        // Compare needs a current branch; Push and Pull say why they can't.
        let main = try fixture.branch("main")
        let compareError = await #expect(throws: OperationError.self) {
            try await fixture.history.compare(with: main, direction: .ahead)
        }
        #expect(compareError?.reason == .precondition("There is no current branch to compare with."))
        let pushError = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.push()
        }
        #expect(pushError?.reason == .precondition("You're on a detached HEAD, not a branch."))
        let pullError = await #expect(throws: OperationError.self) {
            try await fixture.model.sync.pull()
        }
        #expect(pullError?.reason == .precondition("You're on a detached HEAD, not a branch."))

        // Fetching works.
        try await fixture.model.sync.fetch()
        await fixture.settle()
        #expect(fixture.gitState.tip == .detached(currentSha: shas[1]))
    }

    @Test("committing on a detached HEAD moves only HEAD; it can be undone, amended, and kept on a new branch")
    func commitOnDetachedHead() async throws {
        let (fixture, _, shas) = try await makeFixture()
        try await fixture.git(["checkout", "-q", "--detach", shas[1]])
        await fixture.refresh(.full)

        try fixture.write("detached.txt", "work\n")
        await fixture.refresh()
        fixture.changes.setIncludeAll(true)
        let work = try await fixture.commitIncluded("Detached work")
        await fixture.refresh(.full)
        #expect(fixture.gitState.tip == .detached(currentSha: work.sha))
        #expect(try await fixture.sha("main") == shas[2])
        #expect(fixture.gitState.localCommitSHAs == [work.sha])
        #expect(fixture.commit.undoableCommitSHA == work.sha)
        let workCommit = try #require(try await getCommit(fixture.local, work.sha))
        #expect(workCommit.parentSHAs == [shas[1]])

        // History shows the detached commit, which no branch has.
        await fixture.activateHistory()
        #expect(fixture.history.commitSHAs.contains(work.sha))
        #expect(fixture.history.isLocalCommit(work.sha))

        // Undo puts the change back.
        try await fixture.commit.undo(workCommit)
        await fixture.settle()
        #expect(fixture.gitState.tip == .detached(currentSha: shas[1]))
        #expect(fixture.paths == ["detached.txt"])
        #expect(fixture.commit.draft.summary == "Detached work")

        // Commit again, then amend (no force push to warn about on a
        // detached HEAD).
        fixture.changes.setIncludeAll(true)
        _ = try await fixture.commitIncluded("Detached work")
        try await fixture.commit.startAmending()
        try fixture.write("detached.txt", "work, amended\n")
        await fixture.refresh()
        fixture.changes.setIncludeAll(true)
        let amended = try await fixture.commitIncluded("Detached work, amended")
        await fixture.refresh(.full)
        #expect(fixture.gitState.tip == .detached(currentSha: amended.sha))
        #expect(try await fixture.commitCount() == 3)

        // A new branch keeps it, and a change comes along.
        try fixture.write("later.txt", "later\n")
        await fixture.refresh()
        let rescue = try await fixture.model.branches.createBranch("rescue", startPoint: nil)
        await fixture.settle()
        #expect(rescue.tip.sha == amended.sha)
        #expect(fixture.gitState.tip.branch?.name == "rescue")
        #expect(fixture.gitState.tip.sha == amended.sha)
        #expect(fixture.paths == ["later.txt"])
        #expect(fixture.capabilities.canPush)
        #expect(fixture.capabilities.canCompareToBranch)

        // And Compare works from it.
        try await fixture.history.compare(with: try fixture.branch("main"), direction: .ahead)
        await fixture.settleHistory()
        #expect(fixture.history.comparison.aheadBehind == AheadBehind(ahead: 1, behind: 1))
    }

    @Test("a tag checked out with git is detached at its commit; switching to a branch brings changes along")
    func checkedOutTag() async throws {
        let (fixture, _, shas) = try await makeFixture()
        try await fixture.git(["checkout", "-q", "v1"])
        try fixture.write("README.md", "# Edited on the tag\n")
        await fixture.refresh(.full)

        #expect(fixture.gitState.tip == .detached(currentSha: shas[1]))
        #expect(fixture.gitState.tags?["v1"] == shas[1])
        #expect(fixture.paths == ["README.md"])

        // On a detached HEAD changes always come along, without asking.
        let main = try fixture.branch("main")
        #expect(try await fixture.model.branches.checkout(main, strategy: .askForConfirmation) == .checkedOut(main))
        await fixture.settle()
        #expect(fixture.gitState.tip.branch?.name == "main")
        #expect(fixture.paths == ["README.md"])
        #expect(fixture.read("README.md") == "# Edited on the tag\n")
        #expect(try await fixture.stashList().isEmpty)
    }

    @Test("a remote branch checked out with git is detached; checking it out in Espalier makes a tracking branch")
    func checkedOutRemoteBranch() async throws {
        let (fixture, remote, _) = try await makeFixture()
        let other = try await cloneRepository(remote)
        try await runGit(["checkout", "-q", "-b", "feature"], other)
        try Data("feature\n".utf8).write(to: URL(filePath: POSIXPath.join(other.path, "feature.txt")))
        try await runGit(["add", "feature.txt"], other)
        try await runGit(["commit", "-q", "-m", "Feature"], other)
        try await runGit(["push", "-q", "origin", "feature"], other)
        try await fixture.model.sync.fetch()
        await fixture.settle()

        let featureTip = try await fixture.sha("origin/feature")
        try await fixture.git(["checkout", "-q", "--detach", "origin/feature"])
        await fixture.refresh(.full)
        #expect(fixture.gitState.tip == .detached(currentSha: featureTip))
        let remoteFeature = try fixture.branch("origin/feature")
        #expect(remoteFeature.type == .remote)

        #expect(try await fixture.model.branches.checkout(remoteFeature) == .checkedOut(remoteFeature))
        await fixture.settle()
        #expect(fixture.gitState.tip.branch?.name == "feature")
        #expect(fixture.gitState.tip.branch?.upstream == "origin/feature")
        #expect(fixture.gitState.aheadBehind == AheadBehind(ahead: 0, behind: 0))
    }

    @Test("leaving commits only a detached HEAD has asks first; commits a branch, tag, remote branch, or the target has don't")
    func leavingCommitsBehind() async throws {
        let (fixture, _, shas) = try await makeFixture()
        try await fixture.git(["checkout", "-q", "--detach", shas[1]])
        await fixture.refresh(.full)
        let main = try fixture.branch("main")

        // Nothing to leave behind: HEAD is on main (and tagged).
        #expect(try await fixture.model.branches.checkout(main) == .checkedOut(main))
        try await fixture.git(["checkout", "-q", "--detach", shas[1]])
        await fixture.refresh(.full)

        // Two commits made there.
        let one = try await fixture.gitCommit("one.txt", "one\n", message: "One")
        let two = try await fixture.gitCommit("two-more.txt", "two\n", message: "Two more")
        await fixture.refresh(.full)

        let error = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.checkout(main)
        }
        let asked = try #require(confirmation(of: error))
        #expect(asked == .leaveCommitsBehind(count: 2, sha: two))
        #expect(asked.title == "Leave 2 Commits Behind?")
        #expect(fixture.gitState.tip == .detached(currentSha: two))

        // Checking out the first of them leaves only the second behind; its
        // own commit isn't asked about.
        let commitError = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.checkout(commit: CommitOneLine(sha: one, summary: "One"), confirmed: [.checkoutCommit])
        }
        #expect(confirmation(of: commitError) == .leaveCommitsBehind(count: 1, sha: two))

        // A tag keeps them: nothing to ask.
        try await fixture.git(["tag", "kept", two])
        await fixture.refresh(.full)
        #expect(try await fixture.model.branches.checkout(main) == .checkedOut(main))
        await fixture.settle()
        #expect(fixture.gitState.tip.branch?.name == "main")

        // Confirmed, the commits are left behind.
        try await fixture.git(["checkout", "-q", "--detach", shas[2]])
        let lost = try await fixture.gitCommit("lost.txt", "lost\n", message: "Lost")
        await fixture.refresh(.full)
        let lostError = await #expect(throws: OperationError.self) {
            try await fixture.model.branches.checkout(main)
        }
        #expect(confirmation(of: lostError) == .leaveCommitsBehind(count: 1, sha: lost))
        #expect(try await fixture.model.branches.checkout(main, confirmed: [.leaveCommitsBehind]) == .checkedOut(main))
        await fixture.settle()
        #expect(fixture.gitState.tip.branch?.name == "main")
        #expect(!fixture.exists("lost.txt"))
    }
}
