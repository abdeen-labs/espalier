// Candy pills: a name (a branch, a remote) or a count on a soft tint of its
// color, the text in the color's deep shade, fully rounded, in bold Allo.
// The tint and the shade are the theme's ref tag recipe (`RefTagStyle`), so
// a pill and the graph's tag of the same branch match. Candy dots are the
// same color as a small round sweet: the color, with a soft halo of its
// tint while it marks where you are.

import AppKit
import SwiftUI

/// A candy pill's colors.
nonisolated public enum CandyColors {
    /// `color`'s soft tint, the pill's fill.
    public static func fill(_ color: NSColor) -> NSColor {
        NSColor.espalierDynamic { variant in
            let tag = Theme.current.refTag
            return color.resolved(in: variant).withAlphaComponent(variant.isDark ? tag.alpha.dark : tag.alpha.light)
        }
    }

    /// `color`'s deep shade, the pill's text: mixed toward the theme's ink
    /// in light, toward white in dark.
    public static func ink(_ color: NSColor) -> NSColor {
        NSColor.espalierDynamic { variant in
            let tag = Theme.current.refTag
            let resolved = color.resolved(in: variant)
            return resolved.blended(
                withFraction: variant.isDark ? tag.textMix.dark : tag.textMix.light,
                of: variant.isDark ? .white : .hex(tag.ink)
            ) ?? resolved
        }
    }
}

/// A candy pill's size.
nonisolated public enum CandyPillSize: Sendable {
    /// In rows: 18 high.
    case small
    /// In popovers' headers and the sidebar's card: 22 high.
    case regular
    /// In the toolbar: 26 high.
    case large

    var height: CGFloat {
        switch self {
        case .small: 18
        case .regular: 22
        case .large: 26
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: 7
        case .regular: 9
        case .large: 11
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: 11
        case .regular: 12
        case .large: 13
        }
    }

    var symbolSize: CGFloat {
        fontSize - 1
    }
}

/// A candy pill: what's in it on a soft tint of `color`, in its deep shade.
public struct CandyPill<Content: View>: View {
    private let color: NSColor
    private let size: CandyPillSize
    private let content: Content

    /// - Parameter content: What the pill holds, drawn in the pill's font
    ///   and its deep shade.
    public init(color: NSColor, size: CandyPillSize = .small, @ViewBuilder content: () -> Content) {
        self.color = color
        self.size = size
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: Metrics.CandyPills.spacing) {
            content
        }
        .font(Typography.sans(size: size.fontSize, weight: .bold, relativeTo: .callout))
        .foregroundStyle(Color(nsColor: CandyColors.ink(color)))
        .lineLimit(1)
        .padding(.horizontal, size.horizontalPadding)
        .frame(height: size.height)
        .background(Capsule(style: .circular).fill(Color(nsColor: CandyColors.fill(color))))
    }
}

extension CandyPill where Content == CandyPillLabel {
    /// A name or a word, with a symbol before it.
    public init(_ text: String, systemImage: String? = nil, color: NSColor, size: CandyPillSize = .small, truncationMode: Text.TruncationMode = .middle) {
        self.init(color: color, size: size) {
            CandyPillLabel(text: text, systemImage: systemImage, symbolSize: size.symbolSize, truncationMode: truncationMode)
        }
    }
}

/// A candy pill's text and its symbol.
public struct CandyPillLabel: View {
    let text: String
    let systemImage: String?
    let symbolSize: CGFloat
    let truncationMode: Text.TruncationMode

    public var body: some View {
        if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .bold))
                .accessibilityHidden(true)
        }
        Text(text)
            .truncationMode(truncationMode)
    }
}

/// A branch's dot, a candy: its color, and around the one you're on a halo
/// of its tint, so it reads as "you are here".
public struct CandyDot: View {
    private let color: NSColor
    private let isHere: Bool

    public init(_ color: NSColor, isHere: Bool = false) {
        self.color = color
        self.isHere = isHere
    }

    public var body: some View {
        Circle()
            .fill(Color(nsColor: color).gradient)
            .frame(width: Metrics.CandyPills.dot, height: Metrics.CandyPills.dot)
            .padding(isHere ? Metrics.CandyPills.halo : 0)
            .background {
                if isHere {
                    Circle().fill(Color(nsColor: CandyColors.fill(color)))
                }
            }
            .accessibilityHidden(true)
    }
}

/// A count in a soft pill: Changes' files, a collapsed section's rows, a
/// stash's files. Neutral on the `field` fill, or in a color's tint.
public struct CountPill: View {
    private let text: String
    private let color: NSColor?

    /// - Parameter color: The pill's color; nil for a neutral pill.
    public init(_ text: String, color: NSColor? = nil) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(Typography.sans(size: 11, weight: .bold, relativeTo: .caption))
            .monospacedDigit()
            .foregroundStyle(color.map { Color(nsColor: CandyColors.ink($0)) } ?? .text2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minWidth: Metrics.CandyPills.countHeight, minHeight: Metrics.CandyPills.countHeight)
            .background(Capsule(style: .circular).fill(color.map { Color(nsColor: CandyColors.fill($0)) } ?? Color(espalier: Palette.field)))
            .fixedSize()
    }
}

extension Metrics {
    /// Candy pills, dots, and count pills.
    public enum CandyPills {
        /// Between a pill's symbol and its text.
        public static let spacing: CGFloat = 4
        /// A candy dot's side.
        public static let dot: CGFloat = 9
        /// The halo around the dot of the branch you're on.
        public static let halo: CGFloat = 3
        /// A count pill's height.
        public static let countHeight: CGFloat = 18
    }
}
