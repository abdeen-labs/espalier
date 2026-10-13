// The floating cards layout (`PaneLayout.floatingCards`, Islands). The
// window is the theme's backdrop: the toolbar and the sidebar sit on it with
// no hairlines, and each pane is a card floating on it, the `background`
// fill in a rounded rectangle (the card radius) with the raised ring and
// soft shadow, everything inside clipped to it. Cards are 8 apart, with no
// margin above them (the toolbar's band ends where they start), 2 after the
// sidebar, and 10 at the window's edges.
//
// A card is drawn `inset` inside its frame, the room its ring and shadow
// draw in, so frames are laid out with that much less space around them
// (`frameMargins`, `frameGap`). A place's two panes are the cards of its
// split (`SplitView`, AppKit): the split's divider is the gap between them,
// still dragged as a divider (the whole gap), and each pane is hosted in a
// `PaneCardView` that clips it. A place with one pane, the inspector, and
// the operation panel are SwiftUI cards (`paneCard(margins:)`). Splits
// inside a pane (a commit's files beside its diff) stay flat. Everything
// follows a change of look at once, keeping its views: SwiftUI bodies read
// the layout, and the splits and cards are told (`LookChangeObserving`).

import AppKit
import SwiftUI

/// The floating cards layout's measures.
enum PaneCards {
    /// Whether the current look floats the panes as cards.
    static var floats: Bool {
        Theme.current.paneLayout == .floatingCards
    }

    /// The space between two cards.
    static let gap: CGFloat = 8

    /// The room a card keeps inside its frame, on every side, for its ring
    /// and shadow.
    static let inset: CGFloat = 2

    /// The space between two cards' frames.
    static let frameGap = gap - 2 * inset

    /// The margin around cards' frames at the window's edges: the cards are
    /// 10 from them.
    static let windowEdgeMargin = 10 - inset

    /// The detail area's margins around its cards' frames: the cards are
    /// none below the toolbar, 2 after the sidebar, and 10 from the
    /// window's trailing and bottom edges.
    static let frameMargins = EdgeInsets(top: -inset, leading: 2 - inset, bottom: windowEdgeMargin, trailing: windowEdgeMargin)

    /// A card's corner radius.
    static var radius: CGFloat {
        Metrics.Radius.card
    }

    /// The soft shadow: the theme's raised shadow, 1 point down, blurred 3
    /// (as CSS blurs; SwiftUI's radius is half).
    static let shadowBlur: CGFloat = 3
    static let shadowOffset: CGFloat = 1
}

// MARK: - SwiftUI

extension EnvironmentValues {
    /// Whether the view is in a pane's card in the floating layout (or in a
    /// pane that is one when the layout floats).
    @Entry var isInPaneCard = false
}

extension PaneCards {
    /// Whether a quiet capsule in a card draws flat on the `field` fill:
    /// the theme's choice, while the layout floats.
    static func drawsQuietFlat(isInPaneCard: Bool) -> Bool {
        isInPaneCard && floats && Theme.current.controls.flatInCards
    }
}

/// A pane as a card on the backdrop, in the floating layout; flat, the pane
/// as it is. The pane keeps its identity across a change of layout: every
/// modifier stays, with values that draw nothing while flat.
struct PaneCardModifier: ViewModifier {
    /// The space around the card's frame.
    let margins: EdgeInsets

    func body(content: Content) -> some View {
        let floats = PaneCards.floats
        let theme = Theme.current
        let shape = RoundedRectangle(cornerRadius: PaneCards.radius, style: .circular)
        content
            .environment(\.isInPaneCard, true)
            .background(floats ? Color(nsColor: theme.background) : .clear)
            // Flat, the clip is far outside the pane.
            .clipShape(shape.inset(by: floats ? 0 : -100_000))
            .background {
                if floats {
                    shape
                        .fill(Color(nsColor: theme.background))
                        .shadow(color: Color(nsColor: theme.raisedShadow), radius: PaneCards.shadowBlur / 2, y: PaneCards.shadowOffset)
                }
            }
            .overlay {
                if floats {
                    shape
                        .inset(by: -0.5)
                        .stroke(Color(nsColor: theme.raisedRing), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .padding(floats ? PaneCards.inset : 0)
            .padding(floats ? margins : EdgeInsets())
    }
}

extension View {
    /// Floats the view as a card on the backdrop in the floating layout,
    /// its frame `margins` from what's around it.
    func paneCard(margins: EdgeInsets = EdgeInsets()) -> some View {
        modifier(PaneCardModifier(margins: margins))
    }

    /// The detail area's margins around its cards' frames in the floating
    /// layout; `leading` and `trailing` replace the leading and trailing
    /// ones.
    func paneMargins(
        leading: CGFloat = PaneCards.frameMargins.leading,
        trailing: CGFloat = PaneCards.frameMargins.trailing
    ) -> some View {
        modifier(PaneMarginsModifier(leading: leading, trailing: trailing))
    }
}

/// The detail area's margins in the floating layout.
private struct PaneMarginsModifier: ViewModifier {
    let leading: CGFloat
    let trailing: CGFloat

    func body(content: Content) -> some View {
        var margins = PaneCards.frameMargins
        margins.leading = leading
        margins.trailing = trailing
        return content.padding(PaneCards.floats ? margins : EdgeInsets())
    }
}

// MARK: - AppKit

/// A split pane's host in `SplitView`: flat, a plain container; floating,
/// a card that clips the pane to its rounded shape on the `background`
/// fill, with the raised ring and soft shadow around it.
final class PaneCardView: NSView, LookChangeObserving {
    /// The pane.
    let content: NSView
    /// Clips the pane and fills the card.
    private let clip = NSView()
    /// Draws the soft shadow and the ring, around the card.
    private let shade = PaneCardShade()

    /// Whether the pane is a card.
    var floats = false {
        didSet {
            if floats != oldValue {
                applyStyle()
            }
        }
    }

    init(content: NSView) {
        self.content = content
        super.init(frame: content.frame)
        wantsLayer = true
        addSubview(shade)
        clip.wantsLayer = true
        addSubview(clip)
        content.autoresizingMask = [.width, .height]
        clip.addSubview(content)
        placeSubviews()
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        placeSubviews()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    func lookDidChange() {
        applyStyle()
    }

    /// The shade fills the view; the card, and the pane in it, are inset
    /// by the room for the ring and shadow while floating.
    private func placeSubviews() {
        shade.frame = bounds
        let inset = floats ? PaneCards.inset : 0
        clip.frame = CGRect(
            x: inset,
            y: inset,
            width: max(bounds.width - 2 * inset, 0),
            height: max(bounds.height - 2 * inset, 0)
        )
        content.frame = clip.bounds
    }

    /// The card's place, fill, and clip in the current look and appearance;
    /// none while flat.
    private func applyStyle() {
        shade.isHidden = !floats
        shade.needsDisplay = true
        placeSubviews()
        guard let clipLayer = clip.layer else {
            return
        }
        guard floats else {
            clipLayer.cornerRadius = 0
            clipLayer.masksToBounds = false
            clipLayer.backgroundColor = nil
            return
        }
        var background: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background = Theme.current.background.cgColor
        }
        clipLayer.cornerRadius = PaneCards.radius
        clipLayer.cornerCurve = .circular
        clipLayer.masksToBounds = true
        clipLayer.backgroundColor = background
    }
}

/// A card's soft shadow and its ring 1 point outside it, drawn around the
/// card, `PaneCards.inset` inside its own bounds.
private final class PaneCardShade: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let theme = Theme.current
        let radius = PaneCards.radius
        let card = bounds.insetBy(dx: PaneCards.inset, dy: PaneCards.inset)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = theme.raisedShadow
        shadow.shadowBlurRadius = PaneCards.shadowBlur
        shadow.shadowOffset = NSSize(width: 0, height: isFlipped ? PaneCards.shadowOffset : -PaneCards.shadowOffset)
        shadow.set()
        theme.background.setFill()
        NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        theme.raisedRing.setStroke()
        let ring = NSBezierPath(roundedRect: card.insetBy(dx: -0.5, dy: -0.5), xRadius: radius + 0.5, yRadius: radius + 0.5)
        ring.lineWidth = 1
        ring.stroke()
    }
}

/// `SplitView`'s split. Holding a place's panes in the floating layout, its
/// divider is the gap between the cards and draws nothing.
final class PaneSplitView: NSSplitView, LookChangeObserving {
    /// Whether the split holds a place's panes, which float as cards in the
    /// floating layout (a split inside a pane stays flat).
    var holdsPanes = false

    /// Whether the panes float as cards now.
    private(set) var floats = false

    override var dividerThickness: CGFloat {
        floats ? PaneCards.frameGap : super.dividerThickness
    }

    /// Floating, the divider draws nothing: the gap between the cards is
    /// the divider.
    override var dividerColor: NSColor {
        floats ? .clear : super.dividerColor
    }

    override func layout() {
        super.layout()
        hideDividers()
    }

    /// The divider views it hid, shown again once flat.
    private var hiddenDividers: [NSView] = []

    /// Floating, the divider's views (AppKit's own) are hidden: the gap
    /// between the cards is the divider. Flat, the ones it hid show again.
    private func hideDividers() {
        guard floats else {
            for divider in hiddenDividers {
                divider.isHidden = false
            }
            hiddenDividers = []
            return
        }
        for divider in subviews where !divider.isHidden && !arrangedSubviews.contains(divider) && NSStringFromClass(type(of: divider)) == "NSSplitDividerView" {
            divider.isHidden = true
            hiddenDividers.append(divider)
        }
    }

    func lookDidChange() {
        updateLayout()
    }

    /// Floats the panes as cards, or lays them flat, as the current look
    /// does. The leading pane keeps its width.
    func updateLayout() {
        let floats = holdsPanes && PaneCards.floats
        for case let card as PaneCardView in arrangedSubviews {
            card.floats = floats
        }
        guard floats != self.floats else {
            return
        }
        // The leading pane's content keeps its width: its card's frame
        // takes the room for the ring and shadow, or gives it back.
        let position = arrangedSubviews.first.map { $0.frame.maxX + (floats ? 2 : -2) * PaneCards.inset }
        self.floats = floats
        if let position, arrangedSubviews.count == 2, bounds.width > 0 {
            setPosition(position, ofDividerAt: 0)
        } else {
            adjustSubviews()
        }
        hideDividers()
        needsDisplay = true
    }
}

/// Hides the window's split view dividers (the sidebar's and the
/// inspector's) in the floating layout, where the backdrop's gaps divide
/// the columns; flat, they show as AppKit draws them. It sits in the
/// background of the window's `NavigationSplitView` and looks after the
/// splits in the window's content.
struct WindowDividerStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> StylerView {
        StylerView()
    }

    func updateNSView(_ view: StylerView, context: Context) {
        view.apply()
    }

    final class StylerView: NSView, LookChangeObserving {
        /// The dividers it hid, shown again once the layout is flat.
        private let hiddenDividers = NSHashTable<NSView>.weakObjects()
        private var observer: (any NSObjectProtocol)?

        isolated deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard window != nil else {
                return
            }
            // A split makes its dividers as it lays out, and may make them
            // again (the sidebar collapsed, the inspector shown).
            observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: nil) { [weak self] notification in
                // Split views post on the main thread, synchronously.
                nonisolated(unsafe) let notification = notification
                MainActor.assumeIsolated {
                    guard let self, let splitView = notification.object as? NSSplitView, splitView.window === self.window else {
                        return
                    }
                    self.style(splitView)
                }
            }
            apply()
        }

        func lookDidChange() {
            apply()
        }

        /// Hides every divider of the window's own splits (`SplitView`'s
        /// draw their own) while floating; shows the ones it hid once flat.
        func apply() {
            guard PaneCards.floats else {
                for divider in hiddenDividers.allObjects {
                    divider.alphaValue = 1
                }
                hiddenDividers.removeAllObjects()
                return
            }
            guard let content = window?.contentView else {
                return
            }
            Self.visit(content) { splitView in
                style(splitView)
            }
        }

        /// A divider, and the edge AppKit draws beside the sidebar.
        private static let dividerClasses: Set<String> = ["NSSplitDividerView", "_NSSplitViewShadowView"]

        /// Hides `splitView`'s dividers while floating.
        private func style(_ splitView: NSSplitView) {
            guard PaneCards.floats, !(splitView is PaneSplitView) else {
                return
            }
            for divider in splitView.subviews where Self.dividerClasses.contains(NSStringFromClass(type(of: divider))) && divider.alphaValue != 0 {
                divider.alphaValue = 0
                hiddenDividers.add(divider)
            }
        }

        private static func visit(_ view: NSView, _ body: (NSSplitView) -> Void) {
            if let splitView = view as? NSSplitView {
                body(splitView)
            }
            for subview in view.subviews {
                visit(subview, body)
            }
        }
    }
}
