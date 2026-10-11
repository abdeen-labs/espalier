// Espalier's popover card: the content on the flat `background`, radius 22,
// with the floating ring and shadow, and no arrow. The content takes its
// ideal size, capped to the screen; the card follows it, and where the
// card is larger for a moment (while it resizes) the content keeps to the
// anchor's side. The card fades in and settles from 97% toward its anchor
// as it arrives, except under Reduce Motion, offscreen, and in snapshots.
// `PopoverController` shows it in an `AnchoredPanel`.

import SwiftUI

extension Metrics.Popover {
    /// Between a popover's card and its anchor.
    public static let gap: CGFloat = 6
    /// The transparent margin around the card where its shadow draws: the
    /// floating shadow's, as a menu's.
    public static let shadowInsets = Metrics.Menu.shadowInsets
    /// The card settles from this scale as it arrives.
    public static let settleScale: CGFloat = 0.97
}

/// What a popover's card shows, and whether it has arrived.
@MainActor @Observable
final class PopoverCardModel {
    /// The content, built in the card's own view tree.
    var content: () -> AnyView
    /// The side of its anchor the card is on.
    var edge: AnchoredPanel.Edge
    /// Whether the card has arrived; it fades and settles in as this turns
    /// true.
    var isShown: Bool
    /// The largest the content gets: the screen's visible frame, less its
    /// margins.
    var maxContentSize: CGSize
    /// The environment of the view the popover opens from.
    var environment: EnvironmentValues?
    /// Turns motion off in the card: its window isn't on screen.
    var isMotionSuppressed = false
    /// Closes the popover, for its content and the menus opened in it.
    var closeAction: ClosePopoverAction?
    /// Told the content's size as it changes.
    @ObservationIgnored var onContentSize: ((CGSize) -> Void)?

    init(
        edge: AnchoredPanel.Edge = .below,
        isShown: Bool = true,
        maxContentSize: CGSize = CGSize(width: CGFloat.infinity, height: .infinity),
        content: @escaping () -> AnyView
    ) {
        self.content = content
        self.edge = edge
        self.isShown = isShown
        self.maxContentSize = maxContentSize
    }
}

/// A popover's card, with the margin its shadow draws in.
struct PopoverCardView: View {
    let model: PopoverCardModel
    @Environment(\.motion) private var motion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.sheet, style: .continuous)
        let isShown = model.isShown || !motion.animates
        PopoverContentLayout(maxSize: model.maxContentSize) {
            model.content()
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { [model] size in
            model.onContentSize?(size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
        .clipShape(shape)
        .surface(Color(espalier: Palette.background), elevation: .floating, in: shape)
        .scaleEffect(isShown ? 1 : Metrics.Popover.settleScale, anchor: settleAnchor)
        .opacity(isShown ? 1 : 0)
        .padding(EdgeInsets(Metrics.Popover.shadowInsets))
    }

    /// Where the content sits while the card is larger than it: on the
    /// anchor's side.
    private var contentAlignment: Alignment {
        switch model.edge {
        case .above: .bottom
        case .trailing: .leading
        case .leading: .trailing
        case .below, .point: .top
        }
    }

    /// The point the card settles toward: the middle of its side facing the
    /// anchor.
    private var settleAnchor: UnitPoint {
        switch model.edge {
        case .above: .bottom
        case .trailing: .leading
        case .leading: .trailing
        case .below, .point: .top
        }
    }
}

/// The card with the environment its panel gives it: the presenting view's,
/// with the popover's own close action and its window's motion.
struct PopoverCardRoot: View {
    let model: PopoverCardModel

    var body: some View {
        let card = PopoverCardView(model: model)
            .environment(\.closeEnclosingPopover, model.closeAction)
            .environment(\.motionSuppressed, model.isMotionSuppressed || model.environment?.motionSuppressed == true)
        if let environment = model.environment {
            card.environment(\.self, environment)
        } else {
            card
        }
    }
}

/// Sizes a popover's content: its ideal size, or within `maxSize` when
/// that's smaller (a list taller than the screen scrolls).
struct PopoverContentLayout: Layout {
    let maxSize: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else {
            return .zero
        }
        let ideal = content.sizeThatFits(.unspecified)
        guard ideal.width > maxSize.width || ideal.height > maxSize.height else {
            return ideal
        }
        let capped = ProposedViewSize(width: min(ideal.width, maxSize.width), height: min(ideal.height, maxSize.height))
        let fitted = content.sizeThatFits(capped)
        return CGSize(width: min(fitted.width, maxSize.width), height: min(fitted.height, maxSize.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
