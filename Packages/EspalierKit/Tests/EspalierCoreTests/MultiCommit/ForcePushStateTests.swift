// `getCurrentBranchForcePushState`'s cases, then the model's force-push
// list against a real diverged branch: recorded with the remote branch's
// tip, kept through more commits and a relaunch, and ended once the remote
// branch moves.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import GitKit
import Testing
import TestSupport

@Suite("Force push state")
struct ForcePushStateTests {
    let branch = ModelFixtures.branch("feature", sha: "new-tip", upstream: "origin/feature")

    @Test("not available without an upstream or without diverging")
    func notAvailable() {
        let tip = Tip.valid(branch: branch)
        let rewritten = ["feature": "remote-tip"]
        for aheadBehind in [nil, AheadBehind(ahead: 2, behind: 0), AheadBehind(ahead: 0, behind: 3)] {
            #expect(getCurrentBranchForcePushState(tip: tip, forcePushBranches: rewritten, upstreamTip: "remote-tip", aheadBehind: aheadBehind) == .notAvailable)
        }
    }

    @Test("recommended while the remote branch is where it was when Espalier rewrote the branch, else available")
    func diverged() {
        let diverged = AheadBehind(ahead: 2, behind: 1)
        let tip = Tip.valid(branch: branch)
        let rewritten = ["feature": "remote-tip"]
        #expect(getCurrentBranchForcePushState(tip: tip, forcePushBranches: rewritten, upstreamTip: "remote-tip", aheadBehind: diverged) == .recommended)
        // The remote branch moved since, or isn't known yet.
        #expect(getCurrentBranchForcePushState(tip: tip, forcePushBranches: rewritten, upstreamTip: "newer-remote-tip", aheadBehind: diverged) == .available)
        #expect(getCurrentBranchForcePushState(tip: tip, forcePushBranches: rewritten, upstreamTip: nil, aheadBehind: diverged) == .available)
        #expect(getCurrentBranchForcePushState(tip: tip, forcePushBranches: [:], upstreamTip: "remote-tip", aheadBehind: diverged) == .available)
        #expect(getCurrentBranchForcePushState(tip: .detached(currentSha: "new-tip"), forcePushBranches: rewritten, upstreamTip: "remote-tip", aheadBehind: diverged) == .available)
    }

    /// A selected repository whose `main` was pushed, then amended with git:
    /// diverged from `origin/main` by one commit each way. Returns the
    /// pushed commit.
    @MainActor
    private func makeAmendedRepository() async throws -> (fixture: SelectedRepository, pushed: String) {
        let fixture = try await makeSelectedRepository()
        try await runGit(["push", "-q", "origin", "main"], fixture.local)
        let pushed = try await fixture.head()
        try await runGit(["commit", "-q", "--amend", "-m", "Amended"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 1, behind: 1))
        return (fixture, pushed)
    }

    @Test("the model records rewrites with the remote branch's tip, forgets them after a force push, and keeps them across a rename", .offline)
    @MainActor
    func model() async throws {
        let (fixture, pushed) = try await makeAmendedRepository()
        let operations = fixture.model.operations
        #expect(operations.forcePushState == .available)

        let main = try #require(fixture.model.gitState.tip.branch)
        await operations.recordRewrite(of: main, previousTip: pushed, upstreamTip: pushed)
        #expect(operations.rewrittenBranches == ["main": pushed])
        #expect(operations.forcePushState == .recommended)

        // An unchanged tip isn't a rewrite, and a branch without an upstream
        // has nothing to force push over.
        await operations.recordRewrite(of: ModelFixtures.branch("other", sha: "same"), previousTip: "same", upstreamTip: "remote")
        await operations.recordRewrite(of: ModelFixtures.branch("unpublished", sha: "new"), previousTip: "old", upstreamTip: nil)
        #expect(operations.rewrittenBranches == ["main": pushed])

        // A rewrite of a branch that didn't have its remote branch's tip
        // (behind it already) records nothing, and drops the record.
        await operations.recordRewrite(of: ModelFixtures.branch("main", sha: "newer"), previousTip: main.tip.sha, upstreamTip: pushed)
        #expect(operations.rewrittenBranches.isEmpty)
        await operations.recordRewrite(of: main, previousTip: pushed, upstreamTip: pushed)

        operations.forgetRewrite(of: main)
        #expect(operations.rewrittenBranches.isEmpty)
        #expect(operations.forcePushState == .available)

        // Renaming the branch keeps its entry.
        await operations.recordRewrite(of: main, previousTip: pushed, upstreamTip: pushed)
        try await fixture.model.branches.rename(main, to: "renamed")
        #expect(operations.rewrittenBranches == ["renamed": pushed])
        #expect(fixture.model.gitState.tip.branch?.name == "renamed")
        #expect(operations.forcePushState == .recommended)
        await fixture.app.idle()
    }

    @Test("an amend records the remote branch's tip from when amending started: a push fetched meanwhile recommends nothing", .offline)
    @MainActor
    func amendRecordsTipAtStart() async throws {
        let fixture = try await makeSelectedRepository()
        let pushed = try await fixture.head()
        let commit = fixture.model.commit
        try await commit.startAmending(confirmed: [.rewritePublishedCommits])

        try await pushCommitFromAnotherClone(fixture.remote, path: "theirs.txt", contents: "theirs\n")
        try await runGit(["fetch", "-q"], fixture.local)
        await fixture.model.refresh(.full, reason: .user)
        #expect(commit.amending?.sha == pushed)

        try fixture.harness.write("mine.txt", "mine\n", in: fixture.local)
        await fixture.model.refresh(.status, reason: .user)
        commit.draft.summary = "Amended"
        #expect(try await commit.commit().amended)

        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 1, behind: 2))
        #expect(fixture.model.operations.rewrittenBranches == ["main": pushed])
        #expect(fixture.model.operations.forcePushState == .available)
        await fixture.app.idle()
    }

    @Test("the recommendation survives more commits and a relaunch, and ends once a fetch shows the remote branch moved", .offline, .hangGuard(minutes: 5))
    @MainActor
    func survivesCommitsAndRelaunch() async throws {
        let (fixture, pushed) = try await makeAmendedRepository()
        let id = fixture.model.id
        let main = try #require(fixture.model.gitState.tip.branch)
        await fixture.model.operations.recordRewrite(of: main, previousTip: pushed, upstreamTip: pushed)

        // One more commit keeps it.
        try await commitFile(fixture.local, "more.txt", "more\n")
        await fixture.model.refresh(.full, reason: .user)
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 2, behind: 1))
        #expect(fixture.model.operations.forcePushState == .recommended)
        #expect(fixture.model.sync.action == .forcePush(remote: "origin", aheadBehind: AheadBehind(ahead: 2, behind: 1), tagsToPush: 0))

        // So does quitting and launching again.
        await fixture.app.idle()
        let relaunched = await fixture.harness.loadedApp()
        relaunched.select(.repository(id))
        await relaunched.idle()
        let model = try #require(relaunched.repository(id))
        #expect(model.operations.rewrittenBranches == ["main": pushed])
        #expect(model.operations.forcePushState == .recommended)
        #expect(model.sync.action == .forcePush(remote: "origin", aheadBehind: AheadBehind(ahead: 2, behind: 1), tagsToPush: 0))

        // Someone else pushes; a pushed commit not fetched yet changes
        // nothing, the fetch ends the recommendation, for good.
        try await pushCommitFromAnotherClone(fixture.remote, path: "theirs.txt", contents: "theirs\n")
        await model.refresh(.full, reason: .user)
        #expect(model.operations.forcePushState == .recommended)
        try await runGit(["fetch", "-q"], fixture.local)
        await model.refresh(.full, reason: .user)
        #expect(model.gitState.aheadBehind == AheadBehind(ahead: 2, behind: 2))
        #expect(model.operations.forcePushState == .available)
        #expect(model.operations.rewrittenBranches.isEmpty)
        await relaunched.idle()
        let launchedAgain = await fixture.harness.loadedApp()
        #expect(launchedAgain.record(id)?.rewrittenBranches == [:])
        await launchedAgain.idle()
    }
}
