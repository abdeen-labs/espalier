// Background tints: a design theme's opaque surfaces (the panes, sidebar,
// fields, hunk headers, lines, cards, and controls' fills; not Pop's
// sidebar, which keeps its accent) in the tint's hue, each at its own
// luminance, so text reads on them as it does on the theme's own. A
// surface's chroma grows with its depth (away from white in light, away
// from black in dark), as the themes' own tints do; a surface too near
// white to carry the hue is as light as the hue allows. Neutral takes the
// hue away. Translucent washes (hover, selection, the scrim) stay
// as they are and take the tint from what's under them; text, the accent,
// and status colors stay the theme's. Hue and chroma are OKLCH's.

import AppKit
import EspalierCore
import Synchronization

nonisolated extension BackgroundTint {
    /// The tint's hue, in degrees; nil for the theme's own and for Neutral.
    var hue: Double? {
        switch self {
        case .own, .neutral: nil
        case .warm: 75
        case .cool: 250
        case .sage: 150
        case .rose: 10
        case .lavender: 300
        }
    }

    /// The chroma of a surface of `lightness` (0 to 1): a little on white,
    /// growing toward gray in light; proportional to lightness in dark.
    func chroma(lightness: Double, isDark: Bool) -> Double {
        guard hue != nil else {
            return 0
        }
        return isDark ? 0.045 * lightness : 0.006 + 0.18 * (1 - lightness)
    }
}

nonisolated extension ThemeDefinition {
    /// The definition with its opaque surfaces in `tint`; the theme's own
    /// is the definition itself.
    func tinted(_ tint: BackgroundTint) -> ThemeDefinition {
        guard tint != .own else {
            return self
        }
        func tinted(_ color: NSColor) -> NSColor {
            OKLCH.tinted(color, tint)
        }
        var definition = self
        definition.tint = tint
        definition.background = tinted(background)
        if sidebarTakesTint {
            definition.sidebar = tinted(sidebar)
        }
        definition.field = tinted(field)
        definition.hunk = tinted(hunk)
        definition.line = tinted(line)
        definition.line2 = tinted(line2)
        definition.quiet = tinted(quiet)
        definition.soft = tinted(soft)
        definition.quietControl = quietControl.map(tinted)
        definition.segmentSelection = segmentSelection.map(tinted)
        definition.backdrop = backdrop.map(tinted)
        definition.sidebarSelection = tinted(sidebarSelection)
        return definition
    }
}

/// OKLab in polar form: lightness, chroma, and hue.
nonisolated enum OKLCH {
    /// `color` in `tint`, as it resolves in the appearance it's drawn in
    /// (Increase Contrast's values too); where it's translucent, as it is.
    /// Each tinted color is worked out once.
    static func tinted(_ color: NSColor, _ tint: BackgroundTint) -> NSColor {
        NSColor(name: nil) { appearance in
            var source = color
            appearance.performAsCurrentDrawingAppearance {
                source = color.usingColorSpace(.sRGB) ?? color
            }
            guard source.alphaComponent == 1 else {
                return source
            }
            let key = TintKey(
                red: source.redComponent, green: source.greenComponent, blue: source.blueComponent,
                tint: tint, isDark: AppearanceVariant.of(appearance).isDark
            )
            if let made = tints.withLock({ $0[key] }) {
                return made
            }
            let made = tinted(source, tint, isDark: key.isDark)
            tints.withLock { $0[key] = made }
            return made
        }
    }

    private struct TintKey: Hashable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let tint: BackgroundTint
        let isDark: Bool
    }

    private static let tints = Mutex<[TintKey: NSColor]>([:])

    /// An opaque sRGB color in `tint`, at its own luminance where the tint
    /// can reach it.
    static func tinted(_ color: NSColor, _ tint: BackgroundTint, isDark: Bool) -> NSColor {
        let rgb = linear(color)
        let lightness = lab(rgb).lightness
        let chroma = tint.chroma(lightness: lightness, isDark: isDark)
        let hue = (tint.hue ?? 0) * .pi / 180
        func at(_ lightness: Double) -> RGB {
            Self.rgb(Lab(lightness: lightness, a: chroma * cos(hue), b: chroma * sin(hue)))
        }
        // The lightness at which the tinted color has the color's luminance,
        // which rises with lightness.
        let target = luminance(rgb)
        var low = 0.0
        var high = 1.0
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if luminance(at(middle)) < target {
                low = middle
            } else {
                high = middle
            }
        }
        var tinted = low
        if !at(tinted).isInGamut, target > 0.5 {
            // Too near white for the hue: as light as it can be.
            low = 0
            high = tinted
            for _ in 0..<40 {
                let middle = (low + high) / 2
                if at(middle).isInGamut {
                    low = middle
                } else {
                    high = middle
                }
            }
            tinted = low
        }
        return at(tinted).color
    }

    /// `color` with `factor` times its chroma (as much as sRGB holds), at
    /// its lightness.
    static func saturated(_ color: NSColor, by factor: Double) -> NSColor {
        let original = lab(linear(color))
        var low = 1.0
        var high = factor
        func at(_ scale: Double) -> RGB {
            rgb(Lab(lightness: original.lightness, a: original.a * scale, b: original.b * scale))
        }
        guard !at(high).isInGamut else {
            return at(high).color
        }
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if at(middle).isInGamut {
                low = middle
            } else {
                high = middle
            }
        }
        return at(low).color
    }

    // MARK: Conversions

    struct Lab {
        var lightness: Double
        var a: Double
        var b: Double
    }

    /// Linear sRGB.
    struct RGB {
        var red: Double
        var green: Double
        var blue: Double

        var isInGamut: Bool {
            [red, green, blue].allSatisfy { $0 >= -1e-6 && $0 <= 1 + 1e-6 }
        }

        /// The color, its channels clamped to sRGB.
        var color: NSColor {
            func encoded(_ channel: Double) -> CGFloat {
                let channel = min(max(channel, 0), 1)
                return CGFloat(channel <= 0.0031308 ? 12.92 * channel : 1.055 * pow(channel, 1 / 2.4) - 0.055)
            }
            return NSColor(srgbRed: encoded(red), green: encoded(green), blue: encoded(blue), alpha: 1)
        }
    }

    private static func linear(_ color: NSColor) -> RGB {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func decoded(_ channel: CGFloat) -> Double {
            let channel = Double(channel)
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return RGB(red: decoded(srgb.redComponent), green: decoded(srgb.greenComponent), blue: decoded(srgb.blueComponent))
    }

    /// WCAG relative luminance.
    private static func luminance(_ rgb: RGB) -> Double {
        0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    }

    private static func lab(_ rgb: RGB) -> Lab {
        let l = cbrt(0.4122214708 * rgb.red + 0.5363325363 * rgb.green + 0.0514459929 * rgb.blue)
        let m = cbrt(0.2119034982 * rgb.red + 0.6806995451 * rgb.green + 0.1073969566 * rgb.blue)
        let s = cbrt(0.0883024619 * rgb.red + 0.2817188376 * rgb.green + 0.6299787005 * rgb.blue)
        return Lab(
            lightness: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    private static func rgb(_ lab: Lab) -> RGB {
        func cube(_ value: Double) -> Double {
            value * value * value
        }
        let l = cube(lab.lightness + 0.3963377774 * lab.a + 0.2158037573 * lab.b)
        let m = cube(lab.lightness - 0.1055613458 * lab.a - 0.0638541728 * lab.b)
        let s = cube(lab.lightness - 0.0894841775 * lab.a - 1.2914855480 * lab.b)
        return RGB(
            red: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            green: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            blue: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }
}
