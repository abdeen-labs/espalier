// Candy pills: a name or a count on a soft tint of its color, the text in
// the color's deep shade, fully rounded. The commit button names its branch
// in one, the Changes header says how many files go into the commit in one,
// and the file rows' line counts are a pair of them. `TintedPillColors`
// makes the tint and the deep shade from any color, for SwiftUI and AppKit
// alike.

import AppKit
import SwiftUI

/// A pill's two colors from one: its tint and its deep shade.
public enum TintedPillColors {
    /// The pill's fill: the color at 16% (26% in dark).
    public static func fill(_ color: NSColor) -> NSColor {
        Palette.tint(color, light: Metrics.TintedPill.tint.light, dark: Metrics.TintedPill.tint.dark)
    }

    /// The pill's text: the color mixed toward espresso in light and
    /// toward white in dark, so it reads on the tint.
    public static func ink(_ color: NSColor) -> NSColor {
        let mix = Metrics.TintedPill.inkMix
        let text = Palette.text
        return NSColor.espalierDynamic { variant in
            let resolved = color.resolved(in: variant)
            let toward = variant.isDark ? NSColor.white : text.resolved(in: variant)
            return resolved.blended(withFraction: mix, of: toward) ?? resolved
        }
    }
}

/// A candy pill: an optional symbol and the text, in the deep shade of
/// `color` on its tint, fully rounded.
public struct TintedPill: View {
    private let text: String
    private let systemImage: String?
    private let color: NSColor
    private let font: Font

    /// - Parameters:
    ///   - color: The pill's color; its tint fills the pill.
    ///   - font: The text's font; the pill's height follows it.
    public init(_ text: String, systemImage: String? = nil, color: NSColor, font: Font = Typography.secondary.weight(.semibold)) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
        self.font = font
    }

    public var body: some View {
        HStack(spacing: Metrics.TintedPill.symbolSpacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .fontWeight(.bold)
            }
            Text(verbatim: text)
                .lineLimit(1)
        }
        .font(font)
        .foregroundStyle(Color(nsColor: TintedPillColors.ink(color)))
        .padding(.horizontal, Metrics.TintedPill.horizontalPadding)
        .padding(.vertical, Metrics.TintedPill.verticalPadding)
        .background(Capsule(style: .continuous).fill(Color(nsColor: TintedPillColors.fill(color))))
    }
}

extension Metrics {
    /// Candy pills.
    public enum TintedPill {
        /// The tint's alpha, light and dark.
        public static let tint: (light: CGFloat, dark: CGFloat) = (0.16, 0.26)
        /// How far the text's shade goes toward espresso (white in dark).
        public static let inkMix: CGFloat = 0.3
        public static let horizontalPadding: CGFloat = 8
        public static let verticalPadding: CGFloat = 2
        /// Between the symbol and the text.
        public static let symbolSpacing: CGFloat = 4
    }
}
