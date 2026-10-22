// Everything one window's views share: the app model, the window's UI
// state, its presenter, its action router, and its modal presenter.

import EspalierCore
import GitKit
import Observation
import SwiftUI

/// One window's shared objects. Views get it from the environment
/// (`@Environment(WindowContext.self)`).
@MainActor @Observable
public final class WindowContext {
    public let app: AppModel
    /// Navigation and UI state.
    public let state: WindowState
    /// Runs intents and shows their confirmations, decisions, and errors.
    public let presenter: WindowPresenter
    /// Routes actions to features.
    public let actions: WindowActions
    /// Shows alerts and sheets on the window.
    @ObservationIgnored public let modals: ModalPresenter
    /// Shows the prompts git waits on.
    @ObservationIgnored lazy var promptHost = PromptHost(context: self)
    /// Where avatars come from.
    @ObservationIgnored public var avatarLoader: any AvatarLoading = GitHubAvatarLoader.shared
    /// Where VoiceOver announcements go.
    @ObservationIgnored var announcer: Announcer = .voiceOver

    /// SwiftUI's window and settings actions, captured from the window's
    /// environment.
    @ObservationIgnored public var openWindow: OpenWindowAction?
    @ObservationIgnored public var openSettingsAction: OpenSettingsAction?
    /// Which Settings pane opens.
    @ObservationIgnored public let settingsNavigation: SettingsNavigation

    /// Where the window keeps its UI state (sidebar sections' expansion,
    /// Clone's source): the app's defaults, the standard ones in the app
    /// and a test's own domain under the harness.
    public var uiDefaults: UserDefaults {
        app.environment.defaults.defaults
    }

    /// Whether the window's state persists where AppKit saves its own (split
    /// dividers): only with the standard defaults.
    public var persistsUIState: Bool {
        uiDefaults === UserDefaults.standard
    }

    /// - Parameters:
    ///   - app: The app model.
    ///   - settingsNavigation: The Settings scene's pane selection.
    ///   - registersFeatures: Whether to register every feature's action
    ///     handlers (tests of the router pass false).
    public init(app: AppModel, settingsNavigation: SettingsNavigation = SettingsNavigation(), registersFeatures: Bool = true) {
        self.app = app
        self.settingsNavigation = settingsNavigation
        state = WindowState()
        let actions = WindowActions()
        self.actions = actions
        presenter = WindowPresenter(app: app, actions: actions)
        modals = ModalPresenter()
        state.isRailHidden = uiDefaults.bool(forKey: WindowState.sidebarHiddenKey)

        actions.availability = { [weak self] kind in
            guard let self else {
                return false
            }
            return CommandAvailability(context: self).isEnabled(kind)
        }
        actions.stateTitle = { [weak self] action in
            guard let self else {
                return nil
            }
            return CommandAvailability(context: self).title(for: action)
        }
        actions.stateReason = { [weak self] action in
            guard let self else {
                return nil
            }
            return CommandAvailability(context: self).reason(for: action)
        }
        actions.isModalPresented = { [weak self] in
            self?.isModalPresented ?? false
        }
        actions.onRefused = { [weak self] reason in
            self?.presenter.show(.refused(reason))
        }
        modals.environment = { [weak self] content in
            guard let self else {
                return content
            }
            return AnyView(content.windowEnvironment(self))
        }
        presenter.reportOutcome = { [weak self] outcome in
            guard let self else {
                return
            }
            OperationOutcomes.report(outcome, in: self)
        }
        if registersFeatures {
            FeatureActions.registerAll(into: actions, context: self)
        }
    }

    /// The selected repository's model.
    public var repository: RepositoryModel? {
        app.selectedRepository
    }

    /// Whether a confirmation, decision, error, prompt, or sheet is showing:
    /// the menus disable themselves.
    public var isModalPresented: Bool {
        presenter.isPresentingModal || modals.isPresenting || app.prompts.current != nil
    }

    // MARK: Capabilities

    /// Bumped when anything the capabilities read changes, so the menus
    /// that read them update.
    private var capabilitiesGeneration = 0
    @ObservationIgnored private var cachedCapabilities: RepositoryCapabilities?

    /// The menu bar's capabilities, computed once per change of what they
    /// read rather than once per menu item: the rules scan the changed
    /// files, and a menu has dozens of items.
    var capabilities: RepositoryCapabilities {
        _ = capabilitiesGeneration
        if let cachedCapabilities {
            return cachedCapabilities
        }
        let capabilities = withObservationTracking {
            app.capabilities(isModalPresented: isModalPresented)
        } onChange: { [weak self] in
            // The models are main-actor isolated, so their changes (and
            // this) happen on the main thread.
            MainActor.assumeIsolated {
                self?.invalidateCapabilities()
            }
        }
        cachedCapabilities = capabilities
        return capabilities
    }

    private func invalidateCapabilities() {
        cachedCapabilities = nil
        capabilitiesGeneration &+= 1
    }

    // MARK: Navigation

    /// Shows `place` in the selected repository.
    public func select(_ place: SidebarPlace) {
        state.select(place, in: repository?.id)
    }

    // MARK: Sidebar

    /// The sidebar's form (Settings ▸ Appearance ▸ Sidebar).
    var sidebarStyle: SidebarStyle {
        app.preferences.sidebarStyle
    }

    /// Whether the sidebar is hidden: its column, or the icons style's
    /// rail. Changes and History are in the toolbar while it is.
    var isSidebarHidden: Bool {
        switch sidebarStyle {
        case .hidden: state.columnVisibility == .detailOnly
        case .icons: state.isRailHidden
        }
    }

    /// Brings the window back: out of the Dock if it's minimized, then to
    /// the front as the key window.
    public func revealWindow() {
        guard let window = modals.window else {
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens Settings at `pane` (nil: the last one).
    public func openSettings(_ pane: SettingsPane? = nil) {
        if let pane {
            settingsNavigation.select(pane)
        }
        openSettingsAction?()
    }
}

extension View {
    /// The environment every view of a window gets: the context, and the
    /// values derived from the settings. Sheets shown through
    /// `ModalPresenter` and panes hosted in `SplitView` get it too.
    public func windowEnvironment(_ context: WindowContext) -> some View {
        modifier(WindowEnvironment(context: context))
    }
}

/// Applies a window's environment.
struct WindowEnvironment: ViewModifier {
    let context: WindowContext

    func body(content: Content) -> some View {
        let preferences = context.app.preferences
        content
            .environment(context)
            .defaultAppStorage(context.uiDefaults)
            .environment(\.dateTimeFormatting, DateTimeFormatting(
                preferAbsoluteDates: preferences.preferAbsoluteDates,
                dateFormat: preferences.dateFormat,
                timeFormat: preferences.timeFormat
            ))
            .environment(\.numberFormat, preferences.numberFormat)
            .environment(\.avatarLoader, context.avatarLoader)
            .environment(\.announcer, context.announcer)
            .environment(\.scheduler, context.app.environment.scheduler)
            .lookFont()
    }
}
