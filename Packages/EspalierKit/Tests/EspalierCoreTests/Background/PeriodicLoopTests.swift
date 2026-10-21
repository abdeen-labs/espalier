// The task loop the background services schedule themselves with, on
// TestSupport's ManualScheduler.

@testable import EspalierCore
import Testing
import TestSupport

/// What the loops' runs did, and when.
@MainActor
private final class Runs {
    private(set) var log: [String] = []

    func append(_ entry: String) {
        log.append(entry)
    }
}

/// The scheduler's elapsed time in whole seconds, for logs.
private func seconds(_ scheduler: ManualScheduler) -> Int64 {
    scheduler.elapsed.components.seconds
}

/// Lets the loop's tasks run, without moving the time, until `condition`
/// holds or a bound passes: a loop ends a few task hops after its last run
/// returns.
@MainActor
private func settle(_ scheduler: ManualScheduler, until condition: () -> Bool) async {
    var rounds = 0
    while !condition(), rounds < 50 {
        await scheduler.advance()
        rounds += 1
    }
}

@Suite("PeriodicLoop", .hangGuard(minutes: 5)) @MainActor
struct PeriodicLoopTests {
    @Test("a run that returns nil stops the loop")
    func nilStops() async {
        let scheduler = ManualScheduler()
        let runs = Runs()
        let loop = PeriodicLoop(scheduler: scheduler)
        var remaining = 2

        loop.start(firstDelay: .seconds(1)) {
            runs.append("ran at \(seconds(scheduler))")
            remaining -= 1
            return remaining > 0 ? .seconds(1) : nil
        }
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .seconds(1))
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .seconds(1))

        #expect(runs.log == ["ran at 1", "ran at 2"])
        await settle(scheduler) { !loop.isRunning }
        #expect(!loop.isRunning)
        #expect(scheduler.sleeperCount == 0)

        await scheduler.advance(by: .seconds(60))
        #expect(runs.log == ["ran at 1", "ran at 2"])
        #expect(scheduler.sleeps == [.seconds(1), .seconds(1)])
    }

    @Test("start() replaces a sleeping loop")
    func startReplacesSleepingLoop() async {
        let scheduler = ManualScheduler()
        let runs = Runs()
        let loop = PeriodicLoop(scheduler: scheduler)

        loop.start(firstDelay: .seconds(10)) {
            runs.append("first ran at \(seconds(scheduler))")
            return .seconds(10)
        }
        await scheduler.waitForSleepers(1)
        loop.start(firstDelay: .seconds(3)) {
            runs.append("second ran at \(seconds(scheduler))")
            return nil
        }
        #expect(loop.isRunning)

        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .seconds(60))
        #expect(runs.log == ["second ran at 3"])
        #expect(scheduler.sleeps == [.seconds(10), .seconds(3)])
        await settle(scheduler) { !loop.isRunning }
        #expect(!loop.isRunning)
    }

    @Test("start() lets a replaced loop's run finish before the new loop's first delay starts")
    func startWaitsForRunInProgress() async {
        let scheduler = ManualScheduler()
        let runs = Runs()
        let loop = PeriodicLoop(scheduler: scheduler)

        loop.start(firstDelay: .seconds(10)) {
            runs.append("first ran at \(seconds(scheduler))")
            try? await scheduler.sleep(for: .seconds(5))
            runs.append("first finished at \(seconds(scheduler))")
            return .seconds(10)
        }
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .seconds(10))
        await scheduler.advance(by: .seconds(2))
        #expect(runs.log == ["first ran at 10"])

        loop.start(firstDelay: .seconds(3)) {
            runs.append("second ran at \(seconds(scheduler))")
            return nil
        }
        // The first loop's run ends at 15; the second loop waits 3 seconds from then.
        await scheduler.advance(by: .seconds(3))
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .seconds(3))

        #expect(runs.log == ["first ran at 10", "first finished at 15", "second ran at 18"])
        #expect(scheduler.sleeps == [.seconds(10), .seconds(5), .seconds(3)])
        await settle(scheduler) { !loop.isRunning }
        #expect(!loop.isRunning)
    }

    @Test("releasing the loop cancels its sleep")
    func releaseCancels() async {
        let scheduler = ManualScheduler()
        let runs = Runs()
        var loop: PeriodicLoop? = PeriodicLoop(scheduler: scheduler)

        loop?.start(firstDelay: .seconds(10)) {
            runs.append("ran at \(seconds(scheduler))")
            return .seconds(10)
        }
        await scheduler.waitForSleepers(1)
        loop = nil
        await settle(scheduler) { scheduler.sleeperCount == 0 }
        #expect(scheduler.sleeperCount == 0)

        await scheduler.advance(by: .seconds(3600))
        #expect(runs.log.isEmpty)
    }
}
