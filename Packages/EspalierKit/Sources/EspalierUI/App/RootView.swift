// The main window's root. It shows launching, a launch failure, the welcome
// flow, or the main window, and gives the window its context, presenter
// hosts, and menus' focused value. The welcome flow and the main window
// crossfade over 0.22 s, the window's toolbar with them.

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// The single main window's content.
public struct RootView: View {
    private let model: AppModel?
    private let launchError: String?
    private let settingsNavigation: SettingsNavigation
    private let onWindowContext: (WindowContext) -> Void

    /// - Parameters:
    ///   - model: The app model, once launched.
    ///   - launchError: Why launching failed, if it did.
    ///   - settingsNavigation: The Settings scene's pane selection.
    ///   - onWindowContext: Receives the window's context once it exists.
    public init(
        model: AppModel? = nil,
        launchError: String? = nil,
        settingsNavigation: SettingsNavigation = SettingsNavigation(),
        onWindowContext: @escaping (WindowContext) -> Void = { _ in }
    ) {
        self.model = model
        self.launchError = launchError
        self.settingsNavigation = settingsNavigation
        self.onWindowContext = onWindowContext
    }

    public var body: some View {
        Group {
            if let launchError {
                LaunchErrorView(message: launchError)
            } else if let model {
                WindowRoot(model: model, settingsNavigation: settingsNavigation, onWindowContext: onWindowContext)
            } else {
                LaunchView()
            }
        }
        .frame(minWidth: Metrics.Window.minimumWidth, minHeight: Metrics.Window.minimumHeight)
    }
}

/// The window once the app model exists.
struct WindowRoot: View {
    @State private var context: WindowContext
    private let onWindowContext: (WindowContext) -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init(model: AppModel, settingsNavigation: SettingsNavigation, onWindowContext: @escaping (WindowContext) -> Void) {
        _context = State(initialValue: WindowContext(app: model, settingsNavigation: settingsNavigation))
        self.onWindowContext = onWindowContext
    }

    var body: some View {
        content
            .windowEnvironment(context)
            .presentationHosts(context)
            .focusedSceneValue(context)
            .background(WindowObserver(context: context))
            .onAppear {
                context.openWindow = openWindow
                context.openSettingsAction = openSettings
                onWindowContext(context)
                MoveToApplicationsPrompt.presentIfNeeded(in: context)
            }
            .onChange(of: context.showsWelcome) {
                context.modals.window?.crossfadeContents(Motion.arrive)
            }
    }

    @ViewBuilder
    private var content: some View {
        if context.showsWelcome {
            // The welcome flow fills the window.
            WelcomeView()
        } else {
            MainWindow()
        }
    }
}

extension NSWindow {
    /// Crossfades the window's next change of contents, its title bar and
    /// toolbar included, over `duration` on the curve, when motion runs in
    /// it.
    func crossfadeContents(_ duration: TimeInterval) {
        guard let contentView, Motion.animates(contentView) else {
            return
        }
        Motion.crossfade(contentView.superview?.layer ?? contentView.layer, duration: duration)
    }
}
