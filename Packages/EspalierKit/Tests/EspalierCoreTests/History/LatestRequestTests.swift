// `LatestRequest`, the awaited latest-wins slot compare, previews, and Go
// to Commit use.

@testable import EspalierCore
import Testing

/// Holds operations until it's opened.
private nonisolated struct RequestGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    /// Waits until the gate opens or the task is cancelled.
    func wait() async {
        for await _ in stream {
            break
        }
    }

    func open() {
        continuation.finish()
    }
}

@Suite("Latest request") @MainActor
struct LatestRequestTests {
    /// Starts `operation` in a task and returns once its request is in
    /// flight.
    private func start(_ request: LatestRequest, _ operation: @escaping @Sendable () async -> Int) async -> Task<Int?, Never> {
        let task = Task { await request.perform(operation) }
        for _ in 0..<1_000 where !request.isRunning {
            await Task.yield()
        }
        #expect(request.isRunning)
        return task
    }

    @Test("a newer request replaces the one in flight, whose caller gets nil")
    func latestWins() async {
        let request = LatestRequest()
        let gate = RequestGate()
        let first = await start(request) {
            await gate.wait()
            return Task.isCancelled ? -1 : 1
        }

        #expect(await request.perform { 2 } == 2)
        #expect(request.isRunning == false)
        gate.open()
        #expect(await first.value == nil)
    }

    @Test("cancel gives the caller nil and cancels the operation")
    func cancel() async {
        let request = LatestRequest()
        let gate = RequestGate()
        let first = await start(request) {
            await gate.wait()
            return Task.isCancelled ? -1 : 1
        }

        request.cancel()
        #expect(request.isRunning == false)
        #expect(await first.value == nil)
        await request.idle()
        // The slot works again afterwards.
        #expect(await request.perform { 3 } == 3)
    }

    @Test("a cancelled caller gets nil, and its operation is cancelled")
    func callerCancelled() async {
        let request = LatestRequest()
        let gate = RequestGate()
        let sawCancellation = RequestGate()
        let first = await start(request) {
            await gate.wait()
            if Task.isCancelled {
                sawCancellation.open()
            }
            return 1
        }

        first.cancel()
        await sawCancellation.wait()
        #expect(await first.value == nil)
        await request.idle()
        #expect(request.isRunning == false)
    }

    @Test("idle waits for the request in flight")
    func idle() async {
        let request = LatestRequest()
        let gate = RequestGate()
        let first = await start(request) {
            await gate.wait()
            return 1
        }
        gate.open()
        await request.idle()
        #expect(await first.value == 1)
        #expect(request.isRunning == false)
    }
}
