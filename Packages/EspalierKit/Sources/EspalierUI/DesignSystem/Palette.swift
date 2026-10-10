// Espalier's colors. Every color is a dynamic NSColor with light, dark, and
// Increase Contrast variants, resolved where they're drawn. The surfaces,
// lines, and text are fixed values; the accent is the system's accent
// color. Status colors used as text are the status hues, darkened (light)
// or lightened (dark) just enough to read: text 4.5:1, marks 3:1, and 1.5
// more under Increase Contrast.

import AppKit
import SwiftUI

/// The four appearances Espalier's colors vary by.
nonisolated public enum AppearanceVariant: String, CaseIterable, Sendable {
    case light, dark, highContrastLight, highContrastDark

    /// The system appearance of the variant.
    public var appearanceName: NSAppearance.Name {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        case .highContrastLight: .accessibilityHighContrastAqua
        case .highContrastDark: .accessibilityHighContrastDarkAqua
        }
    }

    /// An appearance to resolve colors in. The Increase Contrast names
    /// can't make appearances (they only match), so those resolve in the
    /// plain light or dark appearance.
    public var appearance: NSAppearance {
        NSAppearance(named: appearanceName) ?? NSAppearance(named: isDark ? .darkAqua : .aqua)!
    }

    /// Whether the variant is dark.
    public var isDark: Bool {
        self == .dark || self == .highContrastDark
    }

    /// Whether the variant has Increase Contrast on.
    public var isHighContrast: Bool {
        self == .highContrastLight || self == .highContrastDark
    }

    /// The variant an appearance matches best.
    public static func of(_ appearance: NSAppearance) -> AppearanceVariant {
        let names: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        switch appearance.bestMatch(from: names) {
        case .darkAqua?: return .dark
        case .accessibilityHighContrastAqua?: return .highContrastLight
        case .accessibilityHighContrastDarkAqua?: return .highContrastDark
        default: return .light
        }
    }
}

extension NSColor {
    /// A color that resolves per appearance. The Increase Contrast variants
    /// default to the plain ones.
    nonisolated public static func espalierDynamic(
        light: NSColor,
        dark: NSColor,
        highContrastLight: NSColor? = nil,
        highContrastDark: NSColor? = nil
    ) -> NSColor {
        let highContrastLight = highContrastLight ?? light
        let highContrastDark = highContrastDark ?? dark
        return NSColor(name: nil) { appearance in
            switch AppearanceVariant.of(appearance) {
            case .light: light
            case .dark: dark
            case .highContrastLight: highContrastLight
            case .highContrastDark: highContrastDark
            }
        }
    }

    /// A color that's computed per appearance when it's drawn, for colors
    /// that follow the user's accent color.
    nonisolated public static func espalierDynamic(_ make: @escaping @Sendable (AppearanceVariant) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            make(AppearanceVariant.of(appearance))
        }
    }

    /// An sRGB color from its hex value, `0xRRGGBB`.
    nonisolated public static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// The color as it resolves in `variant`, in sRGB.
    nonisolated public func resolved(in variant: AppearanceVariant) -> NSColor {
        var result: NSColor?
        variant.appearance.performAsCurrentDrawingAppearance {
            result = self.usingColorSpace(.sRGB)
        }
        return result ?? self
    }
}

/// WCAG 2 contrast between colors.
nonisolated public enum ColorContrast {
    /// The contrast ratio of two opaque sRGB colors, 1 to 21.
    public static func ratio(_ first: NSColor, _ second: NSColor) -> Double {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// WCAG relative luminance of an sRGB color.
    public static func luminance(_ color: NSColor) -> Double {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent) + 0.0722 * linear(srgb.blueComponent)
    }

    /// `color`, darkened (on a light background) or lightened (on a dark
    /// one) in small steps until it reaches `target` against `background`.
    public static func adjust(_ color: NSColor, toReach target: Double, against background: NSColor) -> NSColor {
        let towards: NSColor = luminance(background) > 0.5 ? .black : .white
        var adjusted = color.usingColorSpace(.sRGB) ?? color
        for _ in 0..<50 where ratio(adjusted, background) < target {
            adjusted = adjusted.blended(withFraction: 0.04, of: towards)?.usingColorSpace(.sRGB) ?? adjusted
        }
        return adjusted
    }

    /// `color` over `background`: a translucent color as it reads on an
    /// opaque one.
    public static func composite(_ color: NSColor, over background: NSColor) -> NSColor {
        let front = color.usingColorSpace(.sRGB) ?? color
        let back = background.usingColorSpace(.sRGB) ?? background
        return back.blended(withFraction: front.alphaComponent, of: front.withAlphaComponent(1)) ?? back
    }
}

/// System colors, adapted for Espalier's contrast targets. Syntax tokens
/// and a few marks still start from them.
nonisolated public enum SystemTone: String, CaseIterable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    /// The system color.
    public var base: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .mint: .systemMint
        case .teal: .systemTeal
        case .cyan: .systemCyan
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .brown: .systemBrown
        case .gray: .systemGray
        }
    }

    /// The tone for text or marks: the system shade, adjusted until it
    /// reaches `minimumContrast` against the content background (or that
    /// background under this tone's `tint`, for text on a tinted fill), and
    /// 1.5 more under Increase Contrast.
    public func foreground(minimumContrast: Double, tint: (light: CGFloat, dark: CGFloat)? = nil) -> NSColor {
        Palette.readable(base, minimumContrast: minimumContrast, tint: tint)
    }

    /// A translucent fill of the tone; Increase Contrast multiplies the
    /// alpha by 1.6.
    public func tint(light lightAlpha: CGFloat, dark darkAlpha: CGFloat) -> NSColor {
        Palette.tint(base, light: lightAlpha, dark: darkAlpha)
    }

    /// The hue of the plain light shade, 0 to 1.
    public var hue: CGFloat {
        base.resolved(in: .light).hueComponent
    }
}

/// Espalier's colors.
nonisolated public enum Palette {
    // MARK: Surfaces

    /// Content panes and the toolbar.
    public static let background = NSColor.espalierDynamic(light: .hex(0xFFFFFF), dark: .hex(0x1A1A1D))
    /// The sidebar.
    public static let sidebar = NSColor.espalierDynamic(light: .hex(0xF3F3F5), dark: .hex(0x141416))
    /// Search fields, segmented tracks, neutral chips.
    public static let field = NSColor.espalierDynamic(
        light: .hex(0xF2F2F5), dark: .hex(0x232327),
        highContrastLight: .hex(0xE6E6EA), highContrastDark: .hex(0x2E2E33)
    )
    /// Diff hunk headers.
    public static let hunk = NSColor.espalierDynamic(light: .hex(0xF6F7F9), dark: .hex(0x202024))
    /// A hovered row.
    public static let hover = NSColor.espalierDynamic(
        light: NSColor.black.withAlphaComponent(0.045), dark: NSColor.white.withAlphaComponent(0.05),
        highContrastLight: NSColor.black.withAlphaComponent(0.08), highContrastDark: NSColor.white.withAlphaComponent(0.09)
    )
    /// The sidebar's selected item: a neutral wash, black 6.5% (white 5% in
    /// dark), so the sidebar stays neutral; `accentSoft` is the selection
    /// everywhere else.
    public static let sidebarSelection = NSColor.espalierDynamic(
        light: NSColor.black.withAlphaComponent(0.065), dark: NSColor.white.withAlphaComponent(0.05),
        highContrastLight: NSColor.black.withAlphaComponent(0.11), highContrastDark: NSColor.white.withAlphaComponent(0.09)
    )
    /// Dividers and hairlines.
    public static let line = NSColor.espalierDynamic(
        light: .hex(0xE8E8EC), dark: .hex(0x2A2A2F),
        highContrastLight: .hex(0xB9B9C1), highContrastDark: .hex(0x55555D)
    )
    /// Checkbox borders, key caps, outlined pills.
    public static let line2 = NSColor.espalierDynamic(
        light: .hex(0xD6D6DC), dark: .hex(0x38383F),
        highContrastLight: .hex(0x9A9BA3), highContrastDark: .hex(0x6C6C75)
    )

    // MARK: Text

    /// Primary text.
    public static let text = NSColor.espalierDynamic(
        light: .hex(0x1B1B1F), dark: .hex(0xECECEF),
        highContrastLight: .black, highContrastDark: .white
    )
    /// Secondary text and icons.
    public static let text2 = NSColor.espalierDynamic(
        light: .hex(0x5F6068), dark: .hex(0xA1A1AA),
        highContrastLight: .hex(0x3E3F45), highContrastDark: .hex(0xCACAD1)
    )
    /// Tertiary text: counts, paths, merge commits' summaries.
    public static let text3 = NSColor.espalierDynamic(
        light: .hex(0x9A9BA3), dark: .hex(0x6C6C75),
        highContrastLight: .hex(0x5F6068), highContrastDark: .hex(0xA1A1AA)
    )
    /// A placeholder drawn by hand, as the composer's description draws its
    /// own.
    public static var placeholderText: NSColor { text3 }

    // MARK: Accent

    /// Selection, checkboxes, included lines, links: the system accent.
    public static var accent: NSColor { .controlAccentColor }

    /// Selected rows and chips: the accent at 9% (14% in dark).
    public static let accentSoft = NSColor.espalierDynamic { variant in
        let accent = NSColor.controlAccentColor.resolved(in: variant)
        let alpha: CGFloat = variant.isDark ? 0.14 : 0.09
        return accent.withAlphaComponent(variant.isHighContrast ? alpha * 1.6 : alpha)
    }

    /// The commit message field that has focus: the accent at 6% (10% in
    /// dark), fainter than a selection.
    public static let accentFaint = NSColor.espalierDynamic { variant in
        let accent = NSColor.controlAccentColor.resolved(in: variant)
        let alpha: CGFloat = variant.isDark ? 0.10 : 0.06
        return accent.withAlphaComponent(variant.isHighContrast ? alpha * 1.6 : alpha)
    }

    /// The diff's included line number cells: the accent at 16% (24% in
    /// dark).
    public static let accentMid = NSColor.espalierDynamic { variant in
        let accent = NSColor.controlAccentColor.resolved(in: variant)
        let alpha: CGFloat = variant.isDark ? 0.24 : 0.16
        return accent.withAlphaComponent(variant.isHighContrast ? alpha * 1.6 : alpha)
    }

    /// A deeper accent for prominent fills under white text: `#0064E1`
    /// for the default blue in light; the accent itself in dark.
    public static let button = NSColor.espalierDynamic { variant in
        let accent = NSColor.controlAccentColor.resolved(in: variant)
        guard !variant.isDark else {
            return accent
        }
        if isDefaultBlue(accent) {
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

    /// Whether `accent` is the system's default blue (`#007AFF`).
    nonisolated static func isDefaultBlue(_ accent: NSColor) -> Bool {
        let srgb = accent.usingColorSpace(.sRGB) ?? accent
        return abs(srgb.redComponent - 0) < 0.02 && abs(srgb.greenComponent - 0x7A / 255) < 0.02 && abs(srgb.blueComponent - 1) < 0.02
    }

    // MARK: Controls

    /// Quiet buttons, cards, chips, toasts.
    public static let quiet = NSColor.espalierDynamic(light: .hex(0xFFFFFF), dark: .hex(0x2A2A2F))
    /// Secondary buttons (Cancel in sheets, Undo).
    public static let soft = NSColor.espalierDynamic(
        light: .hex(0xEDEDF0), dark: .hex(0x2E2E34),
        highContrastLight: .hex(0xDCDCE1), highContrastDark: .hex(0x3A3A41)
    )
    /// A disabled control, whole, fades to this opacity.
    public static let disabledOpacity: CGFloat = 0.45

    // MARK: Status

    /// Additions and new files.
    public static let add = NSColor.espalierDynamic(light: .hex(0x16924C), dark: .hex(0x3FCF7F))
    /// Deletions and deleted files.
    public static let delete = NSColor.espalierDynamic(light: .hex(0xD33A3A), dark: .hex(0xFF6B6B))
    /// Modified files, conflicts, warnings.
    public static let modified = NSColor.espalierDynamic(light: .hex(0xC07F00), dark: .hex(0xF2B53A))
    /// Renamed and copied files.
    public static let renamed = NSColor.espalierDynamic(light: .hex(0x7C3AED), dark: .hex(0xA78BFA))

    // MARK: Meaning

    /// Warnings in text.
    public static let warning = readable(modified, minimumContrast: 4.5)
    /// Errors in text (inline AI failures).
    public static let error = readable(delete, minimumContrast: 4.5)
    /// Success marks (toasts, checks).
    public static let success = readable(add, minimumContrast: 3)
    /// Warning marks (the conflict triangle).
    public static let warningMark = readable(modified, minimumContrast: 3)

    /// The fill behind a file status's letter: 15%.
    static let statusTint: (light: CGFloat, dark: CGFloat) = (0.15, 0.15)

    private static let statusForegrounds: [FileStatusKind: NSColor] = Dictionary(
        uniqueKeysWithValues: FileStatusKind.allCases.map { ($0, readable($0.color, minimumContrast: 4.5, tint: statusTint)) }
    )

    private static let statusBackgrounds: [FileStatusKind: NSColor] = Dictionary(
        uniqueKeysWithValues: FileStatusKind.allCases.map { ($0, tint($0.color, light: statusTint.light, dark: statusTint.dark)) }
    )

    private static let checksColors: [ChecksState: NSColor] = [
        .success: readable(add, minimumContrast: 3),
        .failure: readable(delete, minimumContrast: 3),
        .pending: readable(modified, minimumContrast: 3),
        .neutral: text2,
    ]

    /// The color of a file status's letter.
    public static func statusForeground(_ kind: FileStatusKind) -> NSColor {
        statusForegrounds[kind] ?? text
    }

    /// The fill behind a file status's letter.
    public static func statusBackground(_ kind: FileStatusKind) -> NSColor {
        statusBackgrounds[kind] ?? field
    }

    /// The color of a checks status glyph.
    public static func checks(_ state: ChecksState) -> NSColor {
        checksColors[state] ?? text2
    }

    // MARK: Deriving colors

    /// `color` adjusted until it reaches `minimumContrast` against the
    /// content background (under `color`'s own `tint`, for text on a tinted
    /// fill), and 1.5 more under Increase Contrast.
    nonisolated static func readable(_ color: NSColor, minimumContrast: Double, tint: (light: CGFloat, dark: CGFloat)? = nil) -> NSColor {
        let colors = AppearanceVariant.allCases.map { variant in
            let base = color.resolved(in: variant)
            var background = Palette.background.resolved(in: variant)
            if let tint {
                let alpha = variant.isDark ? tint.dark : tint.light
                background = background.blended(withFraction: variant.isHighContrast ? min(1, alpha * 1.6) : alpha, of: base) ?? background
            }
            let target = variant.isHighContrast ? minimumContrast + 1.5 : minimumContrast
            return ColorContrast.adjust(base, toReach: target, against: background)
        }
        return .espalierDynamic(light: colors[0], dark: colors[1], highContrastLight: colors[2], highContrastDark: colors[3])
    }

    /// A translucent fill of `color`; Increase Contrast multiplies the alpha
    /// by 1.6.
    nonisolated static func tint(_ color: NSColor, light lightAlpha: CGFloat, dark darkAlpha: CGFloat) -> NSColor {
        let light = color.resolved(in: .light)
        let dark = color.resolved(in: .dark)
        return .espalierDynamic(
            light: light.withAlphaComponent(lightAlpha),
            dark: dark.withAlphaComponent(darkAlpha),
            highContrastLight: light.withAlphaComponent(min(1, lightAlpha * 1.6)),
            highContrastDark: dark.withAlphaComponent(min(1, darkAlpha * 1.6))
        )
    }
}

extension Color {
    /// A SwiftUI color from one of Espalier's dynamic colors.
    public init(espalier color: NSColor) {
        self.init(nsColor: color)
    }
}

extension ShapeStyle where Self == Color {
    /// Palette colors as SwiftUI shape styles: `.foregroundStyle(.text2)`.
    public static var field: Color { Color(nsColor: Palette.field) }
    public static var line: Color { Color(nsColor: Palette.line) }
    public static var line2: Color { Color(nsColor: Palette.line2) }
    public static var text: Color { Color(nsColor: Palette.text) }
    public static var text2: Color { Color(nsColor: Palette.text2) }
    public static var text3: Color { Color(nsColor: Palette.text3) }
    public static var accentSoft: Color { Color(nsColor: Palette.accentSoft) }
    public static var quiet: Color { Color(nsColor: Palette.quiet) }
    public static var soft: Color { Color(nsColor: Palette.soft) }
}
