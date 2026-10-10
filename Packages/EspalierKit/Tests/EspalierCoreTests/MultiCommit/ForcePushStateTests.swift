// `getCurrentBranchForcePushState`'s cases, then the model's force-push
// list against a real diverged branch.

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
        let rewritten = ["feature": "new-tip"]
        #expect(getCurrentBranchForcePushState(tip: tip, forcePushBranches: rewritten, aheadBehind: nil) == .notAvailable)
        #expect(getCurrentBranchForcePushState(tip: tip, forcePushBranches: rewritten, aheadBehind: AheadBehind(ahead: 2, behind: 0)) == .notAvailable)
        #expect(getCurrentBranchForcePushState(tip: tip, forcePushBranches: rewritten, aheadBehind: AheadBehind(ahead: 0, behind: 3)) == .notAvailable)
    }

    @Test("recommended when Espalier rewrote the branch to its current tip, else available")
    func diverged() {
        let diverged = AheadBehind(ahead: 2, behind: 1)
        let tip = Tip.valid(branch: branch)
        #expect(getCurrentBranchForcePushState(tip: tip, forcePushBranches: ["feature": "new-tip"], aheadBehind: diverged) == .recommended)
        // Committed again since the rewrite.
        #expect(getCurrentBranchForcePushState(tip: tip, forcePushBranches: ["feature": "older-tip"], aheadBehind: diverged) == .available)
        #expect(getCurrentBranchForcePushState(tip: tip, forcePushBranches: [:], aheadBehind: diverged) == .available)
        #expect(getCurrentBranchForcePushState(tip: .detached(currentSha: "new-tip"), forcePushBranches: ["feature": "new-tip"], aheadBehind: diverged) == .available)
    }

    @Test("the model records rewrites, forgets them after a force push, and keeps them across a rename", .offline)
    @MainActor
    func model() async throws {
        let fixture = try await makeSelectedRepository()
        let operations = fixture.model.operations
        // Rewrite main after pushing it: amend the pushed commit.
        try await runGit(["push", "-q", "origin", "main"], fixture.local)
        let pushed = try await fixture.head()
        try await runGit(["commit", "-q", "--amend", "-m", "Amended"], fixture.local)
        try await commitFile(fixture.local, "more.txt", "more\n")
        await fixture.model.refresh(.full, reason: .user)
        #expect(fixture.model.gitState.aheadBehind == AheadBehind(ahead: 2, behind: 1))
        #expect(operations.forcePushState == .available)

        let main = try #require(fixture.model.gitState.tip.branch)
        operations.recordRewrite(of: main, previousTip: pushed)
        #expect(operations.rewrittenBranches == ["main": main.tip.sha])
        #expect(operations.forcePushState == .recommended)

        // An unchanged tip isn't a rewrite.
        operations.recordRewrite(of: ModelFixtures.branch("other", sha: "same"), previousTip: "same")
        #expect(operations.rewrittenBranches == ["main": main.tip.sha])

        operations.forgetRewrite(of: main)
        #expect(operations.rewrittenBranches.isEmpty)
        #expect(operations.forcePushState == .available)

        // Renaming the branch keeps its entry.
        operations.recordRewrite(of: main, previousTip: pushed)
        try await fixture.model.branches.rename(main, to: "renamed")
        #expect(operations.rewrittenBranches == ["renamed": main.tip.sha])
        #expect(fixture.model.gitState.tip.branch?.name == "renamed")
        await fixture.app.idle()
    }
}
