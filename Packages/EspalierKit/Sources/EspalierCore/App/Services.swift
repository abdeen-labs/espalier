import AppKit
import EspalierSupport
import Foundation
import os
import Synchronization
import UserNotifications

private let logger = Log.logger(category: "services")

// MARK: - Trash

/// Moves files to the Trash.
public protocol TrashService: Sendable {
    /// Moves the file or directory at `path` to the Trash.
    func moveToTrash(_ path: String) async throws
}

/// The Trash, through `FileManager`.
public struct FileManagerTrash: TrashService {
    public init() {}

    @concurrent
    public func moveToTrash(_ path: String) async throws {
        // The path's exact bytes: `URL(filePath:)` decomposes non-ASCII
        // names.
        try FileManager.default.trashItem(at: URL(exactFilePath: path), resultingItemURL: nil)
    }
}

// MARK: - Workspace

/// Opens URLs and reveals files.
@MainActor
public protocol WorkspaceService: Sendable {
    /// Opens `url` in its default app. Returns whether it opened.
    ///
    /// For URLs Espalier builds itself: file URLs, made with
    /// `URL(exactFilePath:)`, and System Settings panes. A link that comes
    /// from a server or a repository goes through `openWebLink(_:)`.
    func open(_ url: URL) -> Bool

    /// Shows the file or directory at `path` in the Finder, selected.
    func revealInFinder(_ path: String)
}

extension WorkspaceService {
    /// Opens `url` when it's a web page (`http` or `https`, in the browser)
    /// or an email address (`mailto`, in the mail app); anything else
    /// doesn't open, and it returns false.
    ///
    /// For links that come from a server or a repository: the GitHub API,
    /// a remote's output, commit messages, Markdown. As a file URL
    /// (`file:///Applications/...`) one would launch an app, and with any
    /// other scheme it would go to whichever app claims that scheme.
    public func openWebLink(_ url: URL) -> Bool {
        guard isWebLink(url) else {
            logger.info("Didn't open a link with the scheme \(url.scheme ?? "(none)", privacy: .public) as a web page")
            return false
        }
        return open(url)
    }
}

/// Whether `url` is a web page or an email address: an `http`, `https`,
/// or `mailto` URL.
func isWebLink(_ url: URL) -> Bool {
    switch url.scheme?.lowercased() {
    case "http", "https", "mailto":
        true
    default:
        false
    }
}

/// The workspace, through `NSWorkspace`.
public struct NSWorkspaceService: WorkspaceService {
    public init() {}

    /// Opens `url` when `opens(_:)` allows it, else returns false.
    public func open(_ url: URL) -> Bool {
        guard Self.opens(url) else {
            logger.info("Didn't open a link with the scheme \(url.scheme ?? "(none)", privacy: .public)")
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    /// Whether `open(_:)` opens `url`: a file URL, a web page or an email
    /// address (`http`, `https`, or `mailto`, which `openWebLink(_:)` opens
    /// through it), or a System Settings pane (`x-apple.systempreferences`).
    /// No other scheme opens, whoever passes it.
    nonisolated static func opens(_ url: URL) -> Bool {
        if url.isFileURL {
            return true
        }
        return isWebLink(url) || url.scheme?.lowercased() == "x-apple.systempreferences"
    }

    public func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(exactFilePath: path)])
    }
}

// MARK: - Notifications

/// A notification to post: failed checks, pull request reviews and comments.
public struct UserNotification: Sendable, Equatable {
    public var title: String
    public var body: String
    /// Replaces an earlier notification with the same identifier.
    public var identifier: String
    /// Data for routing a click.
    public var userInfo: [String: String]

    public init(title: String, body: String, identifier: String = UUID().uuidString, userInfo: [String: String] = [:]) {
        self.title = title
        self.body = body
        self.identifier = identifier
        self.userInfo = userInfo
    }
}

/// Posts user notifications.
public protocol UserNotificationPoster: Sendable {
    func post(_ notification: UserNotification) async
}

/// The notification center, as the poster uses it.
public protocol NotificationCenterClient: Sendable {
    /// Whether the user lets Espalier notify, now.
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Asks the user (the system asks once); whether it's allowed.
    func requestAuthorization() async throws -> Bool
    /// Delivers `notification`.
    func add(_ notification: UserNotification) async throws
}

/// `UNUserNotificationCenter.current()`. Only an app bundle may use it, so
/// nothing touches it until it's asked something.
public struct LiveNotificationCenter: NotificationCenterClient {
    public init() {}

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    public func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public func add(_ notification: UserNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.userInfo = notification.userInfo
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

/// Notifications through the User Notifications framework. Authorization is
/// requested the first time something is posted while the user hasn't been
/// asked.
///
/// Only a granted permission is kept: otherwise the permission is read
/// again for every post, so allowing notifications later (Settings ▸
/// Notifications, or System Settings) takes effect at once.
public final class UserNotificationCenterPoster: UserNotificationPoster {
    private struct State {
        var isAuthorized = false
        /// The request for permission in flight, which concurrent posts
        /// share.
        var request: Task<Bool, Never>?
    }

    private let center: any NotificationCenterClient
    private let state = Mutex(State())

    public init(center: any NotificationCenterClient = LiveNotificationCenter()) {
        self.center = center
    }

    @concurrent
    public func post(_ notification: UserNotification) async {
        guard await isAuthorized() else {
            return
        }
        do {
            try await center.add(notification)
        } catch {
            logger.error("Could not post a notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isAuthorized() async -> Bool {
        if state.withLock({ $0.isAuthorized }) {
            return true
        }
        switch await center.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            state.withLock { $0.isAuthorized = true }
            return true
        case .notDetermined:
            let center = center
            let task = state.withLock { state in
                if let request = state.request {
                    return request
                }
                let request = Task {
                    do {
                        return try await center.requestAuthorization()
                    } catch {
                        logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                        return false
                    }
                }
                state.request = request
                return request
            }
            let granted = await task.value
            state.withLock { state in
                if state.request == task {
                    state.request = nil
                }
                if granted {
                    state.isAuthorized = true
                }
            }
            return granted
        default:
            // Denied: asked again at the next post.
            return false
        }
    }
}
