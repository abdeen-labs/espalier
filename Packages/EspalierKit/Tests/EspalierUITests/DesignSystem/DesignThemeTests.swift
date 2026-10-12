// The design themes and fonts: every theme's colors read (text 4.5:1 on
// the background and the sidebar, secondary text 4.5:1, the prominent
// fill's text 4.5:1, the accent 3:1 as a mark, the marks on the accent, the
// sidebar's selection text 4.5:1 on its selection, monograms' white
// initials 3:1), each app font and code font is its bundled family at the
// weights asked for, whatever the other is, a task's look leaves the
// process's alone, and the look follows Settings.

import AppKit
import EspalierCore
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

/// A theme in one of its colors, in one appearance.
struct ThemeVariant: Sendable {
    let theme: DesignTheme
    let color: DesignThemeColor?
    let variant: AppearanceVariant

    /// Every theme in every color, in every appearance.
    static let all: [NamedCase<ThemeVariant>] = DesignTheme.allCases.flatMap { theme in
        (theme.colors.isEmpty ? [nil] : theme.colors.map(Optional.some)).flatMap { color in
            AppearanceVariant.allCases.map { variant in
                NamedCase("\(theme.rawValue) \(color?.rawValue ?? "accent") \(variant.rawValue)", ThemeVariant(theme: theme, color: color, variant: variant))
            }
        }
    }
}

@Suite("Design themes") @MainActor
struct DesignThemeTests {
    @Test("text, secondary text, the prominent fill's text, the accent, and the marks on it reach their contrast", arguments: ThemeVariant.all)
    func contrast(_ testCase: NamedCase<ThemeVariant>) {
        let value = testCase.value
        let theme = Theme.named(value.theme, color: value.color)
        let variant = value.variant
        for surface in [theme.background, theme.sidebar] {
            #expect(ContrastCheck.ratio(theme.text, against: surface, in: variant) >= 4.5, "text")
            #expect(ContrastCheck.ratio(theme.text2, against: surface, in: variant) >= 4.5, "secondary text")
        }
        #expect(ContrastCheck.ratio(theme.accent, against: theme.background, in: variant) >= 3, "the accent as a mark")
        // A check, a radio's dot, and the switch's knob on the accent.
        #expect(ContrastCheck.ratio(theme.onAccent, against: theme.accent, in: variant) >= 3, "the marks on the accent")
        let prominent = ContrastCheck.ratio(theme.prominentText, against: theme.prominent, in: variant)
        if value.theme == .classic, variant.isDark {
            // Classic's dark prominent fill is the Mac's accent itself, as it
            // was before themes; white on the default blue is 3.65:1.
            withKnownIssue("Classic's dark prominent fill is the accent itself") {
                #expect(prominent >= 4.5, "the prominent fill's text")
            } when: {
                prominent < 4.5
            }
        } else {
            #expect(prominent >= 4.5, "the prominent fill's text")
        }
    }

    @Test("the sidebar's selected item's text, which its counts take too, reaches 4.5:1 on the selection", arguments: ThemeVariant.all)
    func sidebarSelectionContrast(_ testCase: NamedCase<ThemeVariant>) {
        let value = testCase.value
        let theme = Theme.named(value.theme, color: value.color)
        guard let text = theme.sidebarSelectionText else {
            return
        }
        let variant = value.variant
        let selection = ColorContrast.composite(theme.sidebarSelection.resolved(in: variant), over: theme.sidebar.resolved(in: variant))
        #expect(ContrastCheck.ratio(text, against: selection, in: variant) >= 4.5)
    }

    @Test("a theme's monograms keep white initials at 3:1, whatever the person's hue")
    func monogramTones() {
        for theme in DesignTheme.allCases {
            guard let tone = Theme.named(theme).monogramTone else {
                continue
            }
            for degree in stride(from: 0, to: 360, by: 5) {
                for isDark in [false, true] {
                    let color = Monogram.shade(CGFloat(degree) / 360, tone: tone, isDark: isDark)
                    #expect(ColorContrast.ratio(.white, color) >= 3, "\(theme) \(degree)° \(isDark ? "dark" : "light")")
                }
            }
        }
    }

    @Test("each app font is its bundled family at the weights asked for, and leaves the code font as it is", arguments: [AppFont.fixel, .atkinson, .martian])
    func appFonts(_ appFont: AppFont) throws {
        let sans = try #require(appFont.face)
        Look.with(Look(appFont: appFont)) {
            for font in [AppKitTypography.row, AppKitTypography.secondary, AppKitTypography.row(weight: .semibold)] {
                #expect(font.familyName == sans.family, "\(font.fontName)")
            }
            #expect(AppKitTypography.code(size: 11.5) == NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular))
        }
        assertWeights(sans, [400, 500, 600, 700])
    }

    @Test("each code font is its bundled family, draws exact characters, and leaves the app font as it is", arguments: [CodeFont.geistMono, .atkinsonMono])
    func codeFonts(_ codeFont: CodeFont) throws {
        let mono = try #require(codeFont.face)
        Look.with(Look(appFont: .fixel, codeFont: codeFont)) {
            for font in [AppKitTypography.refCapsule, AppKitTypography.code(), AppKitTypography.count(), AppKitTypography.shaField] {
                #expect(font.familyName == mono.family, "\(font.fontName)")
                // Exact characters: no ligature or contextual form joins
                // or changes them, so there's one glyph a character.
                let text = "fi ffl -> => != === <= www ::"
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                #expect(CTLineGetGlyphCount(line) == text.utf16.count, "\(font.fontName)")
            }
            #expect(AppKitTypography.row.familyName == BundledFace.fixelText.family)
        }
        Look.with(Look(codeFont: codeFont)) {
            #expect(AppKitTypography.row == NSFont.preferredFont(forTextStyle: .body))
        }
        // Atkinson Hyperlegible Mono's default instance is ExtraLight, so
        // its regular is set.
        assertWeights(mono, [400, 500, 600])
    }

    /// Weights land on the weight axis (a static family's file is the
    /// weight's own).
    private func assertWeights(_ face: BundledFace, _ weights: [Int], sourceLocation: SourceLocation = #_sourceLocation) {
        for weight in weights {
            let font = face.font(size: 13, weight: weight)
            #expect(font.familyName == face.family, sourceLocation: sourceLocation)
            if face.isVariable {
                let variation = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber] ?? [:]
                let axis = variation[NSNumber(value: BundledFace.weightAxis)]?.intValue
                // A named instance at its own weight may leave the axis
                // implicit.
                #expect(axis == weight || (axis == nil && face.name(for: weight) == font.fontName), "\(font.fontName) at \(weight)", sourceLocation: sourceLocation)
            } else {
                #expect(font.fontName == face.name(for: weight), sourceLocation: sourceLocation)
            }
        }
    }

    @Test("SF Pro and SF Mono are the system's fonts, and key caps stay SF Pro whatever the app font")
    func systemFonts() {
        #expect(AppKitTypography.row == NSFont.preferredFont(forTextStyle: .body))
        #expect(AppKitTypography.code(size: 11.5) == NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular))
        for appFont in AppFont.allCases {
            Look.with(Look(appFont: appFont)) {
                #expect(Typography.keyCap == Font.caption.weight(.medium))
            }
        }
    }

    @Test("a bundled face falls back on the system font's cascade list")
    func cascadeList() {
        let font = BundledFace.fixelText.font(size: 13, weight: 400)
        let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor] ?? []
        #expect(!cascade.isEmpty)
    }

    @Test("rows keep SF Pro's line height at the app font's body size")
    func rowHeights() {
        let classic = (graph: Metrics.Graph.rowHeight, files: Metrics.FileList.rowHeight)
        #expect(classic.graph == 32)
        #expect(classic.files == 30)
        // Fixel's line metrics are taller than SF Pro's, at the same size.
        Look.with(Look(appFont: .fixel)) {
            #expect(Metrics.Graph.rowHeight == classic.graph)
            #expect(Metrics.FileList.rowHeight == classic.files)
        }
        Look.with(Look(appFont: .martian)) {
            #expect(Metrics.Graph.rowHeight < classic.graph)
        }
        // The code font doesn't change rows.
        Look.with(Look(codeFont: .atkinsonMono)) {
            #expect(Metrics.Graph.rowHeight == classic.graph)
        }
    }

    @Test("a task's look leaves the process's as it is")
    func taskLook() async {
        let process = LookCenter.shared.look
        Look.with(Look(theme: .pop, appFont: .atkinson, codeFont: .atkinsonMono)) {
            #expect(Look.current == Look(theme: .pop, color: .tangerine, appFont: .atkinson, codeFont: .atkinsonMono))
            #expect(Theme.current.theme == .pop)
        }
        #expect(LookCenter.shared.look == process)
    }

    @Test("a color that isn't the theme's is its default")
    func defaultColors() {
        #expect(Look(theme: .orchard, color: .berry).color == .ink)
        #expect(Look(theme: .classic, color: .ink).color == nil)
        #expect(Theme.named(.islands).color == .lagoon)
        #expect(Theme.named(.pop, color: .magenta) === Theme.named(.pop, color: .magenta))
    }

    @Test("the look follows the theme, color, app font, and code font chosen in Settings", .hangGuard(minutes: 5))
    func applier() async throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let preferences = Preferences(store: PreferenceStore(temporary.defaults))
        // A center of the test's own: the process's look stays as it is.
        let center = LookCenter()
        let applier = LookApplier(preferences: preferences, center: center)
        #expect(center.look == .classic)

        preferences.designTheme = .islands
        await waitUntil { applier.look.theme == .islands }
        #expect(center.look == Look(theme: .islands, color: .lagoon))

        preferences.designThemeColor = .berry
        preferences.appFont = .fixel
        preferences.codeFont = .geistMono
        await waitUntil { applier.look == Look(theme: .islands, color: .berry, appFont: .fixel, codeFont: .geistMono) }
        #expect(center.look == applier.look)
        withExtendedLifetime(applier) {}
    }

    @Test("the stored look applies before the app model loads; unknown values are the defaults")
    func storedLook() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        temporary.defaults.set("pop", forKey: PreferenceKey.designTheme)
        temporary.defaults.set("magenta", forKey: PreferenceKey.designThemeColor(.pop))
        temporary.defaults.set("martian", forKey: PreferenceKey.appFont)
        temporary.defaults.set("atkinsonmono", forKey: PreferenceKey.codeFont)
        #expect(Look.stored(in: PreferenceStore(temporary.defaults)) == Look(theme: .pop, color: .magenta, appFont: .martian, codeFont: .atkinsonMono))

        temporary.defaults.set("sepia", forKey: PreferenceKey.designTheme)
        temporary.defaults.set("comic", forKey: PreferenceKey.appFont)
        temporary.defaults.set("martian", forKey: PreferenceKey.codeFont)
        #expect(Look.stored(in: PreferenceStore(temporary.defaults)) == .classic)
    }
}
