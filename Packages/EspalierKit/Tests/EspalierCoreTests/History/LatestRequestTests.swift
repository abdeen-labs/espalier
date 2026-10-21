// `LatestRequest`, the awaited latest-wins slot compare, previews, and Go
// to Commit use.

@testable import EspalierCore
import Testing
import TestSupport

@Suite("Latest request", .hangGuard(minutes: 5)) @MainActor
struct LatestRequestTests {
    /// Starts `operation`, which waits at `gate`, in a task and returns once
    /// it waits there.
    private func start(
        _ request: LatestRequest,
        at gate: AsyncGate,
        _ operation: @escaping @Sendable () async -> Int
    ) async throws -> Task<Int?, Never> {
        let task = Task { await request.perform(operation) }
        try await gate.waitUntilWaiting()
        #expect(request.isRunning)
        return task
    }

    @Test("a newer request replaces the one in flight, whose caller gets nil")
    func latestWins() async throws {
        let request = LatestRequest()
        let gate = AsyncGate()
        let first = try await start(request, at: gate) {
            await gate.wait()
            return Task.isCancelled ? -1 : 1
        }

        #expect(await request.perform { 2 } == 2)
        #expect(request.isRunning == false)
        gate.open()
        #expect(await first.value == nil)
    }

    @Test("cancel gives the caller nil and cancels the operation")
    func cancel() async throws {
        let request = LatestRequest()
        let gate = AsyncGate()
        let first = try await start(request, at: gate) {
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
    func callerCancelled() async throws {
        let request = LatestRequest()
        let gate = AsyncGate()
        let sawCancellation = AsyncGate()
        let first = try await start(request, at: gate) {
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
    func idle() async throws {
        let request = LatestRequest()
        let gate = AsyncGate()
        let first = try await start(request, at: gate) {
            await gate.wait()
            return 1
        }
        gate.open()
        await request.idle()
        #expect(await first.value == 1)
        #expect(request.isRunning == false)
    }
}
