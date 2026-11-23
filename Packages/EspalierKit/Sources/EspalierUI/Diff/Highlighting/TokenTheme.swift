// The colors of syntax tokens in diffs: the theme's own
// (`Theme.syntaxColors`), and the text color for a style it has none for.

import AppKit
import Synchronization

/// The colors of the eight token styles, in the current theme.
public enum TokenTheme {
    /// The color of text in `style`.
    public static func color(for style: TokenStyle) -> NSColor {
        colors(in: Theme.current)[Int(style.rawValue)]
    }

    /// Each theme's colors, by style, worked out once.
    private static let cache = Mutex<[ObjectIdentifier: [NSColor]]>([:])

    private static func colors(in theme: Theme) -> [NSColor] {
        let key = ObjectIdentifier(theme)
        if let colors = cache.withLock({ $0[key] }) {
            return colors
        }
        let colors = TokenStyle.allCases.map { style in
            theme.syntaxColors[style] ?? theme.text
        }
        cache.withLock { $0[key] = colors }
        return colors
    }
}
