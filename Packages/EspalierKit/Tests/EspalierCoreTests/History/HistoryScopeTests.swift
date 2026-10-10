// History's scopes: HEAD's commits, every local branch with its upstream
// (the default), or every branch and tag; the trunk is the default
// branch's line, or its merge base with HEAD when the history doesn't show
// the default branch's commit.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import GitKit
import Testing
import TestSupport

@Suite("History scope", .offline) @MainActor
struct HistoryScopeTests {
    /// `main` (A, B; checked out), `feature` from A (F1), `topic` from B (T1)
    /// whose upstream `origin/topic` has T2 too, `origin/other` (O1) that no
    /// local branch tracks, an annotated tag on a commit no branch has (D1),
    /// and a tag on a tree.
    private func makeRepository() async throws -> (HistoryFixture, [String: String]) {
        var shas: [String: String] = [:]
        let fixture = try await makeHistoryFixture { repository in
            shas["A"] = try await commitWithGit(repository, "a.txt", "a\n", message: "A")
            shas["B"] = try await commitWithGit(repository, "b.txt", "b\n", message: "B")
            try await runGit(["checkout", "-q", "-b", "feature", shas["A"]!], repository)
            shas["F1"] = try await commitWithGit(repository, "f.txt", "f\n", message: "F1")
            try await runGit(["checkout", "-q", "-b", "topic", "main"], repository)
            shas["T1"] = try await commitWithGit(repository, "t.txt", "t1\n", message: "T1")
            shas["T2"] = try await commitWithGit(repository, "t.txt", "t2\n", message: "T2")
            try await runGit(["update-ref", "refs/remotes/origin/topic", "HEAD"], repository)
            try await runGit(["reset", "-q", "--hard", "HEAD~1"], repository)
            try await runGit(["remote", "add", "origin", "/nonexistent/origin"], repository)
            try await runGit(["config", "branch.topic.remote", "origin"], repository)
            try await runGit(["config", "branch.topic.merge", "refs/heads/topic"], repository)
            try await runGit(["checkout", "-q", "--detach", "main"], repository)
            shas["O1"] = try await commitWithGit(repository, "o.txt", "o\n", message: "O1")
            try await runGit(["update-ref", "refs/remotes/origin/other", "HEAD"], repository)
            try await runGit(["checkout", "-q", "--detach", "main"], repository)
            shas["D1"] = try await commitWithGit(repository, "d.txt", "d\n", message: "D1")
            try await runGit(["tag", "-a", "-m", "Dangling", "dangling", "HEAD"], repository)
            try await runGit(["tag", "tree", "main^{tree}"], repository)
            try await runGit(["checkout", "-q", "main"], repository)
        }
        return (fixture, shas)
    }

    private func loadedSummaries(_ fixture: HistoryFixture) -> Set<String> {
        Set(fixture.summaries)
    }

    @Test("Current Branch shows HEAD's commits")
    func currentBranch() async throws {
        let (fixture, _) = try await makeRepository()
        fixture.history.setScope(.currentBranch)
        await fixture.activate()

        #expect(fixture.summaries == ["B", "A"])
        #expect(fixture.history.isComplete)
    }

    @Test("Local Branches, the default, adds every local branch and its upstream")
    func localBranches() async throws {
        let (fixture, shas) = try await makeRepository()
        #expect(fixture.history.scope == .localBranches)
        await fixture.activate()

        #expect(loadedSummaries(fixture) == ["A", "B", "F1", "T1", "T2"])
        // Parents come after their children.
        let rows = Dictionary(uniqueKeysWithValues: fixture.history.commitSHAs.enumerated().map { ($1, $0) })
        #expect(rows[shas["T2"]!]! < rows[shas["T1"]!]!)
        #expect(rows[shas["T1"]!]! < rows[shas["B"]!]!)
        #expect(rows[shas["F1"]!]! < rows[shas["A"]!]!)
    }

    @Test("All Branches adds remote branches and tags, and ignores tags of trees")
    func allBranches() async throws {
        let (fixture, _) = try await makeRepository()
        fixture.history.setScope(.allBranches)
        await fixture.activate()

        #expect(loadedSummaries(fixture) == ["A", "B", "F1", "T1", "T2", "O1", "D1"])
    }

    @Test("changing the scope reloads at once and is remembered for the repository")
    func scopeIsRemembered() async throws {
        let (fixture, _) = try await makeRepository()
        await fixture.activate()
        let reloadGeneration = fixture.history.graphChange.reloadGeneration

        fixture.history.setScope(.currentBranch)
        #expect(fixture.history.isLoading)
        await fixture.settle()
        #expect(fixture.history.isLoading == false)
        #expect(fixture.summaries == ["B", "A"])
        #expect(fixture.history.graphChange.kind == .reload)
        #expect(fixture.history.graphChange.reloadGeneration == reloadGeneration + 1)
        #expect(fixture.app.record(fixture.model.id)?.historyScope == .currentBranch)

        // A relaunch shows the same scope.
        await fixture.app.idle()
        let relaunched = await fixture.harness.loadedApp()
        let model = try #require(relaunched.repository(fixture.model.id))
        #expect(model.history.scope == .currentBranch)
        #expect(model.record.historyScope == .currentBranch)
    }

    @Test("a branch whose upstream is gone still loads")
    func upstreamGone() async throws {
        let (fixture, _) = try await makeRepository()
        try await fixture.git(["update-ref", "-d", "refs/remotes/origin/topic"])
        await fixture.refresh()
        await fixture.activate()

        #expect(loadedSummaries(fixture) == ["A", "B", "F1", "T1"])
        #expect(fixture.history.loadError == nil)
    }

    @Test("refs at each commit, for capsules")
    func refsAtCommits() async throws {
        let (fixture, shas) = try await makeRepository()
        fixture.history.setScope(.allBranches)
        await fixture.activate()

        #expect(fixture.history.refs(at: shas["B"]!).map(\.name) == ["main"])
        #expect(fixture.history.refs(at: shas["T2"]!).map(\.name) == ["origin/topic"])
        #expect(fixture.history.refs(at: shas["T2"]!).first?.kind == .remoteBranch)
        #expect(fixture.history.refs(at: shas["T1"]!).first?.upstream == "refs/remotes/origin/topic")
        #expect(fixture.history.refs(at: shas["D1"]!) == [
            HistoryRef(kind: .tag, fullName: "refs/tags/dangling", name: "dangling"),
        ])
        #expect(fixture.history.refs(at: shas["A"]!).isEmpty)
    }

    @Test("the trunk is the default branch's line, or its merge base with HEAD")
    func trunk() async throws {
        let (fixture, shas) = try await makeRepository()
        await fixture.activate()
        #expect(fixture.history.trunkTip == shas["B"])
        #expect(fixture.history.graph[fixture.history.row(of: shas["B"]!)!].lane == 0)
        #expect(fixture.history.graph[fixture.history.row(of: shas["A"]!)!].lane == 0)

        // On feature, Current Branch doesn't show main's commit: the trunk is
        // the merge base, so feature's own commit leaves the trunk's lane.
        try await fixture.git(["checkout", "-q", "feature"])
        fixture.history.setScope(.currentBranch)
        await fixture.refresh()
        #expect(fixture.summaries == ["F1", "A"])
        #expect(fixture.history.trunkTip == shas["A"])
        #expect(fixture.history.graph[fixture.history.row(of: shas["A"]!)!].lane == 0)
        #expect(fixture.history.graph[fixture.history.row(of: shas["F1"]!)!].lane == 1)

        // Local Branches shows main's commit again.
        fixture.history.setScope(.localBranches)
        await fixture.settle()
        #expect(fixture.history.trunkTip == shas["B"])
    }

    @Test("without a default branch, HEAD's line is the trunk")
    func noDefaultBranch() async throws {
        let fixture = try await makeHistoryFixture { repository in
            try await runGit(["checkout", "-q", "-b", "work"], repository)
            try await commitWithGit(repository, "a.txt", "a\n", message: "A")
        }
        await fixture.activate()
        #expect(fixture.model.gitState.branches.defaultBranch == nil)
        #expect(fixture.history.trunkTip == (try await fixture.sha("HEAD")))
    }
}
