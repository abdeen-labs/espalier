// Espalier's scenes: one main window, Settings, and About. Everything else
// is a sheet, popover, or alert on the main window.

import EspalierCore
import GitKit
import SwiftUI

/// Espalier's scenes. The app target's `App` body is just this.
public struct EspalierScenes: Scene {
    /// The main window's identifier.
    public static let mainWindowID = "main"
    /// The About window's identifier.
    public static let aboutWindowID = "about"
    /// The Acknowledgements window's identifier (About's Acknowledgements…).
    public static let acknowledgementsWindowID = "acknowledgements"

    private let delegate: EspalierAppDelegate

    public init(delegate: EspalierAppDelegate) {
        self.delegate = delegate
        // Before the main window and its toolbar exist.
        FlatWindowChrome.install()
    }

    public var body: some Scene {
        Window("Espalier", id: Self.mainWindowID) {
            MainWindowScene(delegate: delegate)
        }
        .defaultSize(width: Metrics.Window.defaultWidth, height: Metrics.Window.defaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            // With the main window minimized (no window key), the menus act
            // on the main window and bring it back.
            EspalierCommands(mainWindowContext: { [delegate] in delegate.mainWindowContext })
        }

        Settings {
            SettingsView(model: delegate.launched?.model)
                .environment(delegate.settingsNavigation)
        }

        Window("About Espalier", id: Self.aboutWindowID) {
            AboutWindow()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        // A window of its own, as other Mac apps' acknowledgements are (a
        // sheet would dwarf the small About window).
        Window("Acknowledgements", id: Self.acknowledgementsWindowID) {
            AcknowledgementsView()
        }
        .defaultSize(width: Metrics.About.acknowledgementsWidth, height: Metrics.About.acknowledgementsHeight)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
    }
}

/// The main window's root, which also gives the delegate the window's
/// context and a way to reopen it.
private struct MainWindowScene: View {
    let delegate: EspalierAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView(
            model: delegate.launched?.model,
            launchError: delegate.launchError,
            settingsNavigation: delegate.settingsNavigation,
            onWindowContext: { context in
                delegate.mainWindowContext = context
            }
        )
        .onAppear {
            let openWindow = openWindow
            delegate.openMainWindow = {
                openWindow(id: EspalierScenes.mainWindowID)
            }
        }
    }
}
