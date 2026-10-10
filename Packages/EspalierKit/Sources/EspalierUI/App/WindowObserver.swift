// Connects the main window's `NSWindow` to the app. Window occlusion goes to
// `AppModel.setMainWindowVisible` (the watcher runs only while the window is
// visible); closing the window quits Espalier after the quit guard, so
// Cancel keeps the window open; modals attach to the window; a click away
// from a text field ends its editing (`ClickAwayFocus`).

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// Finds the window the view is in and connects it.
struct WindowObserver: NSViewRepresentable {
    let context: WindowContext

    func makeNSView(context representableContext: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindow = { [weak context] window in
            context.map { MainWindowConnection.connect(window, to: $0) }
        }
        return view
    }

    func updateNSView(_ view: WindowObserverView, context representableContext: Context) {}
}

/// A view that reports the window it moves into.
final class WindowObserverView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindow?(window)
        }
    }
}

/// The main window's connections to the app.
@MainActor
enum MainWindowConnection {
    private static var connections: [ObjectIdentifier: Connection] = [:]

    /// Connects `window` to `context`, once.
    static func connect(_ window: NSWindow, to context: WindowContext) {
        context.modals.window = window
        FlatWindowChrome.apply(to: window)
        let key = ObjectIdentifier(window)
        if let connection = connections[key] {
            connection.installDelegate()
            return
        }
        let connection = Connection(window: window, context: context)
        connections[key] = connection
        connection.start()
    }

    /// One window's observers and delegate proxy.
    final class Connection {
        private weak var window: NSWindow?
        private weak var context: WindowContext?
        private let proxy = MainWindowDelegateProxy()
        private var observers: [any NSObjectProtocol] = []
        /// Runs ⌘J, ⌥⌘F, ⌃⇥, and ⇧⌃⇥ in the window, whatever holds them.
        private var shortcutMonitor: Any?
        /// Pops up the focused table's row menu on ⇧F10.
        private var contextMenuMonitor: Any?
        /// Ends a text field's editing on a click away from it.
        private var clickAwayMonitor: Any?

        init(window: NSWindow, context: WindowContext) {
            self.window = window
            self.context = context
        }

        /// Connects the window. This runs while SwiftUI lays the window out,
        /// so it must not change the window's frame (that lays the window out
        /// again from inside its layout). SwiftUI saves and restores the
        /// frame itself, under the scene's identifier.
        func start() {
            installDelegate()
            reportVisibility()
            if let context {
                shortcutMonitor = ContestedShortcuts.install(for: context)
                contextMenuMonitor = KeyboardContextMenu.install(for: context)
            }
            if let window {
                clickAwayMonitor = ClickAwayFocus.install(in: window)
            }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reportVisibility()
                    }
                },
                // SwiftUI may set its own delegate again; the proxy goes back
                // in front of it.
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.installDelegate()
                    }
                },
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.context?.app.setMainWindowVisible(false)
                    }
                },
            ]
        }

        /// Puts the proxy in front of the window's delegate.
        func installDelegate() {
            guard let window, !(window.delegate is MainWindowDelegateProxy) else {
                return
            }
            proxy.original = window.delegate
            window.delegate = proxy
        }

        private func reportVisibility() {
            guard let window, let context else {
                return
            }
            context.app.setMainWindowVisible(window.occlusionState.contains(.visible))
        }
    }
}

/// The main window's delegate: closing the window quits Espalier, so the
/// quit guard runs first and Cancel keeps the window open. Every other
/// delegate message goes to the delegate SwiftUI installed.
final class MainWindowDelegateProxy: NSObject, NSWindowDelegate {
    /// SwiftUI's delegate. Set and read on the main thread only; the
    /// Objective-C runtime asks `responds(to:)` and `forwardingTarget(for:)`
    /// there too, for window delegate messages.
    nonisolated(unsafe) weak var original: (any NSWindowDelegate)?

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) {
            return original
        }
        return super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           original.windowShouldClose?(sender) == false {
            return false
        }
        // Quitting asks first when work would be lost
        // (`applicationShouldTerminate`), and closes the window when it
        // goes ahead; the window stays open meanwhile.
        AppTermination.quit()
        return false
    }
}

/// Quitting from code.
@MainActor
enum AppTermination {
    /// Quits as the Quit menu item does, from the run loop. The quit guard
    /// answers `terminateLater` and replies from a main-actor task, which
    /// runs only once the main queue is free, but `terminate(_:)` waits for
    /// that reply where it's called: called from a main-queue block or a
    /// main-actor task, it never gets it, and the app hangs with its window
    /// open. A delayed perform runs from a run loop timer instead.
    static func quit() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
}
