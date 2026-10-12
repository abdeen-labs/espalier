// Classic: Espalier's look before themes, and the default. Neutral gray
// surfaces, the Mac's accent color for selection, the current branch, and
// the one prominent action (deepened so white text reads on it), uppercase
// section labels, a transit-map graph of rings, and tinted ref tags and
// file badges.

import AppKit
import EspalierCore
import SwiftUI

nonisolated extension ThemeDefinition {
    static let classic = ThemeDefinition(
        theme: .classic,
        color: nil,
        background: ThemeColor.surface(0xFFFFFF, 0x1A1A1D),
        sidebar: ThemeColor.surface(0xF3F3F5, 0x141416),
        field: .espalierDynamic(
            light: .hex(0xF2F2F5), dark: .hex(0x232327),
            highContrastLight: .hex(0xE6E6EA), highContrastDark: .hex(0x2E2E33)
        ),
        hunk: ThemeColor.surface(0xF6F7F9, 0x202024),
        hover: .espalierDynamic(
            light: NSColor.black.withAlphaComponent(0.045), dark: NSColor.white.withAlphaComponent(0.05),
            highContrastLight: NSColor.black.withAlphaComponent(0.08), highContrastDark: NSColor.white.withAlphaComponent(0.09)
        ),
        line: .espalierDynamic(
            light: .hex(0xE8E8EC), dark: .hex(0x2A2A2F),
            highContrastLight: .hex(0xB9B9C1), highContrastDark: .hex(0x55555D)
        ),
        line2: .espalierDynamic(
            light: .hex(0xD6D6DC), dark: .hex(0x38383F),
            highContrastLight: .hex(0x9A9BA3), highContrastDark: .hex(0x6C6C75)
        ),
        quiet: ThemeColor.surface(0xFFFFFF, 0x2A2A2F),
        soft: .espalierDynamic(
            light: .hex(0xEDEDF0), dark: .hex(0x2E2E34),
            highContrastLight: .hex(0xDCDCE1), highContrastDark: .hex(0x3A3A41)
        ),
        scrim: .espalierDynamic(
            light: NSColor.black.withAlphaComponent(0.2), dark: NSColor.black.withAlphaComponent(0.45)
        ),
        text: .espalierDynamic(
            light: .hex(0x1B1B1F), dark: .hex(0xECECEF),
            highContrastLight: .black, highContrastDark: .white
        ),
        text2: .espalierDynamic(
            light: .hex(0x5F6068), dark: .hex(0xA1A1AA),
            highContrastLight: .hex(0x3E3F45), highContrastDark: .hex(0xCACAD1)
        ),
        text3: .espalierDynamic(
            light: .hex(0x9A9BA3), dark: .hex(0x6C6C75),
            highContrastLight: .hex(0x5F6068), highContrastDark: .hex(0xA1A1AA)
        ),
        accent: .controlAccentColor,
        prominent: classicProminent,
        add: .espalierDynamic(light: .hex(0x16924C), dark: .hex(0x3FCF7F)),
        delete: .espalierDynamic(light: .hex(0xD33A3A), dark: .hex(0xFF6B6B)),
        modified: .espalierDynamic(light: .hex(0xC07F00), dark: .hex(0xF2B53A)),
        renamed: .espalierDynamic(light: .hex(0x7C3AED), dark: .hex(0xA78BFA)),
        trunk: .espalierDynamic(light: .hex(0x0F766E), dark: .hex(0x2DD4BF)),
        tones: TrackPalette.tones,
        skipsToneNearestAccent: true,
        // A neutral wash, black 6.5% (white 5% in dark), so the sidebar
        // stays neutral.
        sidebarSelection: .espalierDynamic(
            light: NSColor.black.withAlphaComponent(0.065), dark: NSColor.white.withAlphaComponent(0.05),
            highContrastLight: NSColor.black.withAlphaComponent(0.11), highContrastDark: NSColor.white.withAlphaComponent(0.09)
        ),
        sectionLabel: SectionLabelStyle(isUppercase: true, size: 10, weight: .semibold, tracking: 0.07, color: nil),
        radii: ThemeRadii(row: 9, card: 14, small: 5, tag: nil),
        commitTitle: TitleStyle(size: 15, weight: .semibold),
        graph: GraphStyle(lineWidth: 3, lanePitch: 16, node: .ring),
        refTag: RefTagStyle(fill: .tinted(alpha: (0.14, 0.14), textMix: nil, ink: 0x000000), currentUsesProminent: false),
        statusBadge: StatusBadgeStyle(fill: .tinted, shape: .roundedSquare)
    )

    /// A deeper accent for prominent fills under white text: `#0064E1` for
    /// the default blue in light; the accent itself in dark.
    private static let classicProminent = NSColor.espalierDynamic { variant in
        let accent = NSColor.controlAccentColor.resolved(in: variant)
        guard !variant.isDark else {
            return accent
        }
        if Palette.isDefaultBlue(accent) {
            return .hex(0x0064E1)
        }
        let deeper = NSColor(
            hue: accent.hueComponent,
            saturation: accent.saturationComponent,
            brightness: accent.brightnessComponent * 0.88,
            alpha: 1
        )
        return ColorContrast.adjust(deeper, toReach: 4.5, against: .white)
    }
}
