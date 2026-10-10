// Time limits and hang guards that leave room for Thread Sanitizer, whose
// instrumentation slows the whole package several times over (a sanitized
// run of EspalierUITests' harness suites passed their 5-minute limits).

import Darwin
import Testing

/// Whether this process runs under Thread Sanitizer, and how much longer its
/// time limits are then.
public enum ThreadSanitizer {
    /// Whether the sanitizer's runtime is loaded (`swift test
    /// --sanitize=thread`).
    public static let isActive: Bool = {
        // RTLD_DEFAULT: every image loaded in the process.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
    }()

    /// How many times longer `.timeLimit(minutes:)` and `.hangGuard(minutes:)`
    /// are under the sanitizer.
    public static let timeLimitFactor = 6
}

extension Trait where Self == TimeLimitTrait {
    /// A time limit of `minutes`, `ThreadSanitizer.timeLimitFactor` times as
    /// long when the tests run under Thread Sanitizer, for a test that checks
    /// its own speed. Use it in place of `.timeLimit(.minutes(_:))`; a test
    /// that only must not hang takes `.hangGuard(minutes:)`.
    public static func timeLimit(minutes: Int) -> Self {
        .timeLimit(.minutes(ThreadSanitizer.isActive ? minutes * ThreadSanitizer.timeLimitFactor : minutes))
    }
}
