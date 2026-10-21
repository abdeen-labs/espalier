// The sidebar's first comparison of branches with their upstreams writes
// git's commit-graph file when the repository has none
// (RepositoryModel+CommitGraph.swift).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Upstream comparisons' commit-graph", .offline, .hangGuard(minutes: 5)) @MainActor
struct UpstreamStatesCommitGraphTests {
    /// Where `git commit-graph write --split` writes.
    private func graphDirectory(_ repository: Repository) -> String {
        POSIXPath.join(repository.path, ".git", "objects", "info", "commit-graphs")
    }

    /// The split commit-graph's list of layers.
    private func chain(_ repository: Repository) throws -> String {
        try String(contentsOfFile: POSIXPath.join(graphDirectory(repository), "commit-graph-chain"), encoding: .utf8)
    }

    /// A repository whose branch `ahead` is a commit ahead of its upstream,
    /// prepared by `prepare`, selected in an app that writes commit-graphs.
    private func makeRepository(_ prepare: (Repository) async throws -> Void = { _ in }) async throws -> SelectedRepository {
        let (local, remote) = try await setupRepositoryWithRemote()
        try await runGit(["checkout", "-b", "ahead"], local)
        try await runGit(["push", "-u", "origin", "ahead"], local)
        try await commitFile(local, "ahead.txt", "ahead\n")
        try await prepare(local)
        let harness = try AppHarness(writesCommitGraphs: true)
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)
        return SelectedRepository(harness: harness, app: app, model: model, local: local, remote: remote)
    }

    /// The state the sidebar shows for `ahead`.
    private func aheadState(_ model: RepositoryModel) -> BranchUpstreamState? {
        model.branches.upstreamStates["refs/heads/ahead"]
    }

    /// Moves `ahead` a commit further, so its row compares it again, and
    /// waits for the comparison.
    private func commitAndCompareAgain(_ selected: SelectedRepository, _ name: String) async throws {
        try await commitFile(selected.local, name, "\(name)\n")
        await selected.model.refresh(.refs, reason: .user)
        await selected.model.branches.upstreamStatesIdle()
        await selected.model.idle()
    }

    @Test("the first comparison writes a commit-graph when the repository has none, and only that one")
    func writesOnce() async throws {
        try await withIsolatedGitConfig { _ in
            let selected = try await makeRepository()
            let model = selected.model
            #expect(try await !hasCommitGraph(selected.local))

            // The row of `ahead` appears.
            model.branches.upstreamStatesLoader.beginWatching(["refs/heads/ahead"])
            await model.branches.upstreamStatesIdle()
            await model.idle()
            #expect(aheadState(model) == .tracking(AheadBehind(ahead: 1, behind: 0)))
            #expect(try await hasCommitGraph(selected.local))

            // With the file gone, the next comparison writes none.
            try FileManager.default.removeItem(atPath: graphDirectory(selected.local))
            try await commitAndCompareAgain(selected, "second.txt")
            #expect(aheadState(model) == .tracking(AheadBehind(ahead: 2, behind: 0)))
            #expect(try await !hasCommitGraph(selected.local))
            await selected.app.idle()
        }
    }

    @Test("a repository that has a commit-graph keeps it as it is")
    func hasOne() async throws {
        try await withIsolatedGitConfig { _ in
            // The commit after the graph isn't in it: writing would add a
            // layer.
            let selected = try await makeRepository { local in
                try await runGit(["commit-graph", "write", "--reachable", "--split", "--no-progress"], local)
                try await commitFile(local, "after.txt", "after\n")
            }
            let model = selected.model
            let before = try chain(selected.local)

            model.branches.upstreamStatesLoader.beginWatching(["refs/heads/ahead"])
            await model.branches.upstreamStatesIdle()
            await model.idle()
            #expect(aheadState(model) == .tracking(AheadBehind(ahead: 2, behind: 0)))
            #expect(try chain(selected.local) == before)
            await selected.app.idle()
        }
    }

    @Test("doesn't start while an operation holds a lane, and the next comparison writes it", arguments: [OperationLanes.local, .network])
    func waitsForOperations(lanes: OperationLanes) async throws {
        try await withIsolatedGitConfig { _ in
            let selected = try await makeRepository()
            let model = selected.model
            let gate = AsyncGate()
            let operation = Task {
                try await model.perform(OperationDescriptor(kind: lanes == .network ? .fetch : .commit, lanes: lanes)) { _ in
                    await gate.wait()
                }
            }
            await waitForState { model.localOperation != nil || model.networkOperation != nil }

            // The comparison runs; the write doesn't start.
            model.branches.upstreamStatesLoader.beginWatching(["refs/heads/ahead"])
            await model.branches.upstreamStatesIdle()
            #expect(aheadState(model) == .tracking(AheadBehind(ahead: 1, behind: 0)))
            gate.open()
            try await operation.value
            await model.idle()
            #expect(try await !hasCommitGraph(selected.local))

            try await commitAndCompareAgain(selected, "second.txt")
            #expect(aheadState(model) == .tracking(AheadBehind(ahead: 2, behind: 0)))
            #expect(try await hasCommitGraph(selected.local))
            await selected.app.idle()
        }
    }
}
