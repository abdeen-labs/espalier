// Frost: quiet and precise. Near-white and near-black surfaces with almost
// no hue, a neutral wash for every selection, ink (near-black, near-white
// in dark) for the one prominent action and the current branch's tag, and
// the palette's accent kept for focus, links, checkboxes, and the current
// branch's line. Flat pills, sentence-case labels, small radii, a fine graph
// of dots, code in a soft palette, and lists that fade out at an edge with
// more beyond it. The main window is glass: the backdrop color at 80% over
// a plain blur of what's behind the window, with a 5% wash for the chrome,
// around one inset card (`PaneLayout.insetCard`) that's a panel, the
// background at 40% over the glass, the panes in it clear. Lines, hover,
// selection, fields, and hunk headers are washes, so they read the same on
// the glass wherever they are.

import AppKit
import EspalierCore
import SwiftUI

nonisolated extension ThemeDefinition {
    static func frost(_ palette: PaletteColors) -> ThemeDefinition {
        ThemeDefinition(
            theme: .frost,
            palette: palette.palette,
            background: ThemeColor.surface(0xFFFFFF, 0x0A0A0A),
            sidebar: ThemeColor.surface(0xEBEBED, 0x171717),
            // Washes: the fields' ink, the hunk headers' blue-gray, the
            // hover, and the lines.
            field: ThemeColor.wash(.black, 0.035, .white, 0.035),
            hunk: ThemeColor.wash(.hex(0x3A5378), 0.07, .hex(0x7592BD), 0.05),
            hover: ThemeColor.wash(.hex(0x1A1A1A), 0.06, .hex(0xEBEBEB), 0.11),
            line: ThemeColor.wash(.black, 0.10, .white, 0.08),
            line2: ThemeColor.wash(.black, 0.17, .white, 0.14),
            quiet: ThemeColor.surface(0xFFFFFF, 0x1C1C1E),
            soft: ThemeColor.fill(0xEAEAEC, 0x232325),
            // Quiet controls are flat pills on the field's gray; the
            // selected segment is a card raised off its track.
            quietControl: ThemeColor.fill(0xEAEAEC, 0x222224),
            quietControlIsRaised: false,
            segmentSelection: ThemeColor.surface(0xFFFFFF, 0x333336),
            scrim: .espalierDynamic(light: NSColor.black.withAlphaComponent(0.2), dark: NSColor.black.withAlphaComponent(0.6)),
            // The chrome: the backdrop color at 80% over the blur, and a
            // 5% wash over that.
            backdrop: ThemeColor.surface(0xF3F3F5, 0x0D0D0D),
            backdropGlass: GlassStyle(opacity: 0.8, wash: ThemeColor.wash(.hex(0x1A1A1A), 0.05, .hex(0xEBEBEB), 0.05)),
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
            marks: palette.marks,
            add: ThemeColor.fixed(0x15803D, 0x34D399),
            delete: ThemeColor.fixed(0xDC2626, 0xF87171),
            modified: ThemeColor.fixed(0xA16207, 0xFACC15),
            renamed: FrostColor.violet,
            renamedNearAccent: FrostColor.blue,
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
            // Cyan; green beside a blue or teal accent.
            branches: BranchTones(trunk: FrostColor.cyan, tones: [.orange, .pink, .violet, .blue, .green]),
            branchesNearAccent: BranchTones(trunk: FrostColor.green, tones: [.orange, .pink, .violet, .blue, .cyan]),
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

/// Frost's branch and code colors, light and dark.
nonisolated private enum FrostColor {
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

    /// Every selection: one neutral wash, near-black 10% (near-white
    /// 16% in dark).
    static let selection = ThemeColor.wash(.hex(0x1A1A1A), 0.10, .hex(0xEBEBEB), 0.16)
}
