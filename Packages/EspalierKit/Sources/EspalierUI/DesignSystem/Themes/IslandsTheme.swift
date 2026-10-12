// Islands: calm and friendly. The panes float as white cards on a sage
// backdrop (`PaneLayout.floatingCards`), controls are soft pills with bold
// titles (white and raised on the backdrop, flat on the field fill in a
// card), and one accent marks selection, the current branch, and the one
// prominent action. Bold uppercase labels, rounded-square avatars, round
// file badges, rounded-rectangle ref tags, and a graph of dots. Colors:
// Berry, Lagoon (the default), Indigo.

import AppKit
import EspalierCore
import SwiftUI

nonisolated extension ThemeDefinition {
    static func islands(_ color: DesignThemeColor) -> ThemeDefinition {
        let palette = IslandsColor(color)
        return ThemeDefinition(
            theme: .islands,
            color: palette.color,
            background: ThemeColor.surface(0xFFFFFF, 0x181D1A),
            // The sidebar sits on the backdrop.
            sidebar: ThemeColor.surface(0xE3E9E5, 0x0E1210),
            field: ThemeColor.fill(0xEEF2EF, 0x232A26),
            hunk: ThemeColor.surface(0xF3F6F4, 0x1D2320),
            hover: ThemeColor.wash(.hex(0x142D1E), 0.05, .white, 0.05),
            line: ThemeColor.line(0xE4E9E6, 0x262D29),
            line2: ThemeColor.line2(0xD2DAD5, 0x343D38),
            quiet: ThemeColor.surface(0xFFFFFF, 0x1F2522),
            soft: ThemeColor.fill(0xE8EDEA, 0x2A322E),
            scrim: .espalierDynamic(light: NSColor.black.withAlphaComponent(0.2), dark: NSColor.black.withAlphaComponent(0.45)),
            backdrop: ThemeColor.surface(0xE3E9E5, 0x0E1210),
            raisedShadow: .espalierDynamic(light: NSColor.hex(0x142D1E, alpha: 0.08), dark: .clear),
            raisedRing: .espalierDynamic(light: NSColor.hex(0x142D1E, alpha: 0.05), dark: NSColor.white.withAlphaComponent(0.05)),
            text: ThemeColor.text(0x16201B, 0xE8EEEA),
            text2: ThemeColor.text2(0x55625B, 0xA2AFA7),
            // Tertiary text reaches 3:1 on the backdrop (the sidebar's
            // section labels and counts).
            text3: ThemeColor.text3(0x7A8880, 0x6D7A73, text2: (0x55625B, 0xA2AFA7)),
            accent: palette.accent,
            linkBase: palette.ink,
            accentSoftAlpha: palette.selectionAlpha,
            textSelectionAlpha: palette.textSelectionAlpha,
            prominent: palette.prominent,
            // A dark mark on the light accents of dark mode.
            onAccent: ThemeColor.fixed(0xFFFFFF, 0x181D1A),
            add: ThemeColor.fixed(0x23784A, 0x6FD39A),
            delete: palette.delete,
            modified: ThemeColor.fixed(0x9A6400, 0xE9B64E),
            renamed: palette.accent,
            trunk: palette.trunk,
            tones: palette.tones,
            toneColors: palette.toneColors,
            sidebarSelection: palette.sidebarSelection,
            sidebarSelectionText: palette.sidebarSelectionText,
            sidebarSelectionIsBold: true,
            sidebarSelectionTintsCounts: true,
            sectionLabel: SectionLabelStyle(isUppercase: true, size: 10, weight: .bold, tracking: 0.08, color: nil),
            radii: ThemeRadii(row: 10, card: 14, small: 5, tag: 6),
            commitTitle: TitleStyle(size: 18, weight: .bold),
            buttonWeights: ButtonWeights(quiet: .bold, prominent: .bold),
            graph: GraphStyle(lineWidth: 3.25, lanePitch: 17, node: .dot),
            refTag: RefTagStyle(fill: .tinted(alpha: (0.14, 0.22), textMix: (0.30, 0.25), ink: 0x0C1410), currentUsesProminent: true),
            statusBadge: StatusBadgeStyle(fill: .tinted, shape: .circle),
            avatarShape: .roundedSquare,
            paneLayout: .floatingCards,
            controls: ControlStyle(prominentShadow: NSColor.black.withAlphaComponent(0.14), flatInCards: true)
        )
    }
}

/// An Islands color's values, light and dark.
nonisolated private struct IslandsColor {
    let color: DesignThemeColor
    let accent: NSColor
    let ink: NSColor
    let prominent: NSColor
    let selectionAlpha: (light: CGFloat, dark: CGFloat)
    /// Selected text's wash, light enough that secondary text on it in a
    /// field keeps 4.5:1.
    let textSelectionAlpha: (light: CGFloat, dark: CGFloat)
    let sidebarSelection: NSColor
    let sidebarSelectionText: NSColor
    let delete: NSColor
    let trunk: NSColor
    let tones: [TrackPalette.Tone]
    let toneColors: [TrackPalette.Tone: NSColor]

    static let orange = ThemeColor.fixed(0xE07B24, 0xF0A05C)
    static let rose = ThemeColor.fixed(0xC2416B, 0xE7779B)
    static let periwinkle = ThemeColor.fixed(0x5868D6, 0x9AA3F2)
    static let violet = ThemeColor.fixed(0x8A4FA8, 0xC58BDD)
    static let sea = ThemeColor.fixed(0x0E8094, 0x5CC6D6)
    static let green = ThemeColor.fixed(0x2E8A4E, 0x7BD08F)
    static let mint = ThemeColor.fixed(0x2E8A6E, 0x5CC7A0)
    static let red = ThemeColor.fixed(0xC23A2B, 0xF0877A)

    init(_ color: DesignThemeColor) {
        let toneColors: [TrackPalette.Tone: NSColor] = [
            .orange: Self.orange, .pink: Self.rose, .indigo: Self.periwinkle,
            .violet: Self.violet, .cyan: Self.sea, .green: Self.green,
        ]
        self.toneColors = toneColors
        switch color {
        case .berry:
            self.color = .berry
            accent = ThemeColor.fixed(0xB8255F, 0xF07AA8)
            ink = ThemeColor.fixed(0xA6215A, 0xF07AA8)
            prominent = ThemeColor.fixed(0xB0225C, 0xC42A67)
            selectionAlpha = (0.09, 0.14)
            textSelectionAlpha = (0.14, 0.20)
            sidebarSelection = ThemeColor.wash(.hex(0xB8255F), 0.12, .hex(0xF07AA8), 0.16)
            sidebarSelectionText = ThemeColor.fixed(0x8E1C4C, 0xF7AECB)
            // Deletions turn vermilion, so they don't read as the accent.
            delete = ThemeColor.fixed(0xBF4513, 0xF2966A)
            trunk = Self.mint
            tones = [.orange, .indigo, .violet]
        case .indigo:
            self.color = .indigo
            accent = ThemeColor.fixed(0x4447C9, 0x9C9FF5)
            ink = ThemeColor.fixed(0x3E41BC, 0x9C9FF5)
            prominent = ThemeColor.fixed(0x3F42BE, 0x4A4DD0)
            selectionAlpha = (0.09, 0.15)
            textSelectionAlpha = (0.14, 0.18)
            sidebarSelection = ThemeColor.wash(.hex(0x4447C9), 0.12, .hex(0x9C9FF5), 0.16)
            sidebarSelectionText = ThemeColor.fixed(0x33369F, 0xC0C2FA)
            delete = Self.red
            trunk = Self.mint
            tones = [.orange, .pink, .cyan]
        default:
            // Lagoon, the default: a deep sea blue-green.
            self.color = .lagoon
            accent = ThemeColor.fixed(0x0B7A8C, 0x5CC6D6)
            ink = ThemeColor.fixed(0x096C7C, 0x5CC6D6)
            prominent = ThemeColor.fixed(0x0A6F80, 0x0E8094)
            selectionAlpha = (0.10, 0.14)
            textSelectionAlpha = (0.15, 0.16)
            sidebarSelection = ThemeColor.wash(.hex(0x0B7A8C), 0.13, .hex(0x5CC6D6), 0.16)
            sidebarSelectionText = ThemeColor.fixed(0x075E6C, 0x93DCE7)
            delete = Self.red
            trunk = Self.green
            tones = [.orange, .pink, .indigo, .violet]
        }
    }
}
