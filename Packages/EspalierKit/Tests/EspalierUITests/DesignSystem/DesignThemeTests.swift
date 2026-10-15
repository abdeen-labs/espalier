// The design themes' contrast: every theme's colors read in every color
// and background tint (text 4.5:1 on the background and the sidebar,
// secondary text 4.5:1, the prominent fill's text 4.5:1, the accent 3:1 as a
// mark, the marks on the accent, the sidebar's selection text 4.5:1 on its
// selection), and monograms' white initials reach 3:1.

import AppKit
import EspalierCore
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

/// A theme in one of its colors and background tints, in one appearance.
struct ThemeVariant: Sendable {
    let theme: DesignTheme
    let color: DesignThemeColor?
    let background: BackgroundTint
    let variant: AppearanceVariant

    /// Every theme in every color and background tint, in every appearance.
    static let all: [NamedCase<ThemeVariant>] = DesignTheme.allCases.flatMap { theme in
        (theme.colors.isEmpty ? [nil] : theme.colors.map(Optional.some)).flatMap { color in
            BackgroundTint.allCases.flatMap { background in
                AppearanceVariant.allCases.map { variant in
                    NamedCase(
                        "\(theme.rawValue) \(color?.rawValue ?? "accent") \(background.rawValue) \(variant.rawValue)",
                        ThemeVariant(theme: theme, color: color, background: background, variant: variant)
                    )
                }
            }
        }
    }

    var themeValue: Theme {
        Theme.named(theme, color: color, background: background)
    }
}

@Suite("Design themes") @MainActor
struct DesignThemeTests {
    @Test("text, secondary text, the prominent fill's text, the accent, and the marks on it reach their contrast", arguments: ThemeVariant.all)
    func contrast(_ testCase: NamedCase<ThemeVariant>) {
        let value = testCase.value
        let theme = value.themeValue
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
        let theme = value.themeValue
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
}
