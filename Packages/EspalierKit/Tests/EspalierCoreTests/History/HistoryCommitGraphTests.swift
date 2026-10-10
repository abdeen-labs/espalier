// History writes git's commit-graph file when a repository has none.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("History commit-graph", .offline) @MainActor
struct HistoryCommitGraphTests {
    private func chainPath(_ repository: Repository) -> String {
        POSIXPath.join(repository.path, ".git", "objects", "info", "commit-graphs", "commit-graph-chain")
    }

    @Test("writes a commit-graph once when History opens on a repository without one")
    func writesOnce() async throws {
        try await withIsolatedGitConfig { _ in
            let local = try await setupTwoCommitRepo()
            let harness = try AppHarness(writesCommitGraphs: true)
            let app = await harness.loadedApp()
            let model = try await harness.addAndSelect(local, to: app)
            #expect(try await !hasCommitGraph(local))

            model.history.activate()
            await model.idle()
            #expect(try await hasCommitGraph(local))
            let written = try FileManager.default.attributesOfItem(atPath: chainPath(local))[.modificationDate] as? Date

            // Opening History again writes nothing more.
            try await runGit(["commit-graph", "write", "--reachable", "--split", "--no-progress"], local)
            let rewritten = try FileManager.default.attributesOfItem(atPath: chainPath(local))[.modificationDate] as? Date
            model.history.deactivate()
            model.history.activate()
            await model.idle()
            let after = try FileManager.default.attributesOfItem(atPath: chainPath(local))[.modificationDate] as? Date
            #expect(written != nil)
            #expect(after == rewritten)
            await app.idle()
        }
    }

    @Test("leaves the repository alone when writing commit-graphs is off")
    func off() async throws {
        try await withIsolatedGitConfig { _ in
            let local = try await setupTwoCommitRepo()
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let model = try await harness.addAndSelect(local, to: app)

            model.history.activate()
            await model.idle()
            #expect(try await !hasCommitGraph(local))
            await app.idle()
        }
    }
}
