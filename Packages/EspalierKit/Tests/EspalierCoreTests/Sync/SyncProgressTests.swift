// The weighted progress of push (push 0-0.643, fetch -0.9, refreshing
// -0.95), pull (pull 0-0.6, refreshing 0.9-0.95), and fetch (fetch 0-0.9
// shared by the remotes, refreshing 0.9-0.95). The primitives run with a
// context whose progress is recorded.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Sync progress", .offline) @MainActor
struct SyncProgressTests {
    @MainActor
    private final class Recorder {
        var values: [AnyProgress] = []
    }

    /// A context for `kind` whose progress `recorder` records.
    private func makeContext(_ fixture: SelectedRepository, kind: OperationKind, recorder: Recorder) -> OperationContext {
        let relay = ProgressRelay<AnyProgress> { recorder.values.append($0) }
        return OperationContext(
            repository: fixture.local,
            kind: kind,
            isBackgroundTask: false,
            hooks: .none,
            progress: ProgressSink(relay: relay),
            gitHubHTMLURL: nil,
            mainWorktreePath: nil
        )
    }

    /// Lets the relay deliver what's pending.
    private func flush() async {
        for _ in 0..<10 {
            await MainActor.run {}
            await Task.yield()
        }
    }

    private func refreshing(_ values: [AnyProgress]) -> [GenericProgress] {
        values.compactMap { if case .generic(let progress) = $0 { progress } else { nil } }
    }

    /// Whether the refreshing steps came at 0.9 and 0.95 (the weights add up
    /// to 0.8999…, as in JavaScript).
    private func refreshesAtDesktopsValues(_ values: [AnyProgress]) -> Bool {
        let steps = refreshing(values).map(\.value)
        return steps.count == 2 && abs(steps[0] - 0.9) < 1e-9 && abs(steps[1] - 0.95) < 1e-9
    }

    @Test("a push reports the push up to 0.643, the fetch after it up to 0.9, then refreshing")
    func push() async throws {
        let fixture = try await makeSelectedRepository { local in
            try await commitFile(local, "a.txt", String(repeating: "a", count: 10_000))
        }
        let recorder = Recorder()
        let ctx = makeContext(fixture, kind: .push, recorder: recorder)
        let branch = try #require(fixture.model.gitState.tip.branch)
        let remote = try #require(fixture.model.gitState.remotes.currentRemote)

        _ = try await fixture.harness.environment.withRuntimes {
            try await fixture.model.sync.pushPrimitive(branch, to: remote, forceWithLease: false, in: ctx, progress: ctx.progress)
        }
        await flush()

        let values = recorder.values
        let pushWeight = 2.5 / 3.5 * 0.9
        let pushes = values.compactMap { if case .push(let progress) = $0 { progress } else { nil } }
        #expect(!pushes.isEmpty)
        #expect(pushes.allSatisfy { $0.value <= pushWeight + 1e-9 && $0.branch == "main" })
        let fetches = values.compactMap { if case .fetch(let progress) = $0 { progress } else { nil } }
        #expect(!fetches.isEmpty)
        #expect(fetches.allSatisfy { $0.value >= pushWeight - 1e-9 && $0.value <= 0.9 + 1e-9 })
        #expect(refreshesAtDesktopsValues(values))
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.value <= $1.value })
        await fixture.app.idle()
    }

    @Test("a pull reports the pull up to 0.6, then refreshing")
    func pull() async throws {
        let fixture = try await makeSelectedRepository()
        try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: String(repeating: "b", count: 10_000))
        let recorder = Recorder()
        let ctx = makeContext(fixture, kind: .pull, recorder: recorder)
        let remote = try #require(fixture.model.gitState.remotes.currentRemote)

        let outcome = try await fixture.harness.environment.withRuntimes {
            try await pullPrimitive(remote, in: ctx)
        }
        await flush()

        #expect(outcome == .completed)
        let values = recorder.values
        let pulls = values.compactMap { if case .pull(let progress) = $0 { progress } else { nil } }
        #expect(!pulls.isEmpty)
        #expect(pulls.allSatisfy { $0.value <= 0.6 + 1e-9 })
        #expect(refreshesAtDesktopsValues(values))
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.value <= $1.value })
        await fixture.app.idle()
    }

    @Test("a fetch shares 0-0.9 among the remotes, then refreshing")
    func fetch() async throws {
        let fixture = try await makeSelectedRepository()
        let mirror = try await makeBareRemote(from: fixture.remote)
        try await runGit(["remote", "add", "mirror", mirror.path], fixture.local)
        try await pushCommitFromAnotherClone(fixture.remote, path: "other.txt", contents: "other\n")
        let recorder = Recorder()
        let ctx = makeContext(fixture, kind: .fetch, recorder: recorder)

        try await fixture.harness.environment.withRuntimes {
            try await fetchAndFastForward([Remote(name: "origin", url: fixture.remote.path), Remote(name: "mirror", url: mirror.path)], in: ctx)
        }
        await flush()

        let fetches = recorder.values.compactMap { if case .fetch(let progress) = $0 { progress } else { nil } }
        let origin = fetches.filter { $0.remote == "origin" }
        let mirrorProgress = fetches.filter { $0.remote == "mirror" }
        #expect(!origin.isEmpty && !mirrorProgress.isEmpty)
        #expect(origin.allSatisfy { $0.value <= 0.45 + 1e-9 })
        #expect(mirrorProgress.allSatisfy { $0.value >= 0.45 - 1e-9 && $0.value <= 0.9 + 1e-9 })
        #expect(refreshesAtDesktopsValues(recorder.values))
        await fixture.app.idle()
    }
}
