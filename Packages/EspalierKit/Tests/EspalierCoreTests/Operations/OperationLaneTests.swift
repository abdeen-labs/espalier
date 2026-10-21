// The operation lanes and busy policies.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Operation lanes", .hangGuard(minutes: 5)) @MainActor
struct OperationLaneTests {
    let commit = ActiveOperation(kind: .commit)
    let checkout = ActiveOperation(kind: .checkoutBranch)
    let backgroundFetch = ActiveOperation(kind: .fetch, isBackgroundTask: true)
    let prune = ActiveOperation(kind: .pruneBranches, isBackgroundTask: true)

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    @Test("background work skips a taken lane")
    func backgroundSkips() async {
        let lane = OperationLane(name: "network")
        _ = await lane.acquire(for: commit, policy: .user)
        #expect(await lane.acquire(for: backgroundFetch, policy: .background) == .skipped)
        lane.release(commit)

        _ = await lane.acquire(for: prune, policy: .background)
        #expect(await lane.acquire(for: backgroundFetch, policy: .background) == .skipped)
    }

    @Test("a user operation waits behind background work and gets the lane next")
    func userWaitsBehindBackground() async {
        let lane = OperationLane(name: "network")
        _ = await lane.acquire(for: backgroundFetch, policy: .background)
        let waiting = Task { await lane.acquire(for: commit, policy: .user) }
        await settle()
        #expect(lane.holder?.id == backgroundFetch.id)

        // Meanwhile another user operation is busy behind the waiting one,
        // and background work skips.
        #expect(await lane.acquire(for: checkout, policy: .user) == .busy(.commit))
        #expect(await lane.acquire(for: prune, policy: .background) == .skipped)

        lane.release(backgroundFetch)
        #expect(await waiting.value == .acquired)
        #expect(lane.holder?.id == commit.id)
    }

    @Test("a waiting user operation whose task is cancelled gives up")
    func cancelledWaiter() async {
        let lane = OperationLane(name: "network")
        _ = await lane.acquire(for: backgroundFetch, policy: .background)
        let waiting = Task { await lane.acquire(for: commit, policy: .user) }
        await settle()
        waiting.cancel()
        #expect(await waiting.value == .cancelled)
        lane.release(backgroundFetch)
        #expect(lane.isFree)
    }

    @Test("only the holder releases a lane")
    func onlyHolderReleases() async {
        let lane = OperationLane(name: "local")
        _ = await lane.acquire(for: commit, policy: .user)
        lane.release(checkout)
        #expect(lane.holder?.id == commit.id)
    }

    // MARK: Through the runner

    @Test("pull takes the network lane, then the local one, and releases the first when the second is busy")
    func pullTakesBothLanes() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithRemote()
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let repository = try await harness.addAndSelect(local, to: app)

            let gate = AsyncGate()
            let commit = Task {
                try await repository.perform(OperationDescriptor(kind: .commit)) { _ in
                    await gate.wait()
                }
            }
            try await gate.waitUntilWaiting()

            let pull = await #expect(throws: OperationError.self) {
                try await repository.perform(OperationDescriptor(kind: .pull, lanes: [.network, .local])) { _ in }
            }
            #expect(pull?.reason == .busy(.commit))
            #expect(repository.networkLane.isFree)
            #expect(repository.networkOperation == nil)

            gate.open()
            try await commit.value
            let pulled = try await repository.perform(OperationDescriptor(kind: .pull, lanes: [.network, .local])) { _ in
                (repository.localOperation?.kind, repository.networkOperation?.kind, repository.localOperation?.id == repository.networkOperation?.id)
            }
            #expect(pulled.0 == .pull && pulled.1 == .pull && pulled.2)
            await app.idle()
        }
    }

    @Test("worktrees of one repository share the network lane")
    func worktreesShareNetworkLane() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithRemote()
            let worktreePath = try createTempDirectory() + "/linked"
            try await runGit(["worktree", "add", "-b", "linked", worktreePath], local)

            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let main = try await harness.addAndSelect(local, to: app)
            let linked = try await harness.addAndSelect(Repository(path: worktreePath), to: app)
            #expect(main.id != linked.id)
            #expect(main.networkLaneKey == linked.networkLaneKey)
            #expect(main.networkLane === linked.networkLane)
            #expect(main.localLane !== linked.localLane)

            let gate = AsyncGate()
            let fetch = Task {
                try await main.perform(OperationDescriptor(kind: .fetch, lanes: [.network])) { _ in
                    await gate.wait()
                }
            }
            try await gate.waitUntilWaiting()
            let other = await #expect(throws: OperationError.self) {
                try await linked.perform(OperationDescriptor(kind: .fetch, lanes: [.network])) { _ in }
            }
            #expect(other?.reason == .busy(.fetch))
            // Local work in the linked worktree isn't blocked.
            try await linked.perform(OperationDescriptor(kind: .commit)) { _ in }

            gate.open()
            try await fetch.value
            await app.idle()
        }
    }
}
