// Islands: calm and friendly. The panes float as white cards on a sage
// backdrop (`PaneLayout.floatingCards`), controls are soft pills with bold
// titles (white and raised on the backdrop, flat on the field fill in a
// card), and the palette's accent marks selection, the current branch, and
// (as its prominent fill) the one prominent action. Bold uppercase labels,
// rounded-square avatars, round file badges, rounded-rectangle ref tags,
// and a graph of dots.

import AppKit
import EspalierCore
import SwiftUI

nonisolated extension ThemeDefinition {
    static func islands(_ palette: PaletteColors) -> ThemeDefinition {
        ThemeDefinition(
            theme: .islands,
            palette: palette.palette,
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
            text3: ThemeColor.text3(0x909E96, 0x6D7A73, text2: (0x55625B, 0xA2AFA7)),
            accent: palette.accent,
            linkBase: palette.ink,
            accentSoftAlpha: (0.10, 0.14),
            textSelectionAlpha: (0.14, 0.18),
            prominent: palette.prominent,
            prominentText: palette.prominentText,
            marks: palette.marks,
            add: ThemeColor.fixed(0x23784A, 0x6FD39A),
            delete: IslandsColor.red,
            modified: ThemeColor.fixed(0x9A6400, 0xE9B64E),
            renamed: palette.accent,
            conflictOurs: IslandsColor.mint,
            conflictTheirs: IslandsColor.orange,
            // Mint; green beside a teal accent.
            branches: BranchTones(trunk: IslandsColor.mint, tones: [.orange, .pink, .blue, .violet, .cyan]),
            branchesNearAccent: BranchTones(trunk: IslandsColor.green, tones: [.orange, .pink, .blue, .violet, .cyan]),
            toneColors: IslandsColor.toneColors,
            sidebarSelection: ThemeColor.wash(palette.accent, 0.12, 0.16),
            sidebarSelectionText: palette.deepInk,
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

/// Islands' status and branch colors, light and dark.
nonisolated private enum IslandsColor {
    static let orange = ThemeColor.fixed(0xE07B24, 0xF0A05C)
    static let rose = ThemeColor.fixed(0xC2416B, 0xE7779B)
    static let periwinkle = ThemeColor.fixed(0x5868D6, 0x9AA3F2)
    static let violet = ThemeColor.fixed(0x8A4FA8, 0xC58BDD)
    static let sea = ThemeColor.fixed(0x0E8094, 0x5CC6D6)
    static let green = ThemeColor.fixed(0x2E8A4E, 0x7BD08F)
    static let mint = ThemeColor.fixed(0x2E8A6E, 0x5CC7A0)
    static let red = ThemeColor.fixed(0xC23A2B, 0xF0877A)

    static let toneColors: [TrackPalette.Tone: NSColor] = [
        .orange: orange, .pink: rose, .blue: periwinkle,
        .violet: violet, .cyan: sea, .green: green,
    ]
}
