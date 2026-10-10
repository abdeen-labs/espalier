// Settings ▸ Notifications: the setting with its description, and a status
// line about the system's permission with Open Notifications Settings….
// Turning the setting on asks the system for permission.
//
// The system's permission is behind `NotificationPermissions`, injected
// through the environment: `UNUserNotificationCenter.current()` raises an
// exception in a process without an app bundle (the test runner), so tests
// give the pane fixed states.

import AppKit
import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import UserNotifications

/// Whether the system lets Espalier show notifications.
nonisolated public enum NotificationPermission: Sendable, Equatable {
    /// The user hasn't been asked yet.
    case notDetermined
    /// The user turned notifications off for Espalier.
    case denied
    /// Allowed (including provisionally).
    case authorized
    /// Unknown: not an app bundle, so there is no notification center.
    case unavailable
}

/// Reads and requests the system's permission to notify.
nonisolated public struct NotificationPermissions: Sendable {
    /// The permission now.
    public var status: @Sendable () async -> NotificationPermission
    /// Asks the user for permission (the system asks once), then reports
    /// the permission.
    public var request: @Sendable () async -> NotificationPermission
    /// System Settings ▸ Notifications, at Espalier.
    public var settingsURL: URL?

    public init(
        status: @escaping @Sendable () async -> NotificationPermission,
        request: @escaping @Sendable () async -> NotificationPermission,
        settingsURL: URL?
    ) {
        self.status = status
        self.request = request
        self.settingsURL = settingsURL
    }

    /// The User Notifications framework, when Espalier runs as an app
    /// bundle; `.unavailable` otherwise.
    public static let live = NotificationPermissions(
        status: {
            guard isAppBundle else {
                return .unavailable
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return NotificationPermission(settings.authorizationStatus)
        },
        request: {
            guard isAppBundle else {
                return .unavailable
            }
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            return NotificationPermission(await center.notificationSettings().authorizationStatus)
        },
        settingsURL: Bundle.main.bundleIdentifier.flatMap {
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\($0)")
        }
    )

    /// A permission that never changes (tests and snapshots); requesting
    /// grants it unless it was denied.
    public static func fixed(_ permission: NotificationPermission) -> NotificationPermissions {
        NotificationPermissions(
            status: { permission },
            request: { permission == .notDetermined ? .authorized : permission },
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.abdeen.espalier")
        )
    }

    /// Only an app bundle has a notification center.
    private static var isAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
}

nonisolated extension NotificationPermission {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .authorized
        @unknown default: self = .unavailable
        }
    }
}

extension EnvironmentValues {
    /// The system's notification permission (fixed in tests).
    @Entry public var notificationPermissions: NotificationPermissions = .live
}

/// Settings ▸ Notifications.
public struct NotificationsPane: View {
    private let model: AppModel?
    @Environment(\.notificationPermissions) private var permissions

    public init(model: AppModel?) {
        self.model = model
    }

    public var body: some View {
        if let model {
            NotificationsPaneContent(settings: NotificationSettings(
                preferences: model.preferences,
                permissions: permissions,
                open: { url in model.integrations.openInBrowser(url) }
            ))
        } else {
            SettingsPanePlaceholder(tab: .notifications)
        }
    }
}

/// What the status line says for a permission, and its button.
nonisolated struct NotificationStatusLine: Equatable {
    enum Action: Equatable {
        /// Asks for permission (the system shows its prompt).
        case request
        /// Opens System Settings ▸ Notifications.
        case openSettings
    }

    let message: String
    let kind: InlineMessage.Kind
    let action: Action

    /// The line for `permission`, or nil when there's nothing to say: the
    /// setting is off, or the permission is unknown.
    init?(_ permission: NotificationPermission?, isEnabled: Bool) {
        guard isEnabled, let permission else {
            return nil
        }
        switch permission {
        case .notDetermined:
            message = "Espalier needs your permission to show these notifications."
            kind = .note
            action = .request
        case .denied:
            message = "Espalier isn't allowed to show notifications. Turn them on in System Settings."
            kind = .warning
            action = .openSettings
        case .authorized:
            message = "Notifications are allowed. You can change how they look in System Settings."
            kind = .success
            action = .openSettings
        case .unavailable:
            return nil
        }
    }

    var buttonTitle: String {
        switch action {
        case .request: "Allow Notifications…"
        case .openSettings: "Open Notifications Settings…"
        }
    }
}

/// The Notifications pane's state: the setting and the system's
/// permission.
@MainActor @Observable
final class NotificationSettings {
    let preferences: Preferences
    @ObservationIgnored let permissions: NotificationPermissions
    @ObservationIgnored let open: (URL) -> Void
    /// The permission once read.
    private(set) var permission: NotificationPermission?

    init(preferences: Preferences, permissions: NotificationPermissions, permission: NotificationPermission? = nil, open: @escaping (URL) -> Void) {
        self.preferences = preferences
        self.permissions = permissions
        self.permission = permission
        self.open = open
    }

    /// The status line under the setting, if any.
    var statusLine: NotificationStatusLine? {
        NotificationStatusLine(permission, isEnabled: preferences.highSignalNotificationsEnabled)
    }

    /// Writes the setting; turning it on asks for permission when the user
    /// hasn't been asked yet.
    func setEnabled(_ enabled: Bool) async {
        preferences.highSignalNotificationsEnabled = enabled
        if enabled {
            await requestIfNotDetermined()
        }
    }

    /// Asks for permission when the user hasn't been asked yet.
    func requestIfNotDetermined() async {
        let current = await permissions.status()
        permission = current == .notDetermined ? await permissions.request() : current
    }

    /// Reads the permission again (on appearing, and when Espalier becomes
    /// active, back from System Settings).
    func refresh() async {
        permission = await permissions.status()
    }

    /// The status line's button.
    func perform(_ action: NotificationStatusLine.Action) async {
        switch action {
        case .request:
            permission = await permissions.request()
        case .openSettings:
            if let url = permissions.settingsURL {
                open(url)
            }
        }
    }
}

/// The Notifications pane: the switch, and the system's permission.
struct NotificationsPaneContent: View {
    @State private var settings: NotificationSettings
    /// Whether to read the permission on appearing (snapshots set it).
    private let readsPermission: Bool

    init(settings: NotificationSettings, readsPermission: Bool = true) {
        _settings = State(initialValue: settings)
        self.readsPermission = readsPermission
    }

    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsToggleRow(
                    "Enable notifications",
                    description: "When something important happens in the current repository: checks failing, or a review or comment on your pull request.",
                    isOn: isEnabled
                )
                if let line = settings.statusLine {
                    SettingsMessageRow {
                        InlineMessage(line.message, kind: line.kind)
                    } trailing: {
                        Button(line.buttonTitle) {
                            Task { await settings.perform(line.action) }
                        }
                        .settingsButton()
                    }
                    .barTransition()
                }
            }
        }
        // The status line grows in over 0.22 s and leaves over 0.15 s.
        .barMotion(settings.statusLine != nil)
        .task {
            if readsPermission {
                await settings.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await settings.refresh() }
        }
    }

    private var isEnabled: Binding<Bool> {
        Binding {
            settings.preferences.highSignalNotificationsEnabled
        } set: { enabled in
            // The setting changes at once; asking takes a moment.
            settings.preferences.highSignalNotificationsEnabled = enabled
            if enabled {
                Task { await settings.requestIfNotDetermined() }
            }
        }
    }
}
