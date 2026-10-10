// History loads while a view showing it is active, and reloads when HEAD,
// the commits the scope starts from, or the trunk change; a refresh that
// changes none of them keeps what's loaded.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import GitKit
import Testing
import TestSupport

@Suite("History refresh", .offline) @MainActor
struct HistoryRefreshTests {
    private func makeRepository() async throws -> HistoryFixture {
        try await makeHistoryFixture { repository in
            try await importLinearHistory(repository, count: 150)
        }
    }

    @Test("history loads only while active")
    func loadsWhileActive() async throws {
        let fixture = try await makeRepository()
        let history = fixture.history
        #expect(history.isActive == false)
        #expect(history.commitSHAs.isEmpty)

        await fixture.refresh()
        #expect(history.commitSHAs.isEmpty)

        await fixture.activate()
        #expect(history.isActive)
        #expect(history.commitSHAs.count == 100)

        // While inactive, refreshes don't reload; activating catches up.
        history.deactivate()
        let commit = try await fixture.commit("new.txt", "new\n", message: "New")
        await fixture.refresh()
        #expect(history.commitSHAs.first != commit)
        await fixture.activate()
        #expect(history.commitSHAs.first == commit)
    }

    @Test("a refresh that changes nothing keeps the list")
    func unchangedRefresh() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        let history = fixture.history
        await history.loadNextPage()
        let change = history.graphChange

        await fixture.refresh()
        try fixture.write("history.txt", "edited\n")
        await fixture.model.refresh(.status, reason: .user)
        await fixture.settle()
        #expect(history.graphChange == change)
        #expect(history.commitSHAs.count == 150)
    }

    @Test("a branch created at a listed commit updates the refs without reloading")
    func newBranchAtListedCommit() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        let history = fixture.history
        let target = try await fixture.sha("main~3")
        let change = history.graphChange
        #expect(history.refs(at: target).isEmpty)

        try await fixture.git(["branch", "topic", target])
        try await fixture.git(["tag", "v1.0", target])
        await fixture.refresh()
        #expect(history.graphChange == change)
        #expect(history.refs(at: target).map(\.name) == ["topic", "v1.0"])
        #expect(history.refs(at: target).map(\.kind) == [.localBranch, .tag])
    }

    @Test("a new branch tip reloads the list with it")
    func newBranchTip() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        let history = fixture.history
        let reloadGeneration = history.graphChange.reloadGeneration

        try await fixture.git(["checkout", "-q", "-b", "topic"])
        let topic = try await fixture.commit("topic.txt", "topic\n", message: "Topic")
        try await fixture.git(["checkout", "-q", "main"])
        await fixture.refresh()
        #expect(history.graphChange.reloadGeneration == reloadGeneration + 1)
        #expect(history.commitSHAs.contains(topic))
        // HEAD is still main: its commit stays selected.
        #expect(history.selection.shas == [try await fixture.sha("main")])
    }

    @Test("deleting a branch reloads the list without its commits")
    func deletedBranch() async throws {
        let fixture = try await makeRepository()
        try await fixture.git(["checkout", "-q", "-b", "topic"])
        let topic = try await fixture.commit("topic.txt", "topic\n", message: "Topic")
        try await fixture.git(["checkout", "-q", "main"])
        await fixture.refresh()
        await fixture.activate()
        let history = fixture.history
        #expect(history.commitSHAs.contains(topic))
        let reloadGeneration = history.graphChange.reloadGeneration

        try await fixture.git(["branch", "-q", "-D", "topic"])
        await fixture.refresh()
        #expect(history.graphChange.reloadGeneration == reloadGeneration + 1)
        #expect(!history.commitSHAs.contains(topic))
        #expect(history.refs(at: topic).isEmpty)
    }

    @Test("a fetch that moves the upstream reloads Local Branches with its commits")
    func upstreamMoves() async throws {
        let (local, remote) = try await setupRepositoryWithRemote()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        let fixture = HistoryFixture(harness: harness, app: app, model: model, local: local)
        await fixture.activate()
        #expect(fixture.summaries == ["Initial commit"])

        let pushed = try await pushCommitFromAnotherClone(remote, path: "other.txt", contents: "other\n", message: "From elsewhere")
        try await fixture.git(["fetch", "-q", "origin"])
        await fixture.refresh()
        #expect(fixture.history.commitSHAs.first == pushed)
        #expect(fixture.history.refs(at: pushed).map(\.name) == ["origin/main"])

        // Current Branch doesn't show it.
        fixture.history.setScope(.currentBranch)
        await fixture.settle()
        #expect(fixture.summaries == ["Initial commit"])
    }

    @Test("deselecting the repository stops the loads and the history")
    func deselect() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        let history = fixture.history

        let otherRepository = try setupEmptyRepository("main")
        try await importLinearHistory(otherRepository, count: 2)
        let otherID = try #require(try await fixture.app.addRepositories([otherRepository.path]).added.first)
        await fixture.settle()

        // A selection whose changes are still loading when another
        // repository is selected.
        let target = try await fixture.sha("main~5")
        history.select(shas: [target], contiguous: true)
        #expect(history.selection.changeset.isLoading)
        fixture.app.select(.repository(otherID))
        #expect(history.isActive == false)
        // What's loaded stays; what was loading stopped.
        #expect(history.commitSHAs.count == 100)
        #expect(history.selection.shas == [target])
        #expect(history.selection.changeset == .idle)
        await history.idle()
        #expect(history.selection.changeset == .idle)

        // Selecting the repository and showing its history again loads them.
        fixture.app.select(.repository(fixture.model.id))
        await fixture.activate()
        #expect(history.selection.changeset.value?.files.map(\.path) == ["history.txt"])
        #expect(history.selection.diff.value != nil)
    }

    @Test("counts the history when the repository has a commit-graph file")
    func commitCount() async throws {
        let fixture = try await makeRepository()
        await fixture.activate()
        #expect(fixture.history.totalCommitCount == nil)

        try await fixture.git(["commit-graph", "write", "--reachable"])
        try await fixture.commit("new.txt", "new\n", message: "New")
        await fixture.refresh()
        #expect(fixture.history.totalCommitCount == 151)
        #expect(fixture.history.commitSHAs.count == 100)
    }
}
