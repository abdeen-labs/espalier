// A bar across the top of a place that says what state the repository is in
// (56 high, taller for a third line; tinted with the modified color at 7%).
// The operation panel uses it; its tone follows the state: modified for
// conflicts and anything waiting on the user, add once they're resolved,
// neutral while work runs. A change of tone crossfades the fill and the
// lines' words over 0.22 s.

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

/// A bar across a place: a glyph, the title and up to two lines under it,
/// and trailing controls, with a hairline under it (none in the floating
/// layout, where the bar is a card).
public struct StatusBar<Glyph: View, Trailing: View>: View {
    private let tone: StatusBarTone
    private let title: String
    private let subtitle: Text?
    private let help: String?
    private let detail: String?
    private let glyph: Glyph
    private let trailing: Trailing
    @Environment(\.motion) private var motion

    /// - Parameters:
    ///   - subtitle: The line under the title, one line, truncated.
    ///   - help: The whole subtitle, as its tooltip.
    ///   - detail: A line under the subtitle (how to go on), one line,
    ///     truncated, the whole of it as its tooltip.
    public init(
        tone: StatusBarTone,
        title: String,
        subtitle: Text? = nil,
        help: String? = nil,
        detail: String? = nil,
        @ViewBuilder glyph: () -> Glyph,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.tone = tone
        self.title = title
        self.subtitle = subtitle
        self.help = help
        self.detail = detail
        self.glyph = glyph()
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.StatusBar.spacing) {
                glyph
                    .frame(width: Metrics.StatusBar.glyphWidth)
                // As the tone changes, the lines' new words crossfade in
                // with the fill; other changes (a step of the work, a file
                // resolved) show at once.
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typography.statusBarTitle)
                        .foregroundStyle(.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .motion(Motion.arrive, value: tone)
                    if let subtitle {
                        subtitle
                            .font(Typography.meta)
                            .foregroundStyle(.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .motion(Motion.arrive, value: tone)
                            .tooltip(help)
                    }
                    if let detail {
                        Text(detail)
                            .font(Typography.meta)
                            .foregroundStyle(.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .motion(Motion.arrive, value: tone)
                            .tooltip(detail)
                    }
                }
                .contentTransition(motion.animates ? .opacity : .identity)
                .padding(.vertical, Metrics.insetSmall)
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
