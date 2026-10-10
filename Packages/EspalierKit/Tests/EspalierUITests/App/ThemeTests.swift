// Settings ▸ Appearance's theme applied to the app: System until Light or
// Dark is chosen, each applied at once, with Espalier's colors resolving in
// it. The application's stand-in is an offscreen window, whose views take
// its appearance as the app's windows take the application's.

import AppKit
import EspalierCore
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Theme", .hangGuard(minutes: 5)) @MainActor
struct ThemeTests {
    /// An offscreen window with a view in it.
    private func target() -> (NSWindow, NSView) {
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSView(frame: window.contentLayoutRect)
        window.contentView = view
        return (window, view)
    }

    /// Whether `view` draws dark.
    private func isDark(_ view: NSView) -> Bool {
        AppearanceVariant.of(view.effectiveAppearance).isDark
    }

    @Test("the app follows the Mac until Light or Dark is chosen, which applies at once; System clears the app's appearance")
    func applies() async throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let preferences = Preferences(store: PreferenceStore(temporary.defaults))
        let (window, view) = target()
        defer { withExtendedLifetime(window) {} }

        let applier = ThemeApplier(preferences: preferences, target: window)
        #expect(applier.theme == .system)
        #expect(window.appearance == nil)

        preferences.theme = .dark
        await waitUntil { applier.theme == .dark }
        #expect(window.appearance?.name == .darkAqua)
        #expect(isDark(view))
        // Espalier's colors resolve in the chosen appearance, whatever the
        // Mac's is.
        var background: NSColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = Palette.background.usingColorSpace(.sRGB)
        }
        #expect(background != nil)
        #expect(background != Palette.background.resolved(in: .light))

        preferences.theme = .light
        await waitUntil { applier.theme == .light }
        #expect(window.appearance?.name == .aqua)
        #expect(!isDark(view))

        preferences.theme = .system
        await waitUntil { applier.theme == .system }
        #expect(window.appearance == nil)
        withExtendedLifetime(applier) {}
    }

    @Test("the stored theme applies before the app model loads")
    func storedTheme() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let (window, view) = target()
        defer { withExtendedLifetime(window) {} }

        temporary.defaults.set("dark", forKey: PreferenceKey.theme)
        ThemeApplier.apply(Preferences.storedTheme(in: PreferenceStore(temporary.defaults)), to: window)
        #expect(window.appearance?.name == .darkAqua)
        #expect(isDark(view))

        temporary.defaults.set("system", forKey: PreferenceKey.theme)
        ThemeApplier.apply(Preferences.storedTheme(in: PreferenceStore(temporary.defaults)), to: window)
        #expect(window.appearance == nil)
    }
}
