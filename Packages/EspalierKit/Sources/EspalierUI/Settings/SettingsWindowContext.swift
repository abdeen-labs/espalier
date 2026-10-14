// The Settings window's context. Settings is a window of its own, so it gets
// its own `WindowContext`: a presenter, an action router, and a modal
// presenter whose alerts and sheets cover the Settings window, not the main
// window. Panes use it exactly as the main window's views use theirs
// (`@Environment(WindowContext.self)`, `context.presenter.perform`,
// `context.modals.presentSheet(id:)`, `context.actions.perform`).

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// Makes the Settings window's context.
@MainActor
enum SettingsWindowContext {
    /// A context for the Settings window.
    ///
    /// It registers only the actions Settings can reach: the shell's app
    /// actions (`.openSettings` selects a pane, so a recovery shown in
    /// Settings opens its pane; About; Show Logs in Finder), GitHub's
    /// (signing in from Accounts and from recoveries), and the command line
    /// tool's installer. The main window keeps navigation, sync, and
    /// the repository's actions, and the menus never read this context (it
    /// isn't a focused scene value), so they disable themselves while
    /// Settings is key.
    static func make(app: AppModel, navigation: SettingsNavigation) -> WindowContext {
        let context = WindowContext(app: app, settingsNavigation: navigation, registersFeatures: false)
        let actions = context.actions
        ShellActions.registerApp(into: actions, context: context)
        GitHubActions.register(into: actions, context: context)
        CommandLineToolInstaller.register(into: actions, context: context)
        return context
    }
}

/// Shows the Settings presenter's confirmations, decisions (which editor
/// opens the global Git config), and errors on the Settings window. Prompts
/// git waits on and state notices belong to the main window, so they aren't
/// shown twice. While a modal shows, VoiceOver can't reach the window behind
/// it.
struct SettingsPresentationHosts: ViewModifier {
    let context: WindowContext

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(context.modals.isPresenting)
            .onChange(of: context.presenter.confirmation?.id, initial: true) {
                if let pending = context.presenter.confirmation {
                    ConfirmationHost.present(pending, in: context)
                }
            }
            .onChange(of: context.presenter.decision?.id, initial: true) {
                if let pending = context.presenter.decision {
                    DecisionHost.present(pending, in: context)
                }
            }
            .onChange(of: context.presenter.error?.id, initial: true) {
                if let presented = context.presenter.error {
                    ErrorHost.present(presented, in: context)
                }
            }
    }
}

/// Gives the Settings context's modal presenter the Settings window, keeps
/// the window on its screen, and looks up the installed editors and shells
/// again when it opens.
struct SettingsWindowReader: NSViewRepresentable {
    let context: WindowContext

    func makeCoordinator() -> SettingsWindowObservers {
        SettingsWindowObservers()
    }

    func makeNSView(context representableContext: Context) -> WindowObserverView {
        let view = WindowObserverView()
        let observers = representableContext.coordinator
        view.onWindow = { [weak context, weak observers] window in
            guard let context, let observers else {
                return
            }
            context.modals.window = window
            observers.fitter.follow(window)
            observers.lookups.follow(window, app: context.app)
        }
        return view
    }

    func updateNSView(_ view: WindowObserverView, context representableContext: Context) {}
}

/// The Settings window's observers.
@MainActor
final class SettingsWindowObservers {
    let fitter = SettingsWindowFitter()
    let lookups = SettingsWindowLookups()
}

/// Looks up the installed editors and shells again each time the Settings
/// window becomes key: when Settings opens, and when the user comes back to
/// it, perhaps from installing one.
@MainActor
final class SettingsWindowLookups {
    private var observer: (any NSObjectProtocol)?

    func follow(_ window: NSWindow, app: AppModel) {
        guard observer == nil else {
            return
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak app] _ in
            MainActor.assumeIsolated {
                app?.integrations.lookUpIntegrationsAgain()
            }
        }
        if window.isKeyWindow {
            app.integrations.lookUpIntegrationsAgain()
        }
    }

    isolated deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// Keeps the Settings window on its screen: a window that would run past
/// the bottom of a small display (it opens where it was last, and keeps its
/// top edge as it grows) moves up instead.
@MainActor
final class SettingsWindowFitter {
    private var observer: (any NSObjectProtocol)?

    func follow(_ window: NSWindow) {
        guard observer == nil else {
            return
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window, let visible = window.screen?.visibleFrame else {
                    return
                }
                let fitted = Self.fitted(window.frame, in: visible)
                if fitted != window.frame {
                    window.setFrame(fitted, display: true, animate: false)
                }
            }
        }
    }

    isolated deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// `frame` moved up so its bottom edge is on `visible`'s, or, when it's
    /// taller than `visible`, so its top edge is on `visible`'s top (AppKit's
    /// coordinates, y upward). A frame already inside stays where it is.
    nonisolated static func fitted(_ frame: CGRect, in visible: CGRect) -> CGRect {
        guard frame.minY < visible.minY else {
            return frame
        }
        var fitted = frame
        fitted.origin.y = frame.height <= visible.height ? visible.minY : visible.maxY - frame.height
        return fitted
    }
}

/// Gives the Settings window its flat chrome, from the moment it opens
/// (while Espalier launches too).
struct SettingsWindowChromeReader: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindow = { window in
            SettingsWindowChrome.apply(to: window)
        }
        return view
    }

    func updateNSView(_ view: WindowObserverView, context: Context) {}
}

/// The Settings window's chrome: no visible titlebar. The content fills the
/// window, under a transparent titlebar as high as the main window's
/// toolbar (an empty unified toolbar), so the window's buttons sit in the
/// sidebar's top band, level with the pane's name in its header band. The
/// title stays the pane's name, for the Window menu and VoiceOver, but
/// isn't drawn.
@MainActor
enum SettingsWindowChrome {
    static let toolbarIdentifier = "espalier.settings"

    /// Makes `window`'s titlebar transparent at once, and its content fill
    /// the window right after: changing the window's frame inside
    /// SwiftUI's layout would lay it out again from within it.
    static func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        DispatchQueue.main.async { [weak window] in
            if let window {
                fillWindow(window)
            }
        }
    }

    /// The content under the titlebar, and the titlebar as high as a
    /// toolbar.
    static func fillWindow(_ window: NSWindow) {
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: toolbarIdentifier)
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
        }
        if window.toolbarStyle != .unified {
            window.toolbarStyle = .unified
        }
    }
}

extension View {
    /// Attaches the Settings window's presentation: its context's
    /// environment, its hosts, and its window.
    func settingsWindow(_ context: WindowContext) -> some View {
        windowEnvironment(context)
            .modifier(SettingsPresentationHosts(context: context))
            .background(SettingsWindowReader(context: context))
    }
}
