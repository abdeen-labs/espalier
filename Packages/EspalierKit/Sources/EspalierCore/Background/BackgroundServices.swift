// Which background services start on their own. The app starts all of
// them; tests start only the ones they check (`AppHarness`), so a fetch or
// a poll never lands in a test that didn't ask for it.

/// The background services that start on their own when their conditions
/// hold (`BackgroundCoordinator`'s table, and the notifications poller).
/// One left out never starts; its work runs only when called.
///
/// The repository indicator updater isn't one of them: it follows its
/// setting.
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

    /// Every one, as the app runs them.
    public static let all: BackgroundServices = [.fetcher, .pruner, .pullRequests, .notifications]
}
