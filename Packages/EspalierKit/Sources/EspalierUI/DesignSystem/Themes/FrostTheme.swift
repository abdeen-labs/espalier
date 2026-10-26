// Frost: quiet and precise. Near-white and near-black surfaces with almost
// no hue, a neutral wash for every selection, ink (near-black, near-white
// in dark) for the one prominent action and the current branch's tag, and
// one accent kept for focus, links, checkboxes, and the current branch's
// line. Flat pills, sentence-case labels, small radii, a fine graph of
// dots, code in a soft palette, and lists that fade out at an edge with
// more beyond it. The main window's chrome is glass, the sidebar's color at
// 80% over a blur of what's behind the window, around one inset card
// (`PaneLayout.insetCard`). Colors: Iris (the default), Glacier, Ember.

import AppKit
import EspalierCore
import SwiftUI

nonisolated extension ThemeDefinition {
    static func frost(_ color: DesignThemeColor) -> ThemeDefinition {
        let palette = FrostColor(color)
        return ThemeDefinition(
            theme: .frost,
            color: palette.color,
            background: ThemeColor.surface(0xFFFFFF, 0x0A0A0A),
            sidebar: ThemeColor.surface(0xEBEBED, 0x171717),
            field: ThemeColor.fill(0xEFEFF2, 0x1F1F21),
            hunk: ThemeColor.surface(0xF6F6F7, 0x121213),
            hover: ThemeColor.wash(.black, 0.04, .white, 0.055),
            line: ThemeColor.line(0xE2E2E4, 0x1F1F21),
            line2: ThemeColor.line2(0xCCCCCF, 0x313134),
            quiet: ThemeColor.surface(0xFFFFFF, 0x1C1C1E),
            soft: ThemeColor.fill(0xEAEAEC, 0x232325),
            // Quiet controls are flat pills on the field's gray; the
            // selected segment is a card raised off its track.
            quietControl: ThemeColor.fill(0xEAEAEC, 0x222224),
            quietControlIsRaised: false,
            segmentSelection: ThemeColor.surface(0xFFFFFF, 0x333336),
            scrim: .espalierDynamic(light: NSColor.black.withAlphaComponent(0.2), dark: NSColor.black.withAlphaComponent(0.6)),
            // The chrome: the sidebar's color, as glass.
            backdrop: ThemeColor.surface(0xEBEBED, 0x171717),
            backdropGlass: GlassStyle(opacity: 0.8),
            raisedShadow: .espalierDynamic(light: NSColor.black.withAlphaComponent(0.08), dark: .clear),
            raisedRing: .espalierDynamic(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.08)),
            text: ThemeColor.text(0x303035, 0xE8E8EA),
            text2: ThemeColor.text2(0x62626A, 0xA9A9AE),
            text3: ThemeColor.text3(0x8B8B93, 0x6F6F75, text2: (0x62626A, 0xA9A9AE)),
            accent: palette.accent,
            // Every selection is the same neutral wash as the sidebar's.
            selection: FrostColor.selection,
            prominent: ThemeColor.fixed(0x232328, 0xEBEBEF),
            prominentText: ThemeColor.fixed(0xFFFFFF, 0x0A0A0A),
            // Checks, radio dots, and the switch's knob: white on the deep
            // accents of light, the dark background on the light ones of
            // dark.
            onAccent: ThemeColor.fixed(0xFFFFFF, 0x0A0A0A),
            add: ThemeColor.fixed(0x15803D, 0x34D399),
            delete: ThemeColor.fixed(0xDC2626, 0xF87171),
            modified: ThemeColor.fixed(0xA16207, 0xFACC15),
            renamed: palette.renamed,
            conflictOurs: FrostColor.cyan,
            conflictTheirs: FrostColor.orange,
            syntaxColors: [
                .keyword: FrostColor.iris,
                .string: ThemeColor.fixed(0x15803D, 0x34D399),
                .comment: ThemeColor.fixed(0x6B7280, 0x8A8A92),
                .number: ThemeColor.fixed(0xA16207, 0xFACC15),
                .type: FrostColor.violet,
                .function: FrostColor.blue,
                .operatorOrPunctuation: ThemeColor.fixed(0x52525B, 0xA1A1AA),
            ],
            trunk: palette.trunk,
            tones: palette.tones,
            toneColors: FrostColor.toneColors,
            sidebarSelection: FrostColor.selection,
            sidebarSelectionIcon: ThemeColor.text(0x303035, 0xE8E8EA),
            sectionLabel: SectionLabelStyle(isUppercase: false, size: 12, weight: .medium, tracking: 0, color: nil),
            radii: ThemeRadii(row: 8, card: 12, small: 5, tag: 5),
            commitTitle: TitleStyle(size: 16, weight: .semibold),
            buttonWeights: ButtonWeights(quiet: .regular, prominent: .medium),
            graph: GraphStyle(lineWidth: 2, lanePitch: 15, node: .dot),
            refTag: RefTagStyle(fill: .tinted(alpha: (0.10, 0.16), textMix: (0.30, 0.15), ink: 0x000000), currentUsesProminent: true),
            statusBadge: StatusBadgeStyle(fill: .tinted, shape: .roundedSquare),
            paneLayout: .insetCard,
            // Lists fade out at an edge with more beyond it, over a
            // 24-point band, instead of ending at a hard cut.
            scrollEdgeFade: 24
        )
    }
}

/// A Frost color's values, light and dark.
nonisolated private struct FrostColor {
    let color: DesignThemeColor
    let accent: NSColor
    /// Renamed and copied files.
    let renamed: NSColor
    /// The default branch's color.
    let trunk: NSColor
    let tones: [TrackPalette.Tone]

    // The branch and code colors.
    static let iris = ThemeColor.fixed(0x5B43E8, 0x8B7CF6)
    static let violet = ThemeColor.fixed(0x7E22CE, 0xC084FC)
    static let blue = ThemeColor.fixed(0x2563EB, 0x60A5FA)
    static let cyan = ThemeColor.fixed(0x0E7490, 0x22D3EE)
    static let green = ThemeColor.fixed(0x15803D, 0x4ADE80)
    static let orange = ThemeColor.fixed(0xC2410C, 0xFB923C)
    static let pink = ThemeColor.fixed(0xBE185D, 0xF472B6)

    static let toneColors: [TrackPalette.Tone: NSColor] = [
        .orange: orange, .pink: pink, .violet: violet,
        .blue: blue, .cyan: cyan, .green: green,
    ]

    /// Every selection: black 6% (white 9% in dark).
    static let selection = ThemeColor.wash(.black, 0.06, .white, 0.09)

    init(_ color: DesignThemeColor) {
        switch color {
        case .glacier:
            self.color = .glacier
            accent = Self.blue
            renamed = Self.violet
            trunk = Self.green
            tones = [.orange, .pink, .violet, .cyan]
        case .ember:
            self.color = .ember
            accent = Self.orange
            renamed = Self.violet
            trunk = Self.cyan
            tones = [.pink, .violet, .blue, .green]
        default:
            // Iris, the default: a cool blue-violet.
            self.color = .iris
            accent = Self.iris
            renamed = Self.blue
            trunk = Self.cyan
            tones = [.orange, .pink, .blue, .green]
        }
    }
}
