// The colors of syntax tokens in diffs: eight styles on system colors, or
// the theme's own (`Theme.syntaxColors`).

import AppKit
import Synchronization

/// The colors of the eight token styles, in the current theme.
public enum TokenTheme {
    /// The color of text in `style`.
    public static func color(for style: TokenStyle) -> NSColor {
        colors(in: Theme.current)[Int(style.rawValue)]
    }

    /// Each style's system tone.
    static func tone(for style: TokenStyle) -> SystemTone? {
        switch style {
        case .keyword: .purple
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
                // Operators and punctuation: the theme's text color.
                return theme.text
            }
            return theme.syntaxColors[style] ?? tone.base
        }
        cache.withLock { $0[key] = colors }
        return colors
    }
}
