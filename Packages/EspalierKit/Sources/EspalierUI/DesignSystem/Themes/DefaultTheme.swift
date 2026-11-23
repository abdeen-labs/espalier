// Default: playful and creamy. The panes are cream cards floating on an
// oat backdrop, warm espresso ink for text,
// and a butter-yellow highlight, like a highlighter on paper, for every
// selection. The palette's accent is the one prominent action, focus,
// links, checkboxes, and the current branch. Controls are soft, raised
// pillows with bold titles; section labels are bold and as written; radii
// are generous, file badges round, ref tags soft pills, and the graph is
// drawn in thick strokes with round dots. In dark, the cream turns to
// cocoa and the highlight to a warm honey glow. Status and branch colors
// are an orchard's: leaf, tomato, honey, grape, plum, and teal.

import AppKit
import EspalierCore
import SwiftUI

nonisolated extension ThemeDefinition {
    static func `default`(_ palette: PaletteColors) -> ThemeDefinition {
        ThemeDefinition(
            theme: .default,
            palette: palette.palette,
            background: ThemeColor.surface(0xFFFBF3, 0x2A231D),
            // The sidebar sits on the backdrop.
            sidebar: ThemeColor.surface(0xF2EADB, 0x1D1814),
            field: ThemeColor.fill(0xF5EDDF, 0x352C25),
            hunk: ThemeColor.surface(0xF4EEE6, 0x30281F),
            hover: ThemeColor.wash(.hex(0x6B4A22), 0.06, .hex(0xFFE7C2), 0.06),
            line: ThemeColor.line(0xEEE4D3, 0x3A3029),
            line2: ThemeColor.line2(0xE0D3BE, 0x463A31),
            quiet: ThemeColor.surface(0xFFFBF3, 0x322A23),
            soft: ThemeColor.fill(0xF0E6D5, 0x352C25),
            // Quiet controls are cream pillows raised off the oat, flat on
            // the field fill in a card.
            quietControl: ThemeColor.surface(0xFFFDF8, 0x3A3028),
            segmentSelection: ThemeColor.surface(0xFFFDF8, 0x40352C),
            scrim: .espalierDynamic(light: NSColor.hex(0x3A2A18, alpha: 0.22), dark: NSColor.black.withAlphaComponent(0.5)),
            backdrop: ThemeColor.surface(0xF2EADB, 0x1D1814),
            raisedShadow: .espalierDynamic(light: NSColor.hex(0x6B4A22, alpha: 0.10), dark: NSColor.black.withAlphaComponent(0.35)),
            raisedRing: .espalierDynamic(light: NSColor.hex(0x6B4A22, alpha: 0.07), dark: NSColor.hex(0xFFE7C2, alpha: 0.06)),
            text: ThemeColor.text(0x2B2119, 0xF6ECDF),
            text2: ThemeColor.text2(0x7A6858, 0xBCAA97),
            text3: ThemeColor.text3(0xAA9784, 0x806F60, text2: (0x7A6858, 0xBCAA97)),
            accent: palette.accent,
            linkBase: palette.ink,
            accentFaintAlpha: (0.06, 0.10),
            accentMidAlpha: (0.18, 0.26),
            textSelectionAlpha: (0.18, 0.28),
            // Every selection is the butter highlight.
            selection: DefaultColor.butter,
            prominent: palette.prominent,
            prominentText: palette.prominentText,
            marks: palette.marks,
            add: DefaultColor.leaf,
            delete: DefaultColor.tomato,
            modified: DefaultColor.honey,
            renamed: DefaultColor.grape,
            renamedNearAccent: DefaultColor.plum,
            conflictOurs: DefaultColor.teal,
            conflictTheirs: DefaultColor.apricot,
            // Added and deleted lines a third again as strong in light, so
            // they read on the cream.
            diffLineStrength: (1.35, 1.1),
            syntaxColors: [
                .keyword: DefaultColor.plum,
                .string: DefaultColor.leaf,
                .comment: ThemeColor.fixed(0xA08A73, 0x8C7A69),
                .number: DefaultColor.apricot,
                .type: DefaultColor.teal,
                .function: palette.ink,
                .operatorOrPunctuation: ThemeColor.fixed(0x8A7764, 0xA8978A),
            ],
            // Teal; leaf beside a teal or cyan accent.
            branches: [
                BranchTones(trunk: DefaultColor.teal, tones: [.orange, .pink, .violet, .blue, .green]),
                BranchTones(trunk: DefaultColor.leafTone, tones: [.orange, .pink, .violet, .blue, .cyan]),
            ],
            toneColors: DefaultColor.toneColors,
            sidebarSelection: DefaultColor.butter,
            sidebarSelectionText: ThemeColor.text(0x2B2119, 0xFFF2DA),
            sidebarSelectionIcon: palette.accent,
            sidebarSelectionIsBold: true,
            sectionLabel: SectionLabelStyle(isUppercase: false, size: 12, weight: .bold, tracking: 0),
            radii: ThemeRadii(row: 12, card: 18, small: 6),
            commitTitle: TitleStyle(size: 20, weight: .bold),
            buttonWeights: ButtonWeights(quiet: .semibold, prominent: .bold),
            graph: GraphStyle(lineWidth: 3, lanePitch: 17),
            refTag: RefTagStyle(alpha: (0.16, 0.24), textMix: (0.38, 0.20), ink: 0x2B2119),
            avatarShape: .circle,
            controls: ControlStyle(prominentShadow: nil, flatInCards: true, lip: 3),
            scrollEdgeFade: 24
        )
    }
}

/// Default's status, branch, and code colors, light and dark.
nonisolated private enum DefaultColor {
    static let leaf = ThemeColor.fixed(0x2F8A4C, 0x7FD49A)
    static let tomato = ThemeColor.fixed(0xD8432F, 0xFF8B78)
    static let honey = ThemeColor.fixed(0xB97800, 0xF5C451)
    static let grape = ThemeColor.fixed(0x8A4FD0, 0xC59BFF)
    static let plum = ThemeColor.fixed(0xC2347F, 0xF57FB8)
    static let teal = ThemeColor.fixed(0x13858A, 0x5ECFCF)
    static let apricot = ThemeColor.fixed(0xD9690F, 0xFFA35C)
    static let blue = ThemeColor.fixed(0x3D6FE0, 0x86A8FF)
    static let leafTone = ThemeColor.fixed(0x3B9152, 0x86D79E)

    static let toneColors = ToneColors(pink: plum, violet: grape, orange: apricot, green: leafTone, blue: blue, cyan: teal)

    /// Every selection: a butter-yellow highlight (a honey glow in dark).
    static let butter = ThemeColor.wash(.hex(0xFFC21A), 0.30, .hex(0xFFB830), 0.17)
}
