import EspalierCore
import Synchronization

/// Records the notifications posted, posting nothing.
public final class RecordingNotificationPoster: UserNotificationPoster {
    private let posted = Mutex<[UserNotification]>([])

    public init() {}

    /// The notifications posted, in order.
    public var notifications: [UserNotification] {
        posted.withLock { $0 }
    }

    public func post(_ notification: UserNotification) async {
        posted.withLock { $0.append(notification) }
    }
}
