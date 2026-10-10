// How local branches compare with their upstreams, for the sidebar
// (BranchUpstreamStates.swift): loaded for the rows on screen and cached by
// commit pair.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Branch upstream states", .offline) @MainActor
struct BranchUpstreamStatesTests {
    /// The local branches of the repository's branch list.
    private func localRefs(_ model: RepositoryModel) -> [String] {
        model.gitState.branches.all.filter { $0.type == .local }.map(\.ref)
    }

    @Test("ahead, behind, in sync, gone, and unpublished branches")
    func states() async throws {
        let selected = try await makeSelectedRepository { local in
            // main tracks origin/main and is in sync.
            // ahead: one commit not on its upstream.
            try await runGit(["checkout", "-b", "ahead"], local)
            try await runGit(["push", "-u", "origin", "ahead"], local)
            try await commitFile(local, "ahead.txt", "ahead\n")
            // diverged: one commit each way.
            try await runGit(["checkout", "-b", "diverged", "main"], local)
            try await commitFile(local, "remote.txt", "remote\n")
            try await runGit(["push", "-u", "origin", "diverged"], local)
            try await runGit(["reset", "--hard", "HEAD~1"], local)
            try await commitFile(local, "local.txt", "local\n")
            // gone: its upstream was deleted and pruned.
            try await runGit(["checkout", "-b", "gone", "main"], local)
            try await runGit(["push", "-u", "origin", "gone"], local)
            try await runGit(["push", "origin", "--delete", "gone"], local)
            try await runGit(["fetch", "--prune", "origin"], local)
            // unpublished: no upstream at all.
            try await runGit(["checkout", "-b", "unpublished", "main"], local)
            // local-upstream: tracks the local branch main, one behind.
            try await runGit(["checkout", "-b", "local-upstream", "main"], local)
            try await runGit(["branch", "--set-upstream-to=main"], local)
            try await runGit(["checkout", "main"], local)
            try await commitFile(local, "main.txt", "main\n")
            try await runGit(["push", "origin", "main"], local)
        }
        let branches = selected.model.branches
        branches.upstreamStatesLoader.beginWatching(localRefs(selected.model))
        await branches.upstreamStatesIdle()
        #expect(branches.upstreamStates == [
            "refs/heads/main": .tracking(AheadBehind(ahead: 0, behind: 0)),
            "refs/heads/ahead": .tracking(AheadBehind(ahead: 1, behind: 0)),
            "refs/heads/diverged": .tracking(AheadBehind(ahead: 1, behind: 1)),
            "refs/heads/gone": .gone,
            "refs/heads/local-upstream": .tracking(AheadBehind(ahead: 0, behind: 1)),
        ])
        await selected.app.idle()
    }

    @Test("a refresh compares again only the branches whose commits moved")
    func refreshComparesMoved() async throws {
        let selected = try await makeSelectedRepository { local in
            for name in ["one", "two"] {
                try await runGit(["checkout", "-b", name, "main"], local)
                try await runGit(["push", "-u", "origin", name], local)
                try await commitFile(local, "\(name).txt", "\(name)\n")
            }
            try await runGit(["checkout", "main"], local)
        }
        let model = selected.model
        let host = RecordingHost(model.branches)
        let loader = model.branches.upstreamStatesLoader
        loader.host = host
        loader.reset(keepingCache: false)
        loader.branchesDidChange(model.gitState.branches)
        loader.beginWatching(localRefs(model))
        await loader.idle()
        #expect(host.calls.count == 1)
        #expect(loader.cachedCount == 2)

        // Nothing moved: the cache answers.
        await model.refresh(.refs, reason: .user)
        await loader.idle()
        #expect(host.calls.count == 1)
        #expect(host.states["refs/heads/one"] == .tracking(AheadBehind(ahead: 1, behind: 0)))

        // origin/two gains a commit from another clone.
        let other = try await cloneRepository(selected.remote)
        try await runGit(["checkout", "two"], other)
        try await commitFile(other, "two-remote.txt", "two\n")
        try await runGit(["push", "origin", "two"], other)
        try await runGit(["fetch", "origin"], selected.local)
        await model.refresh(.refs, reason: .user)
        await loader.idle()
        #expect(host.calls.count == 2)
        #expect(host.calls.last == ["refs/heads/two", "refs/remotes/origin/two"])
        #expect(host.states["refs/heads/two"] == .tracking(AheadBehind(ahead: 1, behind: 1)))
        #expect(host.states["refs/heads/one"] == .tracking(AheadBehind(ahead: 1, behind: 0)))
        await selected.app.idle()
    }

    @Test("a row's task watches its branch until it's cancelled")
    func watchTask() async throws {
        let selected = try await makeSelectedRepository { local in
            try await runGit(["checkout", "-b", "one"], local)
            try await runGit(["push", "-u", "origin", "one"], local)
            try await commitFile(local, "one.txt", "one\n")
            try await runGit(["checkout", "main"], local)
        }
        let model = selected.model
        let host = RecordingHost(model.branches)
        model.branches.upstreamStatesLoader.host = host
        let row = Task { await model.branches.watchUpstreamState(of: "refs/heads/one") }
        // The row's task registers on the main actor, ahead of this one.
        await Task.yield()
        await model.branches.upstreamStatesIdle()
        #expect(host.states["refs/heads/one"] == .tracking(AheadBehind(ahead: 1, behind: 0)))
        #expect(host.calls.count == 1)

        // The row scrolled away: one's new pair isn't compared, and its
        // state is forgotten.
        row.cancel()
        await row.value
        try await runGit(["checkout", "one"], selected.local)
        try await commitFile(selected.local, "one-more.txt", "more\n")
        try await runGit(["checkout", "main"], selected.local)
        await model.refresh(.refs, reason: .user)
        await model.branches.upstreamStatesIdle()
        #expect(host.calls.count == 1)
        #expect(host.states["refs/heads/one"] == nil)
        await selected.app.idle()
    }

    // MARK: The loader on its own

    @Test("a batch for rows that left the screen stops, and the next rows get their own")
    func cancelsUnwantedBatch() async throws {
        let host = ScriptedHost()
        let loader = UpstreamStatesLoader()
        loader.host = host
        loader.branchesDidChange(snapshot([("a", "1", "2"), ("b", "3", "4")]))
        loader.beginWatching(["refs/heads/a"])
        // The batch runs up to git.
        await Task.yield()
        #expect(host.calls == [["refs/heads/a", "refs/remotes/origin/a"]])

        loader.endWatching(["refs/heads/a"])
        #expect(host.gate.wasCancelled)
        loader.beginWatching(["refs/heads/b"])
        await Task.yield()
        #expect(host.calls.last == ["refs/heads/b", "refs/remotes/origin/b"])
        host.gate.open(with: lines([("a", "1", "2", "ahead 1"), ("b", "3", "4", "behind 2")]))
        await loader.idle()
        // The cancelled batch's answer never lands.
        #expect(host.states == ["refs/heads/b": .tracking(AheadBehind(ahead: 0, behind: 2))])
        #expect(loader.cachedCount == 1)
    }

    @Test("a batch keeps running while one of its rows is still on screen")
    func keepsWantedBatch() async throws {
        let host = ScriptedHost()
        let loader = UpstreamStatesLoader()
        loader.host = host
        loader.branchesDidChange(snapshot([("a", "1", "2"), ("b", "3", "4")]))
        loader.beginWatching(["refs/heads/a", "refs/heads/b"])
        await Task.yield()
        loader.endWatching(["refs/heads/a"])
        #expect(!host.gate.wasCancelled)
        host.gate.open(with: lines([("a", "1", "2", "ahead 1"), ("b", "3", "4", "behind 2")]))
        await loader.idle()
        #expect(host.calls.count == 1)
        #expect(host.states == [
            "refs/heads/a": .tracking(AheadBehind(ahead: 1, behind: 0)),
            "refs/heads/b": .tracking(AheadBehind(ahead: 0, behind: 2)),
        ])
    }

    @Test("rows on screen keep their state until their moved branch is compared again; others forget it")
    func staleWhileComparing() async throws {
        let host = ScriptedHost()
        let loader = UpstreamStatesLoader()
        loader.host = host
        loader.branchesDidChange(snapshot([("a", "1", "2"), ("b", "3", "4")]))
        loader.beginWatching(["refs/heads/a", "refs/heads/b"])
        await Task.yield()
        host.gate.open(with: lines([("a", "1", "2", "ahead 1"), ("b", "3", "4", "behind 2")]))
        await loader.idle()
        loader.endWatching(["refs/heads/b"])

        // Both upstreams moved.
        host.gate = ResponseGate()
        loader.branchesDidChange(snapshot([("a", "1", "5"), ("b", "3", "6")]))
        #expect(host.states == ["refs/heads/a": .tracking(AheadBehind(ahead: 1, behind: 0))])
        await Task.yield()
        #expect(host.calls.last == ["refs/heads/a", "refs/remotes/origin/a"])
        host.gate.open(with: lines([("a", "1", "5", "ahead 1, behind 3")]))
        await loader.idle()
        #expect(host.states == ["refs/heads/a": .tracking(AheadBehind(ahead: 1, behind: 3))])
        // The old pairs are gone from the cache.
        #expect(loader.cachedCount == 1)
    }

    @Test("a comparison is cached only when git lists the commits the branch list has")
    func cachesConfirmedPairsOnly() async throws {
        let host = ScriptedHost()
        let loader = UpstreamStatesLoader()
        loader.host = host
        loader.branchesDidChange(snapshot([("a", "1", "2"), ("b", "3", "4"), ("c", "5", "6")]))
        loader.beginWatching(["refs/heads/a", "refs/heads/b", "refs/heads/c"])
        await Task.yield()
        // a moved after the list loaded; b's upstream moved; c is as listed.
        host.gate.open(with: lines([("a", "9", "2", "ahead 4"), ("b", "3", "8", "behind 7"), ("c", "5", "6", "ahead 1")]))
        await loader.idle()
        // Shown as git has them, compared once for this list.
        #expect(host.states == [
            "refs/heads/a": .tracking(AheadBehind(ahead: 4, behind: 0)),
            "refs/heads/b": .tracking(AheadBehind(ahead: 0, behind: 7)),
            "refs/heads/c": .tracking(AheadBehind(ahead: 1, behind: 0)),
        ])
        #expect(host.calls.count == 1)
        #expect(loader.cachedCount == 1)

        // The same list again (the refs went back): a and b are compared
        // again, c comes from the cache.
        host.gate = ResponseGate()
        loader.branchesDidChange(snapshot([("a", "1", "2"), ("b", "3", "4"), ("c", "5", "6")]))
        await Task.yield()
        #expect(Set(host.calls.last ?? []) == ["refs/heads/a", "refs/remotes/origin/a", "refs/heads/b", "refs/remotes/origin/b"])
        host.gate.open(with: lines([("a", "1", "2", "ahead 2"), ("b", "3", "4", "behind 3")]))
        await loader.idle()
        #expect(host.states == [
            "refs/heads/a": .tracking(AheadBehind(ahead: 2, behind: 0)),
            "refs/heads/b": .tracking(AheadBehind(ahead: 0, behind: 3)),
            "refs/heads/c": .tracking(AheadBehind(ahead: 1, behind: 0)),
        ])
        #expect(loader.cachedCount == 3)
    }

    @Test("rows past a batch's size are compared in the next batch")
    func batches() async throws {
        let host = ScriptedHost()
        let loader = UpstreamStatesLoader()
        loader.host = host
        let count = upstreamStatesBatchSize + 5
        let branches = (0..<count).map { ("b\($0)", "\($0)", "u\($0)") }
        loader.branchesDidChange(snapshot(branches))
        loader.beginWatching(branches.map { "refs/heads/\($0.0)" })
        host.gate.open(with: lines(branches.map { ($0.0, $0.1, $0.2, "ahead 1") }))
        await loader.idle()
        #expect(host.calls.map(\.count) == [upstreamStatesBatchSize * 2, 10])
        #expect(host.states.count == count)
    }

    // MARK: Parsing

    @Test("parses git's listing and tracking words")
    func parsing() {
        let output = [
            "refs/heads/a\0a1\0refs/remotes/origin/a\0",
            "refs/heads/b\0b1\0refs/remotes/origin/b\0behind 12",
            "refs/heads/c\0c1\0refs/remotes/origin/c\0ahead 3, behind 4",
            "refs/heads/d\0d1\0refs/remotes/origin/d\0gone",
            "refs/heads/e\0e1\0\0",
            "refs/remotes/origin/a\0a2\0\0",
            "",
        ].joined(separator: "\n")
        let lines = parseUpstreamTrackingLines(output)
        #expect(lines.count == 6)
        #expect(lines[ExactString("refs/remotes/origin/a")] == UpstreamTrackingLine(objectName: "a2", upstream: "", track: ""))
        let states = lines.compactMapValues(upstreamState)
        #expect(states == [
            ExactString("refs/heads/a"): .tracking(AheadBehind(ahead: 0, behind: 0)),
            ExactString("refs/heads/b"): .tracking(AheadBehind(ahead: 0, behind: 12)),
            ExactString("refs/heads/c"): .tracking(AheadBehind(ahead: 3, behind: 4)),
            ExactString("refs/heads/d"): .gone,
        ])
    }

    @Test("the branch list names each local branch's upstream when it's listed")
    func trackedUpstreamsOfList() {
        let main = Branch(name: "main", upstream: "origin/main", tip: BranchTip(sha: "1"), type: .local, ref: "refs/heads/main")
        let feature = Branch(name: "feature", upstream: "main", tip: BranchTip(sha: "2"), type: .local, ref: "refs/heads/feature")
        let gone = Branch(name: "gone", upstream: "origin/gone", tip: BranchTip(sha: "3"), type: .local, ref: "refs/heads/gone")
        let unpublished = Branch(name: "new", upstream: nil, tip: BranchTip(sha: "4"), type: .local, ref: "refs/heads/new")
        let originMain = Branch(name: "origin/main", upstream: nil, tip: BranchTip(sha: "5"), type: .remote, ref: "refs/remotes/origin/main")
        let upstreams = trackedUpstreams([main, feature, gone, unpublished, originMain])
        #expect(upstreams == [ExactString("refs/heads/main"): originMain, ExactString("refs/heads/feature"): main])
    }
}

// MARK: - Helpers

/// A branch list of local branches `bN` (name, tip, upstream tip) tracking
/// `origin/bN`.
private func snapshot(_ branches: [(name: String, tip: String, upstreamTip: String)]) -> BranchesSnapshot {
    var all: [Branch] = []
    var upstreams: [ExactString: Branch] = [:]
    for (name, tip, upstreamTip) in branches {
        let local = Branch(name: name, upstream: "origin/\(name)", tip: BranchTip(sha: tip), type: .local, ref: "refs/heads/\(name)")
        all.append(local)
        upstreams[ExactString(local.ref)] = Branch(
            name: "origin/\(name)", upstream: nil, tip: BranchTip(sha: upstreamTip), type: .remote, ref: "refs/remotes/origin/\(name)"
        )
    }
    return BranchesSnapshot(all: all, upstreams: upstreams)
}

/// git's listing of local branches (name, tip, upstream tip, track) and
/// their upstreams.
private func lines(_ branches: [(name: String, tip: String, upstreamTip: String, track: String)]) -> [ExactString: UpstreamTrackingLine] {
    var lines: [ExactString: UpstreamTrackingLine] = [:]
    for (name, tip, upstreamTip, track) in branches {
        lines[ExactString("refs/heads/\(name)")] = UpstreamTrackingLine(objectName: tip, upstream: "refs/remotes/origin/\(name)", track: track)
        lines[ExactString("refs/remotes/origin/\(name)")] = UpstreamTrackingLine(objectName: upstreamTip, upstream: "", track: "")
    }
    return lines
}

/// Runs git as the branches model does, and records each call.
@MainActor
private final class RecordingHost: UpstreamStatesHost {
    private let model: BranchesModel
    var calls: [[String]] = []
    var states: [String: BranchUpstreamState] = [:]

    init(_ model: BranchesModel) {
        self.model = model
    }

    func listUpstreamTracking(_ refs: [String]) async throws -> [ExactString: UpstreamTrackingLine] {
        calls.append(refs)
        return try await model.listUpstreamTracking(refs)
    }

    func upstreamStatesDidChange(_ states: [String: BranchUpstreamState]) {
        self.states = states
    }
}

/// Answers each call when the test opens its gate.
@MainActor
private final class ScriptedHost: UpstreamStatesHost {
    var gate = ResponseGate()
    var calls: [[String]] = []
    var states: [String: BranchUpstreamState] = [:]

    func listUpstreamTracking(_ refs: [String]) async throws -> [ExactString: UpstreamTrackingLine] {
        calls.append(refs)
        guard let answer = await gate.wait() else {
            throw CancellationError()
        }
        let lines = try answer.get()
        // Only what git would list for these refs.
        let asked = refs.exactSet
        return lines.filter { asked.contains($0.key) }
    }

    func upstreamStatesDidChange(_ states: [String: BranchUpstreamState]) {
        self.states = states
    }
}

/// Holds calls until the test answers them; a cancelled call gets nil.
private final class ResponseGate: Sendable {
    private typealias Answer = Result<[ExactString: UpstreamTrackingLine], any Error>

    private struct State {
        var waiters: [Int: CheckedContinuation<Answer?, Never>] = [:]
        var nextID = 0
        var answer: Answer?
        var cancelledCalls = 0
    }

    private let state = Mutex(State())

    /// Whether a call was cancelled.
    var wasCancelled: Bool {
        state.withLock { $0.cancelledCalls > 0 }
    }

    /// Answers the calls waiting and the ones to come.
    func open(with lines: [ExactString: UpstreamTrackingLine]) {
        answer(.success(lines))
    }

    private func answer(_ answer: Answer) {
        let waiters = state.withLock { state in
            state.answer = answer
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.resume(returning: answer)
        }
    }

    func wait() async -> Result<[ExactString: UpstreamTrackingLine], any Error>? {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Answer?, Never>) in
                let answer: Answer? = state.withLock { state in
                    if let answer = state.answer {
                        return answer
                    }
                    state.waiters[id] = continuation
                    return nil
                }
                if let answer {
                    continuation.resume(returning: answer)
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.cancelledCalls += 1
                return state.waiters.removeValue(forKey: id)
            }
            waiter?.resume(returning: nil)
        }
    }
}
