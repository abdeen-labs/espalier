// Settings ▸ Appearance's theme, applied to the app. Windows, sheets,
// popovers, menus, and alerts take the application's appearance unless they
// set their own, so they all follow the theme;
// System leaves the application's appearance unset, so they follow the
// Mac's.

import AppKit
import EspalierCore
import Observation

extension ApplicationTheme {
    /// The appearance the theme gives the app; nil, the Mac's, for System.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The choice's name in Settings.
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Keeps an app's appearance on the theme chosen in Settings: applies it at
/// once, then again each time the choice changes.
@MainActor @Observable
final class ThemeApplier {
    /// The theme applied now.
    private(set) var theme: ApplicationTheme

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let target: any NSAppearanceCustomization

    /// - Parameter target: What takes the appearance: the application.
    init(preferences: Preferences, target: any NSAppearanceCustomization) {
        self.preferences = preferences
        self.target = target
        theme = preferences.theme
        observe()
    }

    /// Gives `target` the theme's appearance.
    static func apply(_ theme: ApplicationTheme, to target: any NSAppearanceCustomization) {
        let appearance = theme.appearance
        guard target.appearance?.name != appearance?.name else {
            return
        }
        target.appearance = appearance
    }

    /// Applies the chosen theme, and applies it again when it changes.
    private func observe() {
        let chosen = withObservationTracking {
            preferences.theme
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
        Self.apply(chosen, to: target)
        if theme != chosen {
            theme = chosen
        }
    }
}
