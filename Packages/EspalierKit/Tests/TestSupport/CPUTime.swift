// Speed checks count work: the CPU time the test's thread spends, which
// other work on a busy machine doesn't add to, as it adds to wall-clock
// time.

import Darwin

/// The CPU time the calling thread spends in `body`.
public func threadCPUTime(_ body: () throws -> Void) rethrows -> Duration {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    try body()
    return .nanoseconds(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start)
}

/// The least CPU time the calling thread spends in `body` over `runs` runs:
/// a first run's page faults, or a run on a slower core, don't count.
public func leastThreadCPUTime(runs: Int, _ body: () throws -> Void) rethrows -> Duration {
    var least = try threadCPUTime(body)
    for _ in 1..<max(runs, 1) {
        least = min(least, try threadCPUTime(body))
    }
    return least
}
