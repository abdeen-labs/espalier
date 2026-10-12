// The colors of syntax tokens in diffs. Eight styles on system colors (or
// the theme's own, `Theme.syntaxColors`), each
// a dynamic color with light, dark, and Increase Contrast variants, adjusted
// until it reads at 4.5:1 on a row, also under the added and deleted tints
// (1.5 more under Increase Contrast).

import AppKit
import Synchronization

/// The colors of the eight token styles, in the current theme.
public enum TokenTheme {
    /// The color of text in `style`.
    public static func color(for style: TokenStyle) -> NSColor {
        colors(in: Theme.current)[Int(style.rawValue)]
    }

    /// The tone each style starts from.
    static func tone(for style: TokenStyle) -> SystemTone? {
        switch style {
        case .keyword: .pink
        case .string: .red
        case .comment: .gray
        case .number: .blue
        case .type: .teal
        case .function: .indigo
        case .operatorOrPunctuation, .plain: nil
        }
    }

    /// Each theme's colors, by style, worked out once.
    private static let cache = Mutex<[ObjectIdentifier: [NSColor]]>([:])

    private static func colors(in theme: Theme) -> [NSColor] {
        let key = ObjectIdentifier(theme)
        if let colors = cache.withLock({ $0[key] }) {
            return colors
        }
        let colors = TokenStyle.allCases.map { style in
            guard let tone = tone(for: style) else {
                // Operators and punctuation read as plain text, as in Xcode.
                return NSColor.labelColor
            }
            return readableColor(theme.syntaxColors[style] ?? tone.base, in: theme)
        }
        cache.withLock { $0[key] = colors }
        return colors
    }

    /// The shade of `color` (the theme's for the style, else the style's
    /// tone) that reaches 4.5:1 (6:1 under Increase Contrast) on a row and
    /// on the darker of the added and deleted tints.
    private static func readableColor(_ color: NSColor, in theme: Theme) -> NSColor {
        let variants = AppearanceVariant.allCases.map { variant -> NSColor in
            let base = color.resolved(in: variant)
            let row = theme.background.resolved(in: variant)
            let target = variant.isHighContrast ? 6.0 : 4.5
            var color = base
            for tint in [theme.diff.addedChange, theme.diff.deletedChange] {
                let fill = tint.resolved(in: variant)
                let background = row.blended(withFraction: fill.alphaComponent, of: fill.withAlphaComponent(1)) ?? row
                color = ColorContrast.adjust(color, toReach: target, against: background)
            }
            return ColorContrast.adjust(color, toReach: target, against: row)
        }
        return .espalierDynamic(light: variants[0], dark: variants[1], highContrastLight: variants[2], highContrastDark: variants[3])
    }
}
