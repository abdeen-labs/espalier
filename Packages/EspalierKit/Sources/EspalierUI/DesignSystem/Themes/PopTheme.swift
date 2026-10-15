// Pop: bright and confident. Crisp white panes, a sidebar tinted with the
// accent, and saturated color in solid shapes: the prominent action, ref
// tags, file badges, monograms, and a bold graph whose current commit has
// a halo. Section labels and the sidebar's counts take the accent's ink; a
// selected row is a tint with a bar in the accent at its leading edge, the
// sidebar's bold. Buttons are semibold, the prominent one bold. Colors:
// Tangerine (the default), Electric, Magenta.

import AppKit
import EspalierCore
import SwiftUI

nonisolated extension ThemeDefinition {
    static func pop(_ color: DesignThemeColor) -> ThemeDefinition {
        let palette = PopColor(color)
        return ThemeDefinition(
            theme: .pop,
            color: palette.color,
            background: ThemeColor.surface(0xFFFFFF, 0x16161C),
            sidebar: palette.sidebar,
            sidebarTakesTint: false,
            field: ThemeColor.fill(0xF1F1F5, 0x23232B),
            hunk: ThemeColor.surface(0xF5F5F9, 0x1C1C23),
            hover: ThemeColor.wash(.hex(0x141428), 0.045, .white, 0.05),
            line: ThemeColor.line(0xECECF1, 0x26262F),
            line2: ThemeColor.line2(0xD9D9E1, 0x363641),
            quiet: ThemeColor.surface(0xFFFFFF, 0x23232B),
            soft: ThemeColor.fill(0xEBEBF0, 0x2A2A33),
            scrim: .espalierDynamic(light: NSColor.black.withAlphaComponent(0.2), dark: NSColor.black.withAlphaComponent(0.45)),
            text: ThemeColor.text(0x16161D, 0xEEEEF3),
            text2: ThemeColor.text2(0x5D5D6C, 0xA4A4B4),
            text3: ThemeColor.text3(0x9898A6, 0x6F6F80, text2: (0x5D5D6C, 0xA4A4B4)),
            accent: palette.accent,
            linkBase: palette.ink,
            accentSoftAlpha: palette.selectionAlpha,
            // Secondary text keeps 4.5:1 on it, in a field too.
            textSelectionAlpha: (0.15, 0.18),
            prominent: palette.prominent,
            prominentText: palette.prominentText,
            onAccent: palette.onAccent,
            add: ThemeColor.fixed(0x17936A, 0x3CCB98),
            delete: palette.delete,
            modified: ThemeColor.fixed(0xFFC53D, 0xF2B23A),
            renamed: palette.accent,
            trunk: ThemeColor.fixed(0x17936A, 0x3CCB98),
            tones: palette.tones,
            toneColors: palette.toneColors,
            sidebarSelection: palette.sidebarSelection,
            sidebarSelectionText: palette.sidebarSelectionText,
            sidebarSelectionIcon: palette.sidebarSelectionIcon,
            selectionBar: true,
            sidebarSelectionIsBold: true,
            sidebarSelectionTintsCounts: true,
            sidebarText3: palette.sidebarText3,
            aheadText: palette.ink,
            sectionLabel: SectionLabelStyle(isUppercase: true, size: 10.75, weight: .bold, tracking: 0.08, color: palette.label),
            radii: ThemeRadii(row: 10, card: 14, small: 5, tag: nil),
            commitTitle: TitleStyle(size: 18, weight: .bold),
            buttonWeights: ButtonWeights(quiet: .semibold, prominent: .bold),
            graph: GraphStyle(lineWidth: 4, lanePitch: 17, node: .haloedDot),
            refTag: RefTagStyle(fill: .solid(darken: 0.10), currentUsesProminent: true),
            statusBadge: StatusBadgeStyle(fill: .solid, shape: .roundedSquare),
            // Saturated, as solid as the tags and badges.
            monogramTone: MonogramTone(saturation: (0.75, 0.62), lightness: (0.50, 0.48))
        )
    }
}

/// A Pop color's values, light and dark.
nonisolated private struct PopColor {
    let color: DesignThemeColor
    let accent: NSColor
    let ink: NSColor
    let prominent: NSColor
    let prominentText: NSColor
    /// The check, dash, radio dot, and switch knob on the accent.
    let onAccent: NSColor
    /// The sidebar, tinted with the accent.
    let sidebar: NSColor
    let selectionAlpha: (light: CGFloat, dark: CGFloat)
    let sidebarSelection: NSColor
    let sidebarSelectionText: NSColor
    let sidebarSelectionIcon: NSColor
    /// Section labels: the accent's ink, three quarters over the sidebar.
    let label: NSColor
    /// The sidebar's tertiary text (counts, pull request numbers, header
    /// buttons): the accent's ink, 70% over the sidebar.
    let sidebarText3: NSColor
    let delete: NSColor
    let tones: [TrackPalette.Tone]
    let toneColors: [TrackPalette.Tone: NSColor]

    static let orange = ThemeColor.fixed(0xE8590C, 0xFF9A5C)
    static let electric = ThemeColor.fixed(0x5146E8, 0x8C85FF)
    static let blue = ThemeColor.fixed(0x4F6BE8, 0x7F96FF)
    static let pink = ThemeColor.fixed(0xD6338A, 0xF062B0)
    static let cyan = ThemeColor.fixed(0x0891B2, 0x22D3EE)
    static let violet = ThemeColor.fixed(0x9333EA, 0xC084FC)
    /// Marks on a deep accent: white in light, dark on the light accent
    /// in dark, as the solid tags' text is.
    static let markOnDeepAccent = ThemeColor.fixed(0xFFFFFF, 0x111116)

    init(_ color: DesignThemeColor) {
        var toneColors: [TrackPalette.Tone: NSColor] = [
            .orange: Self.orange, .indigo: Self.electric, .pink: Self.pink,
            .cyan: Self.cyan, .violet: Self.violet,
        ]
        let sidebarLight: UInt32
        let sidebarDark: UInt32
        let inkLight: UInt32
        let inkDark: UInt32
        switch color {
        case .electric:
            // A vivid indigo-violet.
            self.color = .electric
            accent = ThemeColor.fixed(0x5146E8, 0x8C85FF)
            (inkLight, inkDark) = (0x4A3FD9, 0xA19BFF)
            prominent = ThemeColor.fixed(0x5146E8, 0x6359F5)
            prominentText = .white
            onAccent = Self.markOnDeepAccent
            (sidebarLight, sidebarDark) = (0xF3F2FF, 0x16152A)
            selectionAlpha = (0.10, 0.15)
            sidebarSelection = ThemeColor.wash(.hex(0x5146E8), 0.14, .hex(0x8C85FF), 0.18)
            sidebarSelectionText = ThemeColor.fixed(0x3B31BF, 0xC2BEFF)
            sidebarSelectionIcon = ThemeColor.fixed(0x5146E8, 0x8C85FF)
            delete = ThemeColor.fixed(0xC8361E, 0xFF9480)
            tones = [.orange, .pink, .cyan]
        case .magenta:
            self.color = .magenta
            accent = ThemeColor.fixed(0xC2247E, 0xF062B0)
            (inkLight, inkDark) = (0xAE1F71, 0xF47FBF)
            prominent = ThemeColor.fixed(0xC2247E, 0xD62C8C)
            prominentText = .white
            onAccent = Self.markOnDeepAccent
            (sidebarLight, sidebarDark) = (0xFCF0F7, 0x21131B)
            selectionAlpha = (0.09, 0.14)
            sidebarSelection = ThemeColor.wash(.hex(0xC2247E), 0.13, .hex(0xF062B0), 0.17)
            sidebarSelectionText = ThemeColor.fixed(0x941A60, 0xF8A6D2)
            sidebarSelectionIcon = ThemeColor.fixed(0xC2247E, 0xF062B0)
            // Deletions turn vermilion, so they don't read as the accent.
            delete = ThemeColor.fixed(0xC2410C, 0xFF9A6E)
            toneColors[.indigo] = Self.blue
            tones = [.orange, .indigo, .cyan]
        default:
            // Tangerine, the default: dark text on the prominent orange.
            self.color = .tangerine
            accent = ThemeColor.fixed(0xF25C0F, 0xFF8A47)
            (inkLight, inkDark) = (0xC2470A, 0xFF9A5E)
            prominent = ThemeColor.fixed(0xFF6A1F, 0xFF7A2E)
            prominentText = ThemeColor.fixed(0x1B0F05, 0x1B0F05)
            onAccent = ThemeColor.fixed(0x1B0F05, 0x1B0F05)
            (sidebarLight, sidebarDark) = (0xFFF3EA, 0x1E1611)
            selectionAlpha = (0.11, 0.14)
            sidebarSelection = ThemeColor.wash(.hex(0xF25C0F), 0.15, .hex(0xFF8A47), 0.17)
            // Deeper under Increase Contrast, on the stronger wash.
            sidebarSelectionText = .espalierDynamic(
                light: .hex(0xA63C06), dark: .hex(0xFFB386),
                highContrastLight: .hex(0x8F3305), highContrastDark: .hex(0xFFB386)
            )
            sidebarSelectionIcon = ThemeColor.fixed(0xE5560D, 0xFF8A47)
            // Deletions move to a raspberry red, so they don't read as the
            // accent.
            delete = ThemeColor.fixed(0xC8264E, 0xFF8AA5)
            tones = [.indigo, .pink, .cyan, .violet]
        }
        self.toneColors = toneColors
        ink = ThemeColor.fixed(inkLight, inkDark)
        sidebar = ThemeColor.surface(sidebarLight, sidebarDark)
        let sidebarLightColor = NSColor.hex(sidebarLight)
        let sidebarDarkColor = NSColor.hex(sidebarDark)
        // The accent's ink over the sidebar; the ink itself under Increase
        // Contrast.
        func inkOverSidebar(_ fraction: CGFloat) -> NSColor {
            .espalierDynamic(
                light: sidebarLightColor.blended(withFraction: fraction, of: .hex(inkLight)) ?? .hex(inkLight),
                dark: sidebarDarkColor.blended(withFraction: fraction, of: .hex(inkDark)) ?? .hex(inkDark),
                highContrastLight: .hex(inkLight),
                highContrastDark: .hex(inkDark)
            )
        }
        label = inkOverSidebar(0.75)
        sidebarText3 = inkOverSidebar(0.70)
    }
}
