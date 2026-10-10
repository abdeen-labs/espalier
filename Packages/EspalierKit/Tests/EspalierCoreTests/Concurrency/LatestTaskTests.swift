// The slot that guards loads: a newer load cancels the older one, and only
// the latest load's result is applied.

@testable import EspalierCore
import Synchronization
import Testing

/// A gate an operation waits at until the test opens it. Waiting ignores
/// cancellation, so a cancelled operation can still return a value, as a
/// load that finished just as it was replaced does.
private final class Latch: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isOpen = state.withLock { state in
                if !state.isOpen {
                    state.waiters.append(continuation)
                }
                return state.isOpen
            }
            if isOpen {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// A value an operation records for the test to check.
private final class Recorded<Value: Sendable>: Sendable {
    private let storage: Mutex<Value?> = Mutex(nil)

    var value: Value? {
        storage.withLock { $0 }
    }

    func record(_ value: Value) {
        storage.withLock { $0 = value }
    }
}

/// The results a slot applied, in order.
@MainActor
private final class Applied {
    private(set) var results: [String] = []

    func record(_ result: Result<String, any Error>) {
        switch result {
        case .success(let value): results.append(value)
        case .failure(let error): results.append("failed: \(error)")
        }
    }
}

private struct LoadError: Error, CustomStringConvertible {
    var description: String { "LoadError" }
}

/// An operation that waits at `latch`, records whether its task was
/// cancelled by then, opens `returned` and returns `value`.
private func controlled(
    _ value: String,
    latch: Latch,
    cancelled: Recorded<Bool>,
    returned: Latch
) -> @Sendable () async throws -> String {
    {
        await latch.wait()
        cancelled.record(Task.isCancelled)
        returned.open()
        return value
    }
}

@Suite("LatestTask") @MainActor
struct LatestTaskTests {
    @Test("applies the latest load's result, and keeps its key")
    func appliesResult() async {
        let slot = LatestTask<String>()
        let applied = Applied()
        #expect(slot.currentKey == nil)
        #expect(!slot.isRunning)

        slot.run("a", operation: { "result a" }, apply: applied.record)
        #expect(slot.currentKey == "a")
        #expect(slot.isRunning)

        await slot.idle()
        #expect(applied.results == ["result a"])
        #expect(slot.currentKey == "a")
        #expect(!slot.isRunning)
    }

    @Test("a load for a newer key cancels the older one, whose result never applies")
    func newerKeyCancelsOlder() async {
        let slot = LatestTask<String>()
        let applied = Applied()
        let latch = Latch()
        let returned = Latch()
        let cancelled = Recorded<Bool>()

        slot.run("a", operation: controlled("result a", latch: latch, cancelled: cancelled, returned: returned), apply: applied.record)
        slot.run("b", operation: { "result b" }, apply: applied.record)
        #expect(slot.currentKey == "b")
        await slot.idle()
        #expect(applied.results == ["result b"])

        // The older load returns a value after the newer one applied.
        latch.open()
        await returned.wait()
        await Task.yield()
        #expect(cancelled.value == true)
        #expect(applied.results == ["result b"])
        #expect(slot.currentKey == "b")
    }

    @Test("a stale result that arrives first never applies either")
    func staleResultFirst() async {
        let slot = LatestTask<String>()
        let applied = Applied()
        let latchA = Latch()
        let returnedA = Latch()
        let cancelledA = Recorded<Bool>()
        let latchB = Latch()
        let returnedB = Latch()
        let cancelledB = Recorded<Bool>()

        slot.run("a", operation: controlled("result a", latch: latchA, cancelled: cancelledA, returned: returnedA), apply: applied.record)
        slot.run("b", operation: controlled("result b", latch: latchB, cancelled: cancelledB, returned: returnedB), apply: applied.record)

        latchA.open()
        await returnedA.wait()
        await Task.yield()
        #expect(applied.results.isEmpty)
        #expect(slot.isRunning)

        latchB.open()
        await slot.idle()
        #expect(applied.results == ["result b"])
        #expect(cancelledA.value == true)
        #expect(cancelledB.value == false)
    }

    @Test("a load for the same key replaces the one in flight")
    func sameKeyReplaces() async {
        let slot = LatestTask<String>()
        let applied = Applied()
        let latch = Latch()
        let returned = Latch()
        let cancelled = Recorded<Bool>()

        slot.run("a", operation: controlled("first", latch: latch, cancelled: cancelled, returned: returned), apply: applied.record)
        slot.run("a", operation: { "second" }, apply: applied.record)
        await slot.idle()

        latch.open()
        await returned.wait()
        await Task.yield()
        #expect(cancelled.value == true)
        #expect(applied.results == ["second"])
        #expect(slot.currentKey == "a")
    }

    @Test("cancel() cancels the load in flight, and its result never applies")
    func cancel() async {
        let slot = LatestTask<String>()
        let applied = Applied()
        let latch = Latch()
        let returned = Latch()
        let cancelled = Recorded<Bool>()

        slot.run("a", operation: controlled("result a", latch: latch, cancelled: cancelled, returned: returned), apply: applied.record)
        slot.cancel()
        #expect(slot.currentKey == nil)
        #expect(!slot.isRunning)
        await slot.idle()

        latch.open()
        await returned.wait()
        await Task.yield()
        #expect(cancelled.value == true)
        #expect(applied.results.isEmpty)
        #expect(slot.currentKey == nil)
    }

    @Test("releasing the slot cancels the load in flight")
    func releaseCancels() async {
        var slot: LatestTask<String>? = LatestTask<String>()
        let applied = Applied()
        let latch = Latch()
        let returned = Latch()
        let cancelled = Recorded<Bool>()

        slot?.run("a", operation: controlled("result a", latch: latch, cancelled: cancelled, returned: returned), apply: applied.record)
        slot = nil

        latch.open()
        await returned.wait()
        await Task.yield()
        #expect(cancelled.value == true)
        #expect(applied.results.isEmpty)
    }

    @Test("cancel() with nothing in flight changes nothing, and the slot runs loads after it")
    func cancelWhenIdle() async {
        let slot = LatestTask<String>()
        let applied = Applied()

        slot.cancel()
        #expect(slot.currentKey == nil)

        slot.run("a", operation: { "result a" }, apply: applied.record)
        await slot.idle()
        slot.cancel()
        #expect(slot.currentKey == nil)
        #expect(applied.results == ["result a"])

        slot.run("b", operation: { "result b" }, apply: applied.record)
        await slot.idle()
        #expect(applied.results == ["result a", "result b"])
        #expect(slot.currentKey == "b")
    }

    @Test("applies the latest load's failure, a CancellationError it throws itself included")
    func appliesFailures() async {
        let slot = LatestTask<String>()
        let applied = Applied()

        slot.run("a", operation: { throw LoadError() }, apply: applied.record)
        await slot.idle()
        slot.run("b", operation: { throw CancellationError() }, apply: applied.record)
        await slot.idle()

        #expect(applied.results == ["failed: LoadError", "failed: CancellationError()"])
    }

    @Test("idle() waits for a load started while it waits, and for its result to apply")
    func idleWaitsForNewerLoads() async {
        let slot = LatestTask<String>()
        let applied = Applied()
        let latchA = Latch()
        let latchB = Latch()

        slot.run("a", operation: { await latchA.wait(); return "result a" }, apply: applied.record)
        let waiter = Task { @MainActor in
            await slot.idle()
            return applied.results
        }
        // Let the waiter start waiting for the first load.
        await Task.yield()

        slot.run("b", operation: { await latchB.wait(); return "result b" }, apply: applied.record)
        latchA.open()
        await Task.yield()
        latchB.open()

        #expect(await waiter.value == ["result b"])
    }

    @Test("idle() also waits for a load that applying a result starts")
    func idleWaitsForChainedLoads() async {
        let slot = LatestTask<String>()
        let applied = Applied()

        slot.run("first", operation: { "result first" }, apply: { result in
            applied.record(result)
            slot.run("second", operation: { "result second" }, apply: applied.record)
        })
        await slot.idle()

        #expect(applied.results == ["result first", "result second"])
        #expect(slot.currentKey == "second")
        #expect(!slot.isRunning)
    }
}
