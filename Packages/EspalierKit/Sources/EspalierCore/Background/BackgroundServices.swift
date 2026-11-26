// Which background services start on their own. The app starts all of
// them; tests start only the ones they check (`AppHarness`), so a fetch or
// a poll never lands in a test that didn't ask for it.

/// The background services that start on their own when their conditions
/// hold (`BackgroundCoordinator`'s table, the notifications poller, and the
/// saves of the worktrees' activity). One left out never starts; its work runs only when
/// called.
///
/// The repository indicator updater and watcher aren't among them: they
/// follow their setting.
public struct BackgroundServices: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The background fetcher.
    public static let fetcher = BackgroundServices(rawValue: 1 << 0)
    /// The branch pruner.
    public static let pruner = BackgroundServices(rawValue: 1 << 1)
    /// The pull request updater.
    public static let pullRequests = BackgroundServices(rawValue: 1 << 2)
    /// The pull request notifications poller.
    public static let notifications = BackgroundServices(rawValue: 1 << 3)
    /// The updater of every repository's branch pull request, which also
    /// follows the indicators' setting.
    public static let branchPullRequests = BackgroundServices(rawValue: 1 << 4)
    /// Saving the worktrees' activity and the pins a while after they change
    /// (`WorktreeActivityModel`). Left out, they're saved only when flushed.
    public static let worktreeActivityAutosave = BackgroundServices(rawValue: 1 << 8)
    /// The clock that wakes when a piece of work stops changing now
    /// (`WorkClock`). Left out, phases change only with their inputs.
    public static let workClock = BackgroundServices(rawValue: 1 << 9)

    /// Every one, as the app runs them.
    public static let all: BackgroundServices = [
        .fetcher, .pruner, .pullRequests, .notifications, .branchPullRequests, .worktreeActivityAutosave, .workClock,
    ]
}
