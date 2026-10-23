// What a modal layer draws: over a window, the scrim (clipped to the
// window's corners) and the card centered in the window; on its own, the
// card and its shadow. The card is the content on the flat `background`,
// radius 22, with the sheet's shadow. It takes the content's size, at most
// the window's less a margin on each side; content taller than that scrolls
// inside the card. A sheet that fills the window (`modalCardFillsWindow()`)
// takes all of it, as desktop's Preview Pull Request does. Arriving, the
// scrim fades in while the card fades in and settles from a slight scale;
// leaving, both fade out. As its content grows or shrinks, the card eases to
// its new height. VoiceOver finds the card a modal dialog named by its
// title.

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
                    let room = Self.available(in: proxy.size)
                    card(fillSize: state.fillsWindow ? room : nil, margin: Metrics.Sheet.windowMargin, room: room)
                        .opacity(isShown ? 1 : 0)
                        .scaleEffect(isShown ? 1 : Motion.cardSettleScale)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } else {
            card(fillSize: nil, margin: 0, room: nil)
                .padding(Metrics.Sheet.shadowInset)
                .opacity(isShown ? 1 : 0)
                .scaleEffect(isShown ? 1 : Motion.cardSettleScale)
        }
    }

    private func card(fillSize: CGSize?, margin: CGFloat, room: CGSize?) -> some View {
        ModalCard(content: content, state: state, fillSize: fillSize, margin: margin, room: room)
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
/// sheet's shadow, scrolling when it's taller than its room. As the
/// content's height changes while the card shows, the card eases to it,
/// over 0.22 s as it grows and 0.15 s as it shrinks; as the window's size
/// changes, it follows at once.
struct ModalCard: View {
    let content: AnyView
    let state: ModalLayerState
    /// The size a card that fills the window takes; nil for its own size.
    let fillSize: CGSize?
    /// Kept clear between the card and the edges of what it's in.
    let margin: CGFloat
    /// The most room the card has; nil for as much as it needs.
    let room: CGSize?
    /// The content's height the card shows (at most the room's); nil
    /// until it's measured.
    @State private var shownHeight: CGFloat?
    /// The room when the card last took the content's height.
    @State private var shownRoom: CGSize?
    @Environment(\.motion) private var motion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.sheet, style: .continuous)
        ModalCardLayout(fillSize: fillSize, margin: margin, shownHeight: fillSize == nil ? shownHeight : nil) {
            OverflowScrollView {
                content
                    .frame(width: fillSize?.width, height: fillSize?.height)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                follow(height)
            }
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

    /// Takes the content's new height, as the layout placed it: eased while
    /// the card shows on its own size, over 0.22 s as it grows and 0.15 s
    /// as it shrinks; otherwise at once (the first time, arriving, leaving,
    /// filling the window, or the window's size changing).
    private func follow(_ height: CGFloat) {
        // The window's size changes the height only where the room cuts
        // the content short, before or after.
        let followsWindow = room != shownRoom
            && (height >= (room?.height ?? .infinity) || (shownHeight ?? 0) >= (shownRoom?.height ?? .infinity))
        shownRoom = room
        guard let current = shownHeight, !followsWindow, fillSize == nil, state.phase == .shown else {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                shownHeight = height
            }
            return
        }
        guard height != current else {
            return
        }
        withMotion(motion, height > current ? Motion.arrive : Motion.leave) {
            shownHeight = height
        }
    }
}

/// Sizes the card: the content's own width and height, each at most the
/// room it's offered less `margin` on each side (the content then scrolls),
/// or `fillSize`. The content takes its new height at once, at the card's
/// top; the card's height follows `shownHeight`, which eases, revealing or
/// covering the content's end as it goes.
struct ModalCardLayout: Layout {
    let fillSize: CGSize?
    let margin: CGFloat
    /// The content's height the card shows, at most the room's; nil for
    /// the content's own.
    var shownHeight: CGFloat?

    var animatableData: CGFloat {
        get { shownHeight ?? 0 }
        set {
            if shownHeight != nil {
                shownHeight = newValue
            }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scroller = subviews.first else {
            return .zero
        }
        if let fillSize {
            return fillSize
        }
        let size = contentSize(scroller, proposal: proposal)
        guard let shownHeight else {
            return size
        }
        return CGSize(width: size.width, height: min(shownHeight, room(proposal).height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let scroller = subviews.first else {
            return
        }
        let height = fillSize == nil ? contentSize(scroller, proposal: proposal).height : bounds.height
        scroller.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: height))
    }

    /// The room `proposal` offers, less `margin` on each side.
    private func room(_ proposal: ProposedViewSize) -> CGSize {
        CGSize(
            width: max((proposal.width ?? .infinity) - 2 * margin, 0),
            height: max((proposal.height ?? .infinity) - 2 * margin, 0)
        )
    }

    /// The content's own width and height, each at most the room.
    private func contentSize(_ scroller: LayoutSubview, proposal: ProposedViewSize) -> CGSize {
        let room = room(proposal)
        let ideal = scroller.sizeThatFits(.unspecified)
        let width = min(scroller.sizeThatFits(ProposedViewSize(width: min(ideal.width, room.width), height: nil)).width, room.width)
        let height = scroller.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: min(height, room.height))
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
