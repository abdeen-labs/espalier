// The Appearance and Notifications panes. The pop-ups list every value;
// turning notifications on asks for the system's permission once, and the
// status line follows it.

import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Settings preferences", .offline) @MainActor
struct SettingsPreferencesTests {
    // MARK: Appearance

    @Test("Appearance's pop-ups list desktop's values")
    func appearanceValues() {
        #expect(AppearanceSettings.tabSizes == [1, 2, 3, 4, 5, 6, 8, 10, 12])
        #expect(AppearanceSettings.tabSizeTitle(4) == "4 (default)")
        #expect(AppearanceSettings.tabSizeTitle(8) == "8")
        // A size set some other way still shows.
        #expect(AppearanceSettings.tabSizes(including: 7) == [1, 2, 3, 4, 5, 6, 7, 8, 10, 12])
        #expect(AppearanceSettings.tabSizes(including: 4) == AppearanceSettings.tabSizes)

        let formats = numberFormats.map(AppearanceSettings.numberFormatExample)
        #expect(formats == ["1234567.89", "1234567,89", "1,234,567.89", "1.234.567,89", "1 234 567.89", "1 234 567,89"])
        #expect(AppearanceSettings.formatTitle(example: "Oct 19, 2017", pattern: "MMM d, yyyy") == "Oct 19, 2017 (MMM d, yyyy)")
    }

    // MARK: Notifications

    @Test("turning notifications on asks for permission when the user hasn't been asked")
    func requestsPermission() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        app.preferences.highSignalNotificationsEnabled = false
        let system = FakeNotificationSystem(.notDetermined)
        let settings = NotificationSettings(preferences: app.preferences, permissions: system.permissions, open: { _ in })
        await settings.refresh()
        #expect(settings.statusLine == nil)

        await settings.setEnabled(true)
        #expect(app.preferences.highSignalNotificationsEnabled)
        #expect(harness.defaults.defaults.object(forKey: PreferenceKey.highSignalNotificationsEnabled) as? Bool == true)
        #expect(system.requests == 1)
        #expect(settings.permission == .authorized)
        #expect(settings.statusLine?.action == .openSettings)

        // Asked once: turning it off and on again doesn't ask again.
        await settings.setEnabled(false)
        #expect(settings.statusLine == nil)
        await settings.setEnabled(true)
        #expect(system.requests == 1)
    }

    @Test("a denied permission points to System Settings; the button opens it")
    func deniedPermission() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        let system = FakeNotificationSystem(.denied)
        var opened: [URL] = []
        let settings = NotificationSettings(preferences: app.preferences, permissions: system.permissions, open: { opened.append($0) })
        await settings.setEnabled(true)
        #expect(system.requests == 0)
        let line = try #require(settings.statusLine)
        #expect(line.kind == .warning)
        #expect(line.message == "Espalier isn't allowed to show notifications. Turn them on in System Settings.")
        #expect(line.buttonTitle == "Open Notifications Settings…")
        await settings.perform(line.action)
        #expect(opened == [URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.abdeen.espalier")!])
    }

    @Test("the status line for each permission")
    func statusLines() {
        #expect(NotificationStatusLine(.notDetermined, isEnabled: true)?.action == .request)
        #expect(NotificationStatusLine(.notDetermined, isEnabled: true)?.buttonTitle == "Allow Notifications…")
        #expect(NotificationStatusLine(.authorized, isEnabled: true)?.kind == .success)
        #expect(NotificationStatusLine(.denied, isEnabled: true)?.kind == .warning)
        #expect(NotificationStatusLine(.unavailable, isEnabled: true) == nil)
        #expect(NotificationStatusLine(nil, isEnabled: true) == nil)
        for permission in [NotificationPermission.notDetermined, .denied, .authorized, .unavailable] {
            #expect(NotificationStatusLine(permission, isEnabled: false) == nil)
        }
    }

    @Test("without an app bundle, the system's permission is unavailable")
    func livePermissionsOutsideABundle() async {
        // The test runner isn't an app bundle, where the notification
        // center raises an exception: the live value never touches it.
        #expect(await NotificationPermissions.live.status() == .unavailable)
        #expect(await NotificationPermissions.live.request() == .unavailable)
    }
}

/// A notification system whose permission changes when asked.
final class FakeNotificationSystem: Sendable {
    private let state: Mutex<(permission: NotificationPermission, requests: Int)>

    init(_ permission: NotificationPermission) {
        state = Mutex((permission, 0))
    }

    var requests: Int {
        state.withLock { $0.requests }
    }

    var permissions: NotificationPermissions {
        NotificationPermissions(
            status: { self.state.withLock { $0.permission } },
            request: {
                self.state.withLock { state in
                    state.requests += 1
                    if state.permission == .notDetermined {
                        state.permission = .authorized
                    }
                    return state.permission
                }
            },
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.abdeen.espalier")
        )
    }
}
