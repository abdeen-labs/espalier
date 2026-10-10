// Ported from desktop/app/src/ui/lib/git-perf.ts

import EspalierSupport
import Foundation
import os

/// Measures git operations: an `os_signpost` interval for Instruments, and a
/// log line for anything slower than a second (or everything in debug builds).
enum GitPerf {
    private static let signposter = OSSignposter(subsystem: Log.subsystem, category: "git-perf")
    private static let logger = Log.logger(category: "git-perf")

    /// Measure an async git operation.
    static func measure<T>(_ command: String, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval("git", id: signposter.makeSignpostID(), "\(command, privacy: .public)")
        let start = ContinuousClock.now
        defer {
            signposter.endInterval("git", state)
            let elapsed = ContinuousClock.now - start
            #if DEBUG
            let shouldLog = true
            #else
            let shouldLog = elapsed > .seconds(1)
            #endif
            if shouldLog {
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                logger.info("Executing \(command, privacy: .public) (took \(String(format: "%.3f", seconds), privacy: .public)s)")
            }
        }
        return try await body()
    }
}
