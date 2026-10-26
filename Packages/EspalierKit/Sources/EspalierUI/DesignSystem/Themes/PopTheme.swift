// Pop: bright and confident. Crisp white panes, a sidebar tinted with the
// palette's accent, and saturated color in solid shapes: the prominent
// action, ref tags, file badges, monograms, and a bold graph whose current
// commit has a halo. Section labels and the sidebar's counts take the
// accent's ink; a selected row is a tint with a bar in the accent at its
// leading edge, the sidebar's bold. Buttons are semibold, the prominent one
// bold.

import AppKit
import EspalierCore
import SwiftUI

nonisolated extension ThemeDefinition {
    static func pop(_ palette: PaletteColors) -> ThemeDefinition {
        let ink = palette.ink
        let sidebar = palette.sidebarTint
        // The accent's ink over the sidebar; the ink itself under Increase
        // Contrast.
        func inkOverSidebar(_ fraction: CGFloat) -> NSColor {
            .espalierDynamic { variant in
                let resolvedInk = ink.resolved(in: variant)
                guard !variant.isHighContrast else {
                    return resolvedInk
                }
                return sidebar.resolved(in: variant).blended(withFraction: fraction, of: resolvedInk) ?? resolvedInk
            }
        }
        return ThemeDefinition(
            theme: .pop,
            palette: palette.palette,
            background: ThemeColor.surface(0xFFFFFF, 0x16161C),
            sidebar: sidebar,
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
            linkBase: ink,
            accentSoftAlpha: (0.10, 0.15),
            textSelectionAlpha: (0.15, 0.18),
            prominent: palette.prominent,
            prominentText: palette.prominentText,
            marks: palette.marks,
            add: ThemeColor.fixed(0x17936A, 0x3CCB98),
            // Red; crimson beside an orange accent.
            delete: PopColor.red,
            deleteNearAccent: ThemeColor.fixed(0xC8264E, 0xFF8AA5),
            modified: ThemeColor.fixed(0xFFC53D, 0xF2B23A),
            renamed: palette.accent,
            conflictOurs: PopColor.cyan,
            conflictTheirs: PopColor.orange,
            // Emerald; green beside a teal accent.
            branches: BranchTones(trunk: ThemeColor.fixed(0x17936A, 0x3CCB98), tones: PopColor.tones),
            branchesNearAccent: BranchTones(trunk: ThemeColor.fixed(0x2F9E44, 0x5FD07A), tones: PopColor.tones),
            toneColors: PopColor.toneColors,
            sidebarSelection: ThemeColor.wash(palette.accent, 0.14, 0.17),
            sidebarSelectionText: palette.deepInk,
            sidebarSelectionIcon: palette.accent,
            selectionBar: true,
            sidebarSelectionIsBold: true,
            sidebarSelectionTintsCounts: true,
            // The sidebar's tertiary text (counts, pull request numbers,
            // header buttons): the ink 70% over the sidebar.
            sidebarText3: inkOverSidebar(0.70),
            aheadText: ink,
            // Section labels: the ink three quarters over the sidebar.
            sectionLabel: SectionLabelStyle(isUppercase: true, size: 10.75, weight: .bold, tracking: 0.08, color: inkOverSidebar(0.75)),
            radii: ThemeRadii(row: 10, card: 14, small: 5, tag: nil),
            commitTitle: TitleStyle(size: 18, weight: .bold),
            buttonWeights: ButtonWeights(quiet: .semibold, prominent: .bold),
            graph: GraphStyle(lineWidth: 4, lanePitch: 17, node: .haloedDot),
            refTag: RefTagStyle(fill: .solid(darken: 0.10), currentUsesProminent: true),
            statusBadge: StatusBadgeStyle(fill: .solid, shape: .roundedSquare),
            // Saturated, as solid as the tags and badges.
            monogramTone: MonogramTone(lightness: (0.62, 0.58), chroma: (0.19, 0.16))
        )
    }
}

/// Pop's status and branch colors, light and dark.
nonisolated private enum PopColor {
    static let orange = ThemeColor.fixed(0xE8590C, 0xFF9A5C)
    static let blue = ThemeColor.fixed(0x4F6BE8, 0x7F96FF)
    static let pink = ThemeColor.fixed(0xD6338A, 0xF062B0)
    static let cyan = ThemeColor.fixed(0x0891B2, 0x22D3EE)
    static let violet = ThemeColor.fixed(0x9333EA, 0xC084FC)
    static let red = ThemeColor.fixed(0xC8361E, 0xFF9480)

    static let tones: [TrackPalette.Tone] = [.orange, .blue, .pink, .cyan, .violet]
    static let toneColors: [TrackPalette.Tone: NSColor] = [
        .orange: orange, .blue: blue, .pink: pink,
        .cyan: cyan, .violet: violet,
    ]
}
