// Orchard: warm and crafted. Bone and stone surfaces instead of gray, one
// accent for selection, the current branch, and the one prominent action,
// orchard colors for branches. Soft, generous shapes; sentence-case section
// labels; a raised card for the sidebar's selection; a graph of dots.
// Colors: Plum, Clay, Ink (the default), Teal, Espresso.

import AppKit
import EspalierCore
import SwiftUI

nonisolated extension ThemeDefinition {
    static func orchard(_ color: DesignThemeColor) -> ThemeDefinition {
        let palette = OrchardColor(color)
        return ThemeDefinition(
            theme: .orchard,
            color: palette.color,
            background: ThemeColor.surface(0xFBF9F5, 0x1D1A16),
            sidebar: ThemeColor.surface(0xF1ECE3, 0x151310),
            field: ThemeColor.fill(0xEEE7DB, 0x2B2621),
            hunk: ThemeColor.surface(0xF4EFE7, 0x221E19),
            hover: ThemeColor.wash(.hex(0x50371E), 0.06, .hex(0xFFF0DC), 0.05),
            line: ThemeColor.line(0xE8E1D5, 0x2E2923),
            line2: ThemeColor.line2(0xD9D0C1, 0x3D372F),
            quiet: ThemeColor.surface(0xFFFEFB, 0x2B2621),
            soft: ThemeColor.fill(0xEEE7DB, 0x2B2621),
            // Quiet controls are flat stone pills, as fields are; the
            // selected segment is a card raised off its stone track.
            quietControl: ThemeColor.fill(0xEEE7DB, 0x2B2621),
            quietControlIsRaised: false,
            segmentSelection: ThemeColor.surface(0xFBF9F5, 0x3A332C),
            scrim: .espalierDynamic(light: NSColor.black.withAlphaComponent(0.2), dark: NSColor.black.withAlphaComponent(0.45)),
            raisedShadow: .espalierDynamic(light: NSColor.hex(0x50371E, alpha: 0.10), dark: .clear),
            raisedRing: .espalierDynamic(light: NSColor.hex(0x50371E, alpha: 0.05), dark: NSColor.hex(0xFFF0DC, alpha: 0.06)),
            text: ThemeColor.text(0x27221C, 0xF2ECE3),
            text2: ThemeColor.text2(0x5E574C, 0xC0B6A7),
            text3: ThemeColor.text3(0xA1988A, 0x7D7467, text2: (0x5E574C, 0xC0B6A7)),
            accent: palette.accent,
            linkBase: palette.ink,
            accentSoftAlpha: palette.selectionAlpha,
            textSelectionAlpha: palette.textSelectionAlpha,
            prominent: palette.prominent,
            prominentText: palette.prominentText,
            // Checks, radio dots, and the switch's knob: white on the deep
            // accents of light, the dark background on the light ones of
            // dark.
            onAccent: ThemeColor.fixed(0xFFFFFF, 0x1D1A16),
            add: ThemeColor.fixed(0x46802F, 0x93C77B),
            delete: palette.delete,
            modified: ThemeColor.fixed(0x9C6512, 0xE5B661),
            renamed: palette.accent,
            // Code in the orchard's colors rather than the system's.
            syntaxColors: [
                .keyword: OrchardColor.plum,
                .string: OrchardColor.brick,
                .comment: ThemeColor.fixed(0x8C8273, 0x8F8677),
                .number: ThemeColor.fixed(0xA86A16, 0xE5B661),
                .type: OrchardColor.teal,
                .function: OrchardColor.sky,
            ],
            trunk: palette.trunk,
            tones: palette.tones,
            toneColors: palette.toneColors,
            // The selection is a card of the background's fill on the
            // sidebar, raised by its shadow (`SidebarSelectionCard`).
            sidebarSelection: ThemeColor.surface(0xFBF9F5, 0x25211C),
            sidebarSelectionIcon: ThemeColor.text(0x27221C, 0xF2ECE3),
            sidebarSelectionStyle: .raisedCard,
            sectionLabel: SectionLabelStyle(isUppercase: false, size: 12, weight: .semibold, tracking: 0, color: nil),
            radii: ThemeRadii(row: 10, card: 14, small: 5, tag: nil),
            commitTitle: TitleStyle(size: 18, weight: .semibold),
            graph: GraphStyle(lineWidth: 3.5, lanePitch: 17, node: .dot),
            refTag: RefTagStyle(fill: .tinted(alpha: (0.15, 0.22), textMix: (0.28, 0.22), ink: 0x1D140C), currentUsesProminent: true),
            statusBadge: StatusBadgeStyle(fill: .tinted, shape: .roundedSquare)
        )
    }
}

/// An Orchard color's values, light and dark.
nonisolated private struct OrchardColor {
    let color: DesignThemeColor
    let accent: NSColor
    /// What links deepen from.
    let ink: NSColor
    let prominent: NSColor
    let prominentText: NSColor
    let selectionAlpha: (light: CGFloat, dark: CGFloat)
    var textSelectionAlpha: (light: CGFloat, dark: CGFloat) = (0.16, 0.24)
    let delete: NSColor
    /// The default branch's color.
    let trunk: NSColor
    let tones: [TrackPalette.Tone]
    let toneColors: [TrackPalette.Tone: NSColor]

    // The orchard's branch colors.
    static let orange = ThemeColor.fixed(0xDB7A2E, 0xEFA05C)
    static let rose = ThemeColor.fixed(0xC2416B, 0xE7779B)
    static let plum = ThemeColor.fixed(0x8A43A8, 0xC58BDD)
    static let sky = ThemeColor.fixed(0x3E78B0, 0x73A9DD)
    static let periwinkle = ThemeColor.fixed(0x5B6CD0, 0x9AA6F0)
    static let teal = ThemeColor.fixed(0x1D7C78, 0x6BC6BF)
    static let leaf = ThemeColor.fixed(0x4F8C3A, 0x8CC072)
    static let brick = ThemeColor.fixed(0xB9472F, 0xE8977F)

    init(_ color: DesignThemeColor) {
        let toneColors: [TrackPalette.Tone: NSColor] = [
            .orange: Self.orange, .pink: Self.rose, .violet: Self.plum,
            .indigo: Self.sky, .cyan: Self.teal, .green: Self.leaf,
        ]
        switch color {
        case .clay:
            self.color = .clay
            accent = ThemeColor.fixed(0xB04E2C, 0xEC9673)
            ink = ThemeColor.fixed(0xA84825, 0xEC9673)
            prominent = ThemeColor.fixed(0xA84825, 0xB9532E)
            prominentText = .white
            selectionAlpha = (0.10, 0.15)
            delete = ThemeColor.fixed(0xA63049, 0xF2899C)
            trunk = Self.leaf
            tones = [.indigo, .violet, .cyan]
            self.toneColors = toneColors
        case .plum:
            self.color = .plum
            accent = ThemeColor.fixed(0x7E3D98, 0xCE9BE3)
            ink = accent
            prominent = ThemeColor.fixed(0x75378F, 0x8E4BAB)
            prominentText = .white
            selectionAlpha = (0.10, 0.15)
            delete = Self.brick
            trunk = Self.leaf
            tones = [.orange, .pink, .indigo, .cyan]
            self.toneColors = toneColors
        case .teal:
            self.color = .teal
            accent = ThemeColor.fixed(0x1C7773, 0x6BC6BF)
            ink = ThemeColor.fixed(0x19706C, 0x6BC6BF)
            prominent = ThemeColor.fixed(0x19706C, 0x1E837E)
            prominentText = .white
            selectionAlpha = (0.10, 0.14)
            delete = Self.brick
            trunk = ThemeColor.fixed(0xD27A2C, 0xEFA05C)
            tones = [.pink, .indigo, .green, .violet]
            var colors = toneColors
            colors[.indigo] = Self.periwinkle
            self.toneColors = colors
        case .espresso:
            // No hue at all: warm black for the prominent action and the
            // current branch.
            self.color = .espresso
            accent = ThemeColor.fixed(0x2B251F, 0xF2ECE3)
            // Links are coffee brown.
            ink = ThemeColor.fixed(0x8A5A2B, 0xD7AE84)
            prominent = ThemeColor.fixed(0x2B251F, 0xF2ECE3)
            prominentText = ThemeColor.fixed(0xFBF9F5, 0x1D1A16)
            selectionAlpha = (0.08, 0.10)
            // Selected text is fainter.
            textSelectionAlpha = (0.12, 0.14)
            delete = Self.brick
            trunk = Self.leaf
            tones = [.orange, .pink, .violet, .indigo, .cyan]
            self.toneColors = toneColors
        default:
            // Ink, the default: a deep, warm navy, blue without the system's
            // blue.
            self.color = .ink
            accent = ThemeColor.fixed(0x2E52A0, 0x93B0EF)
            ink = accent
            prominent = ThemeColor.fixed(0x2B4C94, 0x3A62B6)
            prominentText = .white
            selectionAlpha = (0.10, 0.15)
            delete = Self.brick
            trunk = Self.leaf
            tones = [.orange, .pink, .violet, .cyan]
            self.toneColors = toneColors
        }
    }
}
