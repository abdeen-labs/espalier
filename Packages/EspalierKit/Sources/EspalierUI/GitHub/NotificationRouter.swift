// What clicking a pull request notification does: Espalier comes forward,
// the window shows the notification's repository and pull request, and a
// review or a comment opens in a sheet. The notifications carry their route
// in `userInfo`, and `app.pullRequestNotificationTarget(for:)` answers what
// a route shows.
//
// The router is the notification center's delegate from launch (the app
// delegate installs it, so a click that launched Espalier isn't lost), and
// holds clicks until the main window is up. It also lets notifications
// show while Espalier is active.

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import Foundation
import UserNotifications
import os

private let logger = Log.logger(category: "notifications")

/// Routes clicked pull request notifications to the main window.
@MainActor
public final class NotificationRouter: NSObject {
    /// The router the app installs.
    public static let shared = NotificationRouter()

    private weak var context: WindowContext?
    private var pending: [PullRequestNotificationRoute] = []
    private var runner: Task<Void, Never>?
    /// Brings Espalier forward (tests leave the active app alone).
    var activate: @MainActor () -> Void = { NSApp?.activate() }

    /// Becomes the notification center's delegate. Call it before launch
    /// finishes. Only an app bundle has a notification center.
    public func install() {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            return
        }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Routes clicks to the main window `context`, beginning with the ones
    /// that came before it was up.
    func attach(_ context: WindowContext) {
        self.context = context
        runPending()
    }

    /// Routes a click once the main window is up.
    func deliver(_ route: PullRequestNotificationRoute) {
        pending.append(route)
        runPending()
    }

    private func runPending() {
        guard runner == nil, context != nil, !pending.isEmpty else {
            return
        }
        runner = Task {
            while let context, !pending.isEmpty {
                await Self.route(pending.removeFirst(), in: context, activate: activate)
            }
            runner = nil
        }
    }

    /// Shows what a clicked notification is about: Espalier comes forward,
    /// the window selects the notification's repository and pull request,
    /// and a review or a comment opens in a sheet. When the pull request
    /// can't be loaded any more, the repository shows.
    static func route(
        _ route: PullRequestNotificationRoute,
        in context: WindowContext,
        activate: @MainActor () -> Void = { NSApp?.activate() }
    ) async {
        activate()
        let app = context.app
        guard app.repository(route.repositoryID) != nil else {
            logger.info("A notification's repository is no longer in the list")
            return
        }
        guard let target = await app.pullRequestNotificationTarget(for: route) else {
            // The review, comment, or checks couldn't be loaded: the pull
            // request's place, if it's still open, else the repository.
            if app.selection != .repository(route.repositoryID) {
                app.select(.repository(route.repositoryID))
            }
            if app.repository(route.repositoryID)?.gitHub.openPullRequests.contains(where: { $0.pullRequestNumber == route.pullRequestNumber }) == true {
                context.select(.pullRequest(number: route.pullRequestNumber))
            }
            return
        }
        if target.isOtherRepository || app.selection != .repository(target.repositoryID) {
            app.select(.repository(target.repositoryID))
        }
        context.select(.pullRequest(number: target.pullRequest.pullRequestNumber))
        switch target.content {
        case .review, .comment:
            ReviewNotificationSheet.present(target, in: context)
        case .checksFailed:
            // The pull request's place shows its checks.
            break
        }
    }
}

extension NotificationRouter: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            return
        }
        var userInfo: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String {
                userInfo[key] = value
            }
        }
        guard let route = PullRequestNotificationRoute(userInfo: userInfo) else {
            return
        }
        await deliver(route)
    }

    /// Notifications show while Espalier is active too.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
