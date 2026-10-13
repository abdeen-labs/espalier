// Settings ▸ Appearance's design theme, color, background tint, app font,
// and code font, applied to the app as the current look (`LookCenter`).
// SwiftUI views that read a theme's color or font draw again by themselves;
// AppKit views and the controllers of AppKit tables are told
// (`Look.didChange`), and every view of every window lays out and draws
// again. Menus, popovers, and tooltips take the new look the next time they
// open.

import AppKit
import EspalierCore
import Observation

extension Look {
    /// The look the settings choose.
    @MainActor
    init(preferences: Preferences) {
        self.init(
            theme: preferences.designTheme,
            color: preferences.designThemeColor,
            background: preferences.designThemeBackground,
            appFont: preferences.appFont,
            codeFont: preferences.codeFont
        )
    }

    /// The look stored in `store`, for the first windows, before the app
    /// model loads.
    static func stored(in store: PreferenceStore) -> Look {
        let theme = Preferences.storedDesignTheme(in: store)
        return Look(
            theme: theme,
            color: Preferences.storedDesignThemeColors(in: store)[theme],
            background: Preferences.storedDesignThemeBackgrounds(in: store)[theme] ?? .own,
            appFont: Preferences.storedAppFont(in: store),
            codeFont: Preferences.storedCodeFont(in: store)
        )
    }

    /// Posted on the main thread after the process's look changed.
    static let didChange = Notification.Name("EspalierLookDidChange")
}

/// An AppKit view that keeps what the look decides (colors in layers,
/// fonts in labels, heights) and redoes it when the look changes.
@MainActor
protocol LookChangeObserving: AnyObject {
    func lookDidChange()
}

/// Keeps the process's look on the one chosen in Settings: applies it at
/// once, then again each time the choice changes.
@MainActor @Observable
final class LookApplier {
    /// The look applied now.
    private(set) var look: Look

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let center: LookCenter

    init(preferences: Preferences, center: LookCenter = .shared) {
        self.preferences = preferences
        self.center = center
        look = center.look
        observe()
    }

    /// Makes `look` the process's, and tells the AppKit views.
    static func apply(_ look: Look, to center: LookCenter = .shared) {
        guard center.look != look else {
            return
        }
        center.look = look
        guard center === LookCenter.shared else {
            return
        }
        NotificationCenter.default.post(name: Look.didChange, object: nil)
        for window in NSApp?.windows ?? [] {
            if let frame = window.contentView?.superview ?? window.contentView {
                refresh(frame)
            }
        }
    }

    /// Tells `view` and every view in it that the look changed, and has them
    /// lay out and draw again.
    static func refresh(_ view: NSView) {
        (view as? LookChangeObserving)?.lookDidChange()
        if let textView = view as? NSTextView {
            // The selection, insertion point, and marked text.
            TextInputStyle.apply(to: textView)
        }
        view.needsLayout = true
        view.needsDisplay = true
        for subview in view.subviews {
            refresh(subview)
        }
    }

    private func observe() {
        let chosen = withObservationTracking {
            Look(preferences: preferences)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
        Self.apply(chosen, to: center)
        if look != chosen {
            look = chosen
        }
    }
}
