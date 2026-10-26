// Palettes: the accent color and the colors made from it, on every design
// theme, each made for one theme and each a hue of its own: System for
// Classic, Iris and Slate for Frost, Lagoon and Plum for Islands, and
// Tangerine, Magenta, and Volt for Pop. A palette is the accent; its ink, for links, labels, and
// counts in the accent's color (a little deeper in light, lighter in dark);
// its deep ink, for a selected item's title on the accent's wash; the
// prominent fill and its text; the marks drawn on the accent (a checkbox's
// check); and a faint tint of the accent's hue for a sidebar. What a
// palette doesn't set is made from its accent in OKLCH, so the Mac's accent
// color (System) has all of it whichever color it is. Each theme takes what
// it uses (Theme.swift): Classic and Frost the accent, Classic the
// prominent fill, Islands and Pop the inks and the prominent fill, and Pop
// the sidebar's tint.

import AppKit
import EspalierCore
import Synchronization

/// A palette's colors.
nonisolated struct PaletteColors: Sendable {
    let palette: DesignPalette
    /// Selection, checkboxes, included lines, the current branch.
    let accent: NSColor
    /// Links, section labels, and counts in the accent's color.
    let ink: NSColor
    /// A selected item's title on the accent's wash.
    let deepInk: NSColor
    /// The prominent fill, and the text on it (nil is white).
    let prominent: NSColor
    let prominentText: NSColor?
    /// The check, dash, radio dot, and switch knob on the accent.
    let marks: AccentMarks
    /// A sidebar tinted with the accent (Pop's).
    let sidebarTint: NSColor

    /// A palette from its accent, light and dark; nil values are made from
    /// the accent.
    private init(
        _ palette: DesignPalette,
        accent: NSColor,
        ink: NSColor? = nil,
        deepInk: NSColor? = nil,
        prominent: NSColor? = nil,
        prominentText: NSColor? = nil,
        marks: AccentMarks = .whiteOnDeep
    ) {
        self.palette = palette
        self.accent = accent
        self.ink = ink ?? OKLCH.adjusted(accent, light: .init(lightness: .by(-0.035), chroma: 0.93), dark: .init(lightness: .by(0.03), chroma: 0.88))
        self.deepInk = deepInk ?? OKLCH.adjusted(accent, light: .init(lightness: .by(-0.088), chroma: 0.84), dark: .init(lightness: .to(0.83), chroma: 0.6))
        self.prominent = prominent ?? Self.prominent(from: accent)
        self.prominentText = prominentText
        self.marks = marks
        sidebarTint = OKLCH.hueTint(of: accent, light: (lightness: 0.967, chroma: 0.017), dark: (lightness: 0.209, chroma: 0.028))
    }

    /// `palette`'s colors, made once.
    static func named(_ palette: DesignPalette) -> PaletteColors {
        if let made = cache.withLock({ $0[palette] }) {
            return made
        }
        let made = make(palette)
        cache.withLock { $0[palette] = made }
        return made
    }

    private static let cache = Mutex<[DesignPalette: PaletteColors]>([:])

    private static func make(_ palette: DesignPalette) -> PaletteColors {
        switch palette {
        case .system:
            // Classic's: the Mac's accent color, deepened for prominent
            // fills under white text.
            PaletteColors(palette, accent: .controlAccentColor, prominent: systemProminent, marks: .white)
        case .iris:
            // Frost's: a cool blue-violet.
            PaletteColors(palette, accent: ThemeColor.fixed(0x5B43E8, 0x8B7CF6))
        case .slate:
            // Frost's: a steel blue-gray, nearly as quiet as Frost's
            // surfaces.
            PaletteColors(palette, accent: ThemeColor.fixed(0x4B5C74, 0x95A6BE))
        case .lagoon:
            // Islands': a deep sea blue-green.
            PaletteColors(
                palette,
                accent: ThemeColor.fixed(0x0B7A8C, 0x5CC6D6),
                ink: ThemeColor.fixed(0x096C7C, 0x5CC6D6),
                deepInk: ThemeColor.fixed(0x075E6C, 0x93DCE7),
                prominent: ThemeColor.fixed(0x0A6F80, 0x0E8094)
            )
        case .plum:
            // Islands': a deep purple, between Iris and Magenta.
            PaletteColors(palette, accent: ThemeColor.fixed(0x781E98, 0xCA8DEF))
        case .tangerine:
            // Pop's: dark text and marks on the bright orange.
            PaletteColors(
                palette,
                accent: ThemeColor.fixed(0xF25C0F, 0xFF8A47),
                ink: ThemeColor.fixed(0xC2470A, 0xFF9A5E),
                // Deeper under Increase Contrast, on the stronger wash.
                deepInk: .espalierDynamic(
                    light: .hex(0xA63C06), dark: .hex(0xFFB386),
                    highContrastLight: .hex(0x8F3305), highContrastDark: .hex(0xFFB386)
                ),
                prominent: ThemeColor.fixed(0xFF6A1F, 0xFF7A2E),
                prominentText: ThemeColor.fixed(0x1B0F05, 0x1B0F05),
                marks: .color(ThemeColor.fixed(0x1B0F05, 0x1B0F05))
            )
        case .magenta:
            // Pop's.
            PaletteColors(
                palette,
                accent: ThemeColor.fixed(0xC2247E, 0xF062B0),
                ink: ThemeColor.fixed(0xAE1F71, 0xF47FBF),
                deepInk: ThemeColor.fixed(0x941A60, 0xF8A6D2),
                prominent: ThemeColor.fixed(0xC2247E, 0xD62C8C)
            )
        case .volt:
            // Pop's: an electric lime, its prominent fill neon with dark
            // text and marks.
            PaletteColors(
                palette,
                accent: ThemeColor.fixed(0x6E9E00, 0xB5EF32),
                ink: ThemeColor.fixed(0x548100, 0xC2F75B),
                deepInk: ThemeColor.fixed(0x3B6600, 0xDAF99E),
                prominent: ThemeColor.fixed(0xAFEC32, 0xACE92C),
                prominentText: ThemeColor.fixed(0x152502, 0x152502),
                marks: .color(ThemeColor.fixed(0x152502, 0x152502))
            )
        }
    }

    /// The prominent fill made from an accent: the accent as light draws
    /// it, in dark too, at a lightness of at least 0.56 there.
    private static func prominent(from accent: NSColor) -> NSColor {
        let raised = OKLCH.adjusted(accent, .init(lightness: .atLeast(0.56), chroma: 1))
        return NSColor.espalierDynamic { variant in
            variant.isDark ? raised.resolved(in: .light) : accent.resolved(in: variant)
        }
    }

    /// The Mac's accent for prominent fills under white text: `#0064E1` for
    /// the default blue in light, else the accent a little darker; the
    /// accent itself in dark.
    private static let systemProminent = NSColor.espalierDynamic { variant in
        let accent = NSColor.controlAccentColor.resolved(in: variant)
        guard !variant.isDark else {
            return accent
        }
        if Palette.isDefaultBlue(accent) {
            return .hex(0x0064E1)
        }
        return NSColor(
            hue: accent.hueComponent,
            saturation: accent.saturationComponent,
            brightness: accent.brightnessComponent * 0.88,
            alpha: 1
        )
    }
}

/// The marks drawn on the accent.
nonisolated enum AccentMarks: Sendable {
    /// White, or the background on a near-white accent (the Mac's accents).
    case white
    /// White on the deep accents of light; the background on the light
    /// ones of dark.
    case whiteOnDeep
    /// This color, light and dark.
    case color(NSColor)
}
