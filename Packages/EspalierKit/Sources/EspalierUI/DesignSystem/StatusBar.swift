// A bar across the top of a place that says what state the repository is in
// (56 high, tinted with the modified color at 7%). The operation panel uses
// it; its tone follows the state: modified for conflicts and anything
// waiting on the user, add once they're resolved, neutral while work runs.

import AppKit
import SwiftUI

/// A status bar's tint.
nonisolated public enum StatusBarTone: Sendable, Equatable {
    /// Waiting on the user (conflicts): the modified color.
    case attention
    /// Ready to go on: the add color.
    case ready
    /// Work running: the `hunk` gray.
    case neutral

    /// The bar's fill.
    public var fill: NSColor {
        switch self {
        case .attention: Palette.tint(Palette.modified, light: Self.tintAlpha, dark: Self.tintAlpha)
        case .ready: Palette.tint(Palette.add, light: Self.tintAlpha, dark: Self.tintAlpha)
        case .neutral: Palette.hunk
        }
    }

    /// The tint's alpha.
    static let tintAlpha: CGFloat = 0.07
}

/// A bar across a place: a glyph, the title and a line under it, and
/// trailing controls, with a hairline under it (none in the floating
/// layout, where the bar is a card).
public struct StatusBar<Glyph: View, Trailing: View>: View {
    private let tone: StatusBarTone
    private let title: String
    private let subtitle: Text?
    private let help: String?
    private let glyph: Glyph
    private let trailing: Trailing

    /// - Parameters:
    ///   - subtitle: The line under the title, one line, truncated.
    ///   - help: The whole subtitle, as its tooltip.
    public init(
        tone: StatusBarTone,
        title: String,
        subtitle: Text? = nil,
        help: String? = nil,
        @ViewBuilder glyph: () -> Glyph,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.tone = tone
        self.title = title
        self.subtitle = subtitle
        self.help = help
        self.glyph = glyph()
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.StatusBar.spacing) {
                glyph
                    .frame(width: Metrics.StatusBar.glyphWidth)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typography.statusBarTitle)
                        .foregroundStyle(.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle {
                        subtitle
                            .font(Typography.meta)
                            .foregroundStyle(.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tooltip(help)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: Metrics.insetSmall)
                HStack(spacing: Metrics.insetSmall) {
                    trailing
                }
                .fixedSize()
            }
            .padding(.horizontal, Metrics.insetLarge)
            .frame(minHeight: Metrics.StatusBar.height)
            .background(Color(espalier: tone.fill).motion(Motion.arrive, value: tone))
            // A card of its own in the floating layout, which needs none.
            Hairline()
                .opacity(PaneCards.floats ? 0 : 1)
        }
        .accessibilityElement(children: .contain)
    }
}

extension Typography {
    /// A status bar's title (13, semibold).
    public static var statusBarTitle: Font { sans(.body, weight: .semibold) }
}

extension Metrics {
    /// The bar across the top of a place.
    public enum StatusBar {
        /// The bar's height.
        public static let height: CGFloat = 56
        public static let spacing: CGFloat = 12
        /// The glyph's column.
        public static let glyphWidth: CGFloat = 18
    }
}
