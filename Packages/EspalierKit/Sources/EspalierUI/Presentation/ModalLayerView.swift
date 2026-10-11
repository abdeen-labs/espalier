// What a modal layer draws: over a window, the scrim (clipped to the
// window's corners) and the card centered in the window; on its own, the
// card and its shadow. The card is the content on the flat `background`,
// radius 22, with the sheet's shadow. It takes the content's size, at most
// the window's less a margin on each side; content taller than that scrolls
// inside the card. A sheet that fills the window (`modalCardFillsWindow()`)
// takes all of it, as desktop's Preview Pull Request does. Arriving, the
// scrim fades in while the card fades in and settles from a slight scale;
// leaving, both fade out. VoiceOver finds the card a modal dialog named by
// its title.

import AppKit
import SwiftUI

extension Metrics.Sheet {
    /// The least space between a card and its window's edges.
    public static let windowMargin: CGFloat = 40
    /// Around a card shown on its own, for its shadow.
    static let shadowInset: CGFloat = 60
}

extension Motion {
    /// The scale a card settles from as it arrives, and shrinks to as it
    /// leaves.
    nonisolated static let cardSettleScale: CGFloat = 0.97
}

/// A layer's state, which the panel sets and the view draws.
@MainActor @Observable
final class ModalLayerState {
    /// Where the layer is in its motion.
    enum Phase: Equatable {
        /// Not drawn yet: the scrim and the card are clear.
        case hidden
        case shown
        /// Fading out; the panel closes after.
        case leaving
    }

    var phase: Phase = .hidden
    /// The covered window's corners, which clip the scrim.
    var cornerRadii = RectangleCornerRadii()
    /// Whether the card fills the window less its margins.
    var fillsWindow = false
    /// The card's title, for VoiceOver: an alert's, or a sheet's from its
    /// scaffold. The panel takes it as its own.
    var title: String? {
        didSet {
            panel?.title = title ?? ""
        }
    }
    /// The panel the layer is drawn in.
    @ObservationIgnored weak var panel: NSWindow?
    /// Whether the layer covers a window (scrim and centered card) or holds
    /// only the card.
    let coversWindow: Bool

    init(coversWindow: Bool, title: String? = nil) {
        self.coversWindow = coversWindow
        self.title = title
    }
}

/// The layer's root view.
struct ModalLayerView: View {
    let state: ModalLayerState
    let content: AnyView

    var body: some View {
        let isShown = state.phase == .shown
        if state.coversWindow {
            GeometryReader { proxy in
                ZStack {
                    ModalScrim(cornerRadii: state.cornerRadii)
                        .opacity(isShown ? 1 : 0)
                    card(fillSize: state.fillsWindow ? Self.available(in: proxy.size) : nil, margin: Metrics.Sheet.windowMargin)
                        .opacity(isShown ? 1 : 0)
                        .scaleEffect(isShown ? 1 : Motion.cardSettleScale)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } else {
            card(fillSize: nil, margin: 0)
                .padding(Metrics.Sheet.shadowInset)
                .opacity(isShown ? 1 : 0)
                .scaleEffect(isShown ? 1 : Motion.cardSettleScale)
        }
    }

    private func card(fillSize: CGSize?, margin: CGFloat) -> some View {
        ModalCard(content: content, state: state, fillSize: fillSize, margin: margin)
    }

    /// The most room a card has in a window of `size`.
    static func available(in size: CGSize) -> CGSize {
        CGSize(
            width: max(size.width - 2 * Metrics.Sheet.windowMargin, 0),
            height: max(size.height - 2 * Metrics.Sheet.windowMargin, 0)
        )
    }
}

/// The dim over the covered window, in its rounded shape.
struct ModalScrim: View {
    let cornerRadii: RectangleCornerRadii

    var body: some View {
        UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
            .fill(Color(espalier: Palette.scrim))
            .accessibilityHidden(true)
    }
}

/// The card: the content on the flat `background`, radius 22, with the
/// sheet's shadow, scrolling when it's taller than its room.
struct ModalCard: View {
    let content: AnyView
    let state: ModalLayerState
    /// The size a card that fills the window takes; nil for its own size.
    let fillSize: CGSize?
    /// Kept clear between the card and the edges of what it's in.
    let margin: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.sheet, style: .continuous)
        ModalCardLayout(fillSize: fillSize, margin: margin) {
            ScrollView(.vertical) {
                content
                    .frame(width: fillSize?.width, height: fillSize?.height)
            }
            .scrollsOnlyWhenOverflowing()
        }
        .clipShape(shape)
        .surface(Color(espalier: Palette.background), elevation: .sheet, in: shape)
        .onPreferenceChange(ModalCardFillsWindowKey.self) { fills in
            state.fillsWindow = fills
        }
        .onPreferenceChange(ModalTitleKey.self) { title in
            if let title {
                state.title = title
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.title ?? "")
        .accessibilityAddTraits(.isModal)
    }
}

/// Sizes the card: the content's own width and height, each at most the
/// room it's offered less `margin` on each side (the content then scrolls),
/// or `fillSize`.
struct ModalCardLayout: Layout {
    let fillSize: CGSize?
    let margin: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scroller = subviews.first else {
            return .zero
        }
        if let fillSize {
            return fillSize
        }
        let room = CGSize(
            width: max((proposal.width ?? .infinity) - 2 * margin, 0),
            height: max((proposal.height ?? .infinity) - 2 * margin, 0)
        )
        let ideal = scroller.sizeThatFits(.unspecified)
        let width = min(scroller.sizeThatFits(ProposedViewSize(width: min(ideal.width, room.width), height: nil)).width, room.width)
        let height = scroller.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: min(height, room.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Whether a sheet's card fills its window.
struct ModalCardFillsWindowKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// A sheet's title, which names its card for VoiceOver.
struct ModalTitleKey: PreferenceKey {
    static let defaultValue: String? = nil

    static func reduce(value: inout String?, nextValue: () -> String?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Makes the sheet this view is the content of fill its window, less a
    /// margin on each side.
    public func modalCardFillsWindow() -> some View {
        preference(key: ModalCardFillsWindowKey.self, value: true)
    }

    /// Names the card this view is the content of, for VoiceOver.
    func modalTitle(_ title: String) -> some View {
        preference(key: ModalTitleKey.self, value: title)
    }
}
