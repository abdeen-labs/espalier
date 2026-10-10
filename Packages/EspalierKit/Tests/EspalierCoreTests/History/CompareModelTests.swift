// These drive `HistoryModel.compare` and `CompareModel` against real git:
// ahead and behind, mergeability per pair of commits (so one comparison
// never shows another branch's result), the rebase preview, the status
// messages, and refreshes.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import GitKit
import Testing
import TestSupport

@Suite("Compare", .offline) @MainActor
struct CompareModelTests {
    /// `main` checked out with M1 and M2 after the base commit; `feature`
    /// from the base with F1, F2, F3 (clean to merge); `conflict` from the
    /// base changing the line M1 changed.
    private func makeRepository() async throws -> HistoryFixture {
        try await makeHistoryFixture { repository in
            try await commitWithGit(repository, "shared.txt", "base\n", message: "Base")
            try await runGit(["branch", "feature"], repository)
            try await runGit(["branch", "conflict"], repository)
            try await commitWithGit(repository, "shared.txt", "main\n", message: "M1")
            try await commitWithGit(repository, "main.txt", "m2\n", message: "M2")
            try await runGit(["checkout", "-q", "feature"], repository)
            for number in 1...3 {
                try await commitWithGit(repository, "feature\(number).txt", "\(number)\n", message: "F\(number)")
            }
            try await runGit(["checkout", "-q", "conflict"], repository)
            try await commitWithGit(repository, "shared.txt", "conflict\n", message: "C1")
            try await runGit(["checkout", "-q", "main"], repository)
        }
    }

    @Test("compares ahead and behind, lists the direction's commits, and checks the merge")
    func aheadAndBehind() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        let history = fixture.history
        let historySHAs = history.commitSHAs
        let feature = try fixture.branch("feature")

        try await history.compare(with: feature, direction: .behind)
        await fixture.settle()
        #expect(history.mode == .compare(feature, .behind))
        #expect(history.comparison.aheadBehind == AheadBehind(ahead: 2, behind: 3))
        #expect(fixture.summaries == ["F3", "F2", "F1"])
        #expect(history.graph.hasUncommittedWorkRow == false)
        #expect(history.graph.count == 3)
        #expect(history.trunkTip == feature.tip.sha)
        #expect(history.graphChange.kind == .reload)
        #expect(history.selection.shas == [feature.tip.sha])
        #expect(history.comparison.mergeStatus == .clean)
        #expect(history.comparison.behindTitle == "Behind (3)")
        #expect(history.comparison.aheadTitle == "Ahead (2)")
        #expect(history.comparison.statusMessage == "This will merge 3 commits from feature into main")
        #expect(history.comparison.canStart)

        try await history.compare(with: feature, direction: .ahead)
        await fixture.settle()
        #expect(history.mode == .compare(feature, .ahead))
        #expect(fixture.summaries == ["M2", "M1"])
        #expect(history.comparison.mergeStatus == .clean)

        history.resetToHistoryMode()
        await fixture.settle()
        #expect(history.mode == .history)
        #expect(history.commitSHAs == historySHAs)
        #expect(history.graph.hasUncommittedWorkRow)
        #expect(history.comparison.branch == nil)
        #expect(history.comparison.aheadBehind == nil)
    }

    @Test("merge status is per pair of commits: a newer comparison never shows an older one's result")
    func mergeabilityPerPair() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        let history = fixture.history
        let conflict = try fixture.branch("conflict")
        let feature = try fixture.branch("feature")

        try await history.compare(with: conflict, direction: .behind)
        await fixture.settle()
        #expect(history.comparison.mergeStatus == .conflicts(conflictedFiles: 1))
        #expect(history.comparison.statusMessage == "There will be 1 conflicted file when merging conflict into main")
        #expect(history.comparison.canStart)

        // Start comparing with the conflicting branch, then with the clean
        // one before the first finishes.
        history.resetToHistoryMode()
        let first = Task { try? await history.compare(with: conflict, direction: .behind) }
        // Let the first comparison start (it does before its first await).
        for _ in 0..<1_000 where history.comparison.branch?.name != "conflict" {
            await Task.yield()
        }
        #expect(history.comparison.branch?.name == "conflict")
        #expect(history.comparison.isLoading)
        try await history.compare(with: feature, direction: .behind)
        await first.value
        await fixture.settle()
        #expect(history.mode == .compare(feature, .behind))
        #expect(history.comparison.branch?.name == "feature")
        #expect(history.comparison.mergeStatus == .clean)
        #expect(fixture.summaries == ["F3", "F2", "F1"])

        // The first comparison landed and its merge check is still running
        // when the second starts.
        history.resetToHistoryMode()
        try await history.compare(with: conflict, direction: .behind)
        #expect(history.comparison.mergeStatus == .loading)
        try await history.compare(with: feature, direction: .behind)
        await fixture.settle()
        #expect(history.comparison.mergeStatus == .clean)
    }

    @Test("nothing to merge when the current branch isn't behind")
    func notBehind() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        try await fixture.git(["branch", "old", "main~1"])
        await fixture.refresh()
        let old = try fixture.branch("old")

        try await fixture.history.compare(with: old, direction: .behind)
        await fixture.settle()
        let comparison = fixture.history.comparison
        #expect(comparison.aheadBehind == AheadBehind(ahead: 1, behind: 0))
        #expect(comparison.mergeStatus == nil)
        #expect(comparison.statusMessage == nil)
        #expect(comparison.canStart == false)
        #expect(fixture.history.commitSHAs.isEmpty)
        #expect(comparison.emptyListMessage == "Your branch is up to date with the compared branch (old)")

        try await fixture.history.compare(with: old, direction: .ahead)
        #expect(fixture.summaries == ["M2"])
    }

    @Test("unrelated histories can't be merged")
    func unrelatedHistories() async throws {
        let fixture = try await makeRepository()
        try await fixture.git(["checkout", "-q", "--orphan", "unrelated"])
        try await fixture.git(["rm", "-q", "-r", "--cached", "."])
        try await fixture.commit("other.txt", "other\n", message: "Unrelated")
        try await fixture.git(["checkout", "-q", "-f", "main"])
        await fixture.refresh()
        await fixture.activate()

        try await fixture.history.compare(with: try fixture.branch("unrelated"), direction: .behind)
        await fixture.settle()
        let comparison = fixture.history.comparison
        #expect(comparison.mergeStatus == .invalid)
        #expect(comparison.statusMessage == "These branches have unrelated histories and can't be merged")
        #expect(comparison.canStart == false)
    }

    @Test("the rebase preview says what a rebase would apply")
    func rebasePreview() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        let feature = try fixture.branch("feature")
        try await fixture.history.compare(with: feature, direction: .behind)
        await fixture.settle()
        let comparison = fixture.history.comparison

        comparison.method = .rebase
        #expect(comparison.rebasePreview == .loading)
        await fixture.settle()
        guard case .clean(let commitsAhead, let commitsBehind)? = comparison.rebasePreview else {
            Issue.record("Expected a clean rebase preview, got \(String(describing: comparison.rebasePreview))")
            return
        }
        #expect(commitsAhead.map(\.summary) == ["M1", "M2"])
        #expect(commitsBehind.map(\.summary) == ["F1", "F2", "F3"])
        #expect(comparison.commitCount == 2)
        #expect(comparison.statusMessage == "This will update main by applying its 2 commits on top of feature")
        #expect(comparison.canStart)

        comparison.method = .squashMerge
        #expect(comparison.statusMessage == "This will merge 3 commits from feature into main")
    }

    @Test("the status while the merge check and the rebase preview load, and the empty list's message")
    func copy() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        let comparison = fixture.history.comparison

        let feature = try fixture.branch("feature")
        try await fixture.history.compare(with: feature, direction: .behind)
        // The merge status is worked out after the comparison lands.
        #expect(comparison.mergeStatus == .loading)
        #expect(comparison.statusMessage == "Checking whether Git can merge automatically…")
        comparison.method = .squashMerge
        #expect(comparison.statusMessage == "Checking whether Git can squash automatically…")
        // A rebase's commits are counted from its preview, so nothing shows
        // while it loads.
        comparison.method = .rebase
        #expect(comparison.rebasePreview == .loading)
        #expect(comparison.statusMessage == nil)
        #expect(comparison.canStart == false)
        await fixture.settle()
        #expect(comparison.mergeStatus == .clean)
        comparison.method = .merge

        try await fixture.history.compare(with: feature, direction: .ahead)
        #expect(comparison.direction == .ahead)
        try await fixture.git(["branch", "same", "main"])
        await fixture.refresh()
        try await fixture.history.compare(with: try fixture.branch("same"), direction: .ahead)
        #expect(comparison.emptyListMessage == "The compared branch (same) is up to date with your branch")
    }

    @Test("a refresh compares again when either branch moved, and returns to history when the branch is gone")
    func refresh() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        let history = fixture.history
        try await history.compare(with: try fixture.branch("feature"), direction: .behind)
        await fixture.settle()
        #expect(history.comparison.aheadBehind == AheadBehind(ahead: 2, behind: 3))

        // A refresh with nothing changed keeps everything.
        let generation = history.graphChange.generation
        await fixture.refresh()
        #expect(history.graphChange.generation == generation)

        // The compared branch moves.
        try await fixture.git(["checkout", "-q", "feature"])
        try await fixture.commit("feature4.txt", "4\n", message: "F4")
        try await fixture.git(["checkout", "-q", "main"])
        await fixture.refresh()
        #expect(history.comparison.aheadBehind == AheadBehind(ahead: 2, behind: 4))
        #expect(fixture.summaries == ["F4", "F3", "F2", "F1"])
        #expect(history.comparison.branch?.tip.sha == (try await fixture.sha("feature")))
        #expect(history.comparison.mergeStatus == .clean)

        // The compared branch is deleted.
        try await fixture.git(["branch", "-q", "-D", "feature"])
        await fixture.refresh()
        #expect(history.mode == .history)
        #expect(history.graph.hasUncommittedWorkRow)
        #expect(history.commitSHAs.contains(try await fixture.sha("main")))
    }

    @Test("the branches to compare with leave out the current branch and fork remotes")
    func comparableBranches() async throws {
        let fixture = try await makeRepository()
        try await fixture.git(["update-ref", "refs/remotes/github-desktop-octocat/feature", "feature"])
        try await fixture.git(["update-ref", "refs/remotes/origin/main", "main"])
        await fixture.refresh()
        let history = fixture.history

        #expect(history.comparableBranches.map(\.name).sorted() == ["conflict", "feature", "origin/main"])
        #expect(history.recentComparableBranches.map(\.name).contains("main") == false)
        // On main, the default branch isn't offered separately.
        #expect(history.defaultComparableBranch == nil)

        try await fixture.git(["checkout", "-q", "feature"])
        await fixture.refresh()
        #expect(history.defaultComparableBranch?.name == "main")
        #expect(history.comparableBranches.map(\.name).sorted() == ["conflict", "main", "origin/main"])
        #expect(history.recentComparableBranches.map(\.name).contains("feature") == false)
    }

    @Test("comparing needs a branch with commits")
    func detachedHEAD() async throws {
        let fixture = try await makeRepository()
        try await fixture.git(["checkout", "-q", "--detach", "main"])
        await fixture.refresh()
        let error = await #expect(throws: OperationError.self) {
            try await fixture.history.compare(with: try fixture.branch("feature"), direction: .behind)
        }
        #expect(error?.reason == .precondition("There is no current branch to compare with."))
        #expect(error?.operation == .loadHistory)
        #expect(fixture.history.mode == .history)
    }

    @Test("a checkout returns to the history")
    func checkoutResetsCompare() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        let feature = try fixture.branch("feature")
        try await fixture.history.compare(with: feature, direction: .behind)
        #expect(fixture.history.mode == .compare(feature, .behind))

        _ = try await fixture.model.branches.checkout(feature)
        await fixture.settle()
        #expect(fixture.history.mode == .history)
        #expect(fixture.history.commitSHAs.contains(feature.tip.sha))
        #expect(fixture.history.selection.shas == [feature.tip.sha])
    }
}
