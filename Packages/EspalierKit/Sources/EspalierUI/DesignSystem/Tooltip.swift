// Espalier's tooltips. `tooltip(_:)` gives a SwiftUI view one, in place of
// `help(_:)`: the text shows in a small card once the pointer rests on the
// view, and VoiceOver hears it as the view's hint, as it heard `help(_:)`'s.
// AppKit views have `setTooltip(_:)` and tooltip areas
// (`TooltipAreas.swift`); `TooltipCenter` decides when a card shows.
//
// The card: the text in secondary type and color on the `quiet` fill, with
// the floating ring and a smaller shadow than a menu's, radius 9, padded 6
// by 8, wrapping at 280 points.

import AppKit
import SwiftUI

extension View {
    /// Espalier's tooltip for the view: `text` in a card below the pointer
    /// once it rests on the view, and the view's VoiceOver hint, as
    /// `help(_:)` gave. Nil or empty shows none.
    public func tooltip(_ text: String?) -> some View {
        modifier(TooltipModifier(text: text.flatMap { $0.isEmpty ? nil : $0 }))
    }
}

private struct TooltipModifier: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        content
            .background {
                TooltipRegion(text: text)
                    .accessibilityHidden(true)
            }
            .accessibilityHint(Text(verbatim: text ?? ""))
    }
}

/// An AppKit view behind a SwiftUI view with a tooltip: its tracker follows
/// the pointer over it. It draws nothing and takes no clicks.
final class TooltipRegionView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}

private struct TooltipRegion: NSViewRepresentable {
    let text: String?

    func makeNSView(context: Context) -> TooltipRegionView {
        let view = TooltipRegionView()
        view.makeTooltipTracker().text = text
        return view
    }

    func updateNSView(_ view: TooltipRegionView, context: Context) {
        view.makeTooltipTracker().text = text
    }
}

/// A tooltip's card, with the transparent margin its shadow draws in.
struct TooltipCard: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: Metrics.Tooltip.cornerRadius, style: .continuous)
        TooltipTextLayout(maximumWidth: Metrics.Tooltip.maximumWidth - 2 * Metrics.Tooltip.horizontalPadding) {
            Text(verbatim: text)
                .font(Typography.secondary)
                .foregroundStyle(.text2)
        }
        .padding(.horizontal, Metrics.Tooltip.horizontalPadding)
        .padding(.vertical, Metrics.Tooltip.verticalPadding)
        .background {
            shape
                .fill(.quiet)
                .shadow(
                    color: Color(nsColor: Elevation.floating.shadowColor ?? .clear),
                    radius: Metrics.Tooltip.shadowBlur(dark: dark) / 2,
                    y: Metrics.Tooltip.shadowOffset(dark: dark)
                )
        }
        .overlay {
            if let ring = Elevation.floating.ring {
                shape
                    .inset(by: -0.5)
                    .stroke(Color(nsColor: ring), lineWidth: 1)
            }
        }
        .padding(EdgeInsets(Metrics.Tooltip.shadowInsets))
        .accessibilityHidden(true)
    }
}

/// Text that keeps to one line up to `maximumWidth` and wraps past it,
/// reporting its wrapped height even when asked for its ideal size (the
/// card's size is its ideal).
private struct TooltipTextLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else {
            return .zero
        }
        let ideal = text.sizeThatFits(.unspecified)
        let width = min(proposal.width ?? ideal.width, ideal.width, maximumWidth)
        return text.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension Metrics {
    /// Tooltips: the card and where it shows.
    public enum Tooltip {
        /// Space around the text inside the card.
        public static let horizontalPadding: CGFloat = 8
        public static let verticalPadding: CGFloat = 6
        /// The widest a card gets; its text wraps to stay inside.
        public static let maximumWidth: CGFloat = 280
        /// The card's corner radius: a row's.
        public static let cornerRadius: CGFloat = Radius.row
        /// Between the cursor, or the area the card is for, and the card.
        public static let gap: CGFloat = 4
        /// The cursor reaches at most this far below the pointer's hotspot.
        public static let maximumCursorDepth: CGFloat = 32
        /// The shadow's blur (CSS's blur radius) and offset downward,
        /// smaller than a menu's: the floating shadow's color, closer.
        public static func shadowBlur(dark: Bool) -> CGFloat {
            dark ? 14 : 12
        }

        public static func shadowOffset(dark: Bool) -> CGFloat {
            dark ? 5 : 4
        }

        /// The transparent margin around the card where its shadow draws:
        /// the blur, more below, where it falls.
        public static let shadowInsets = NSEdgeInsets(top: 10, left: 14, bottom: 20, right: 14)
    }
}

extension Timing {
    /// The pointer rests this long on a view before its tooltip shows.
    public static let tooltipDelay: Duration = .milliseconds(800)
    /// Once a tooltip has shown, the next shows after the pointer rests
    /// this long...
    public static let tooltipFollowOnDelay: Duration = .milliseconds(100)
    /// ...until none has shown for this long.
    public static let tooltipFollowOnWindow: Duration = .seconds(1)
}
