import Foundation

/// The clock and the waiting that background work uses.
///
/// The app uses `SystemScheduler`. Tests use TestSupport's
/// `ManualScheduler`, whose time moves only when the test advances it, or
/// `ImmediateScheduler`, whose sleeps return at once and move its time
/// forward.
public protocol Scheduler: Sendable {
    /// The current wall-clock time: what background work compares with
    /// timestamps such as a `FETCH_HEAD` modification date, a repository's
    /// `pushed_at`, or the last prune date.
    var now: Date { get }

    /// Suspends the calling task for `duration`.
    ///
    /// - Throws: `CancellationError` when the task is cancelled before or
    ///   while it sleeps.
    func sleep(for duration: Duration) async throws
}

/// The real clock: `Date()` for the time and `ContinuousClock` for sleeping.
/// Time the Mac spends asleep counts toward a sleep, so work that was due
/// while the Mac slept runs as soon as it wakes.
public struct SystemScheduler: Scheduler {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
