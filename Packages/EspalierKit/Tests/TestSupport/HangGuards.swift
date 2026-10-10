// Hang guards: a guarded test fails once it has run for a set time with no
// guarded test anywhere in the process finishing. A busy machine slows every
// test, but tests go on finishing; a hang is caught that long after they
// stop.

import Synchronization
import Testing

/// Fails a test, and cancels it, once it has run for `minutes` with no other
/// guarded test in the process finishing in that time.
///
/// Each test case is guarded on its own; on a suite, every test in it is.
public struct HangGuardTrait: TestTrait, SuiteTrait, TestScoping {
    /// How long a test may run with no guarded test finishing, before
    /// Thread Sanitizer's factor.
    public let minutes: Int
    let sourceLocation: SourceLocation

    public var isRecursive: Bool {
        true
    }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let minutes = ThreadSanitizer.isActive ? minutes * ThreadSanitizer.timeLimitFactor : minutes
        let started = GuardedTests.clock.now
        let sourceLocation = sourceLocation
        let isHung: Bool
        do {
            isHung = try await withoutActuallyEscaping(function) { function in
                try await withThrowingTaskGroup(of: Outcome.self) { group in
                    group.addTask {
                        try await function()
                        return .finished
                    }
                    group.addTask {
                        do {
                            try await GuardedTests.waitUntilQuiet(since: started, for: .seconds(60 * minutes))
                        } catch {
                            return .stopped
                        }
                        Issue.record(
                            "No test finished for \(minutes) minutes while this one ran: it looks hung",
                            sourceLocation: sourceLocation
                        )
                        return .hung
                    }
                    defer { group.cancelAll() }
                    while let outcome = try await group.next() {
                        switch outcome {
                        case .finished: return false
                        case .hung: return true
                        case .stopped: continue
                        }
                    }
                    return false
                }
            }
        } catch {
            GuardedTests.recordFinish()
            throw error
        }
        // A test the guard stopped isn't progress: the tests that hang with
        // it are reported together.
        if !isHung {
            GuardedTests.recordFinish()
        }
    }

    private enum Outcome: Sendable {
        /// The test ended.
        case finished
        /// The guard recorded the test as hung.
        case hung
        /// The guard was cancelled.
        case stopped
    }
}

extension Trait where Self == HangGuardTrait {
    /// Fails a test that runs for `minutes` with no guarded test in the
    /// process finishing, `ThreadSanitizer.timeLimitFactor` times as long
    /// under Thread Sanitizer.
    public static func hangGuard(minutes: Int, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        HangGuardTrait(minutes: minutes, sourceLocation: sourceLocation)
    }
}

/// When a guarded test in this process last finished.
private enum GuardedTests {
    /// Stops while the Mac sleeps, so a run that sleeps isn't a hang.
    static let clock = SuspendingClock()
    static let lastFinish = Mutex<SuspendingClock.Instant?>(nil)

    static func recordFinish() {
        let now = clock.now
        lastFinish.withLock { lastFinish in
            lastFinish = max(lastFinish ?? now, now)
        }
    }

    /// Returns once `limit` has passed since the later of `start` and the
    /// last time a guarded test finished, sleeping until that time and again
    /// whenever a test finished in the meantime.
    static func waitUntilQuiet(since start: SuspendingClock.Instant, for limit: Duration) async throws {
        while true {
            let lastProgress = max(start, lastFinish.withLock { $0 } ?? start)
            let deadline = lastProgress.advanced(by: limit)
            guard clock.now < deadline else {
                return
            }
            try await clock.sleep(until: deadline, tolerance: .seconds(1))
        }
    }
}
