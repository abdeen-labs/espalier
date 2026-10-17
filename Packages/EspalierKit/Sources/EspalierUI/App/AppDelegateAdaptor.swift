// The app delegate. It starts the rolling log file, launches the app model,
// routes URLs and folders opened from outside, reopens the window from the
// Dock, and runs the quit guard before Espalier quits.

import AppKit
import EspalierCore
import GitKit
import EspalierSupport
import Observation
import SwiftUI
import os

private let logger = Log.logger(category: "app-delegate")

/// Espalier's application delegate. The app target adopts it with
/// `@NSApplicationDelegateAdaptor`.
@MainActor @Observable
public final class EspalierAppDelegate: NSObject, NSApplicationDelegate {
    /// The running app, once launched.
    public private(set) var launched: LaunchedApp?
    /// Why launching failed, if it did.
    public private(set) var launchError: String?
    /// The Settings scene's pane, shared with the main window.
    public let settingsNavigation = SettingsNavigation()
    /// App updates, started with the app.
    public let updater = Updater()

    /// URLs and folders opened before or after launch.
    @ObservationIgnored let externalEvents = ExternalEventsBridge()
    /// The main window's context, for the quit guard's alert and external
    /// actions.
    @ObservationIgnored weak var mainWindowContext: WindowContext? {
        didSet {
            if let mainWindowContext, mainWindowContext !== oldValue {
                externalEvents.attach(mainWindowContext)
            }
        }
    }
    /// Reopens the main window (captured from SwiftUI).
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// Set once the user chose to quit, so a second request doesn't ask
    /// again.
    @ObservationIgnored private var isTerminating = false
    /// Keeps the app's appearance on the theme chosen in Settings, once
    /// launched.
    @ObservationIgnored private var themeApplier: ThemeApplier?
    /// Keeps the look on the design theme, color, app font, and code font
    /// chosen in Settings, once launched.
    @ObservationIgnored private var lookApplier: LookApplier?

    override public init() {
        super.init()
    }

    // MARK: Launching

    /// Starts the rolling log file first, so it has the whole run, then
    /// applies the stored theme, look, and Espalier's text input before the
    /// first window opens.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        Log.startFileLog()
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        logger.info("Espalier \(version, privacy: .public) (\(build, privacy: .public)) started, process \(ProcessInfo.processInfo.processIdentifier)")
        ThemeApplier.apply(Preferences.storedTheme(in: PreferenceStore(.standard)), to: NSApplication.shared)
        BundledFonts.register()
        LookApplier.apply(Look.stored(in: PreferenceStore(.standard)))
        TextInputStyling.install()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installExternalEventHandlers()
        // Context clicks in every window open Espalier's menus.
        MenuEventRouter.shared.install()
        // Before launch finishes, so a notification click that launched
        // Espalier reaches it.
        NotificationRouter.shared.install()
        SyntaxHighlighting.defaultHighlighter = TreeSitterHighlighter()
        Task {
            do {
                let launched = try await AppBootstrap.launch()
                themeApplier = ThemeApplier(preferences: launched.model.preferences, target: NSApplication.shared)
                lookApplier = LookApplier(preferences: launched.model.preferences)
                self.launched = launched
            } catch {
                logger.error("Launch failed: \(error.localizedDescription, privacy: .public)")
                launchError = error.localizedDescription
            }
        }
    }

    // MARK: Opening

    /// The folders or URL Espalier was launched to open. AppKit passes the
    /// launch event here before `applicationDidFinishLaunching`, after
    /// SwiftUI opened the main window for it; the action runs once the
    /// window is up.
    public func application(_ application: NSApplication, open urls: [URL]) {
        deliver(ExternalAction.actions(for: urls))
    }

    /// Takes over "open documents" (folders opened from Finder or dropped
    /// on the Dock icon) and "get URL" (`espalier://` links) from AppKit
    /// once Espalier has launched.
    ///
    /// AppKit's handlers pass both to `application(_:open:)`, and SwiftUI
    /// routes them to a scene first: with the main window open, it closes
    /// that `Window` to open a new instance of its scene for the event, so
    /// the app's last window closes and Espalier quits. With these handlers
    /// SwiftUI never sees the events, and the window stays as it is.
    private func installExternalEventHandlers() {
        let manager = NSAppleEventManager.shared()
        let handler = #selector(handleExternalEvent(_:withReplyEvent:))
        manager.setEventHandler(self, andSelector: handler, forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
        manager.setEventHandler(self, andSelector: handler, forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// Runs the folders or URL an Apple event opens in the main window.
    @objc private func handleExternalEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        deliver(ExternalAction.actions(forAppleEvent: event))
    }

    private func deliver(_ actions: [ExternalAction]) {
        for action in actions {
            externalEvents.deliver(action)
        }
    }

    /// Clicking the Dock icon with no window open shows the main window.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            openMainWindow?()
        }
        return true
    }

    // MARK: Quitting

    /// Closing the main window quits (its delegate asks for termination, so
    /// this guard runs first); if it ever closes another way, quitting
    /// follows.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Asks first when an operation the user started runs or a commit
    /// message would be lost, then stops the app model.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let launched else {
            return .terminateNow
        }
        let alert = isTerminating ? nil : QuitGuard.reasons(launched.model).alert(launched.model.preferences.numberFormat)
        Task {
            if let alert {
                let response = await presentQuitAlert(alert)
                guard response.buttonIndex == 0 else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            isTerminating = true
            await launched.terminate()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Writes the rolling log's last batch.
    public func applicationWillTerminate(_ notification: Notification) {
        Log.fileLog?.flushNow()
    }

    /// The quit guard's alert: on the main window when it's showing, else
    /// on its own, app-modally.
    private func presentQuitAlert(_ content: AlertContent) async -> AlertResponse {
        if let context = mainWindowContext, let window = context.modals.window, window.isVisible {
            NSApp.activate()
            return await context.modals.alert(content)
        }
        NSApp.activate()
        return AppModalAlert.run(content)
    }
}
