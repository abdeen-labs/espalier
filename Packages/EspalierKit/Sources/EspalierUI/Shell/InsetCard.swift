// The inset card layout (`PaneLayout.insetCard`, Frost). The window's
// chrome is the backdrop (`ChromeBackdrop`, glass in Frost): the toolbar's
// band, the sidebar or the rail, and the margins around the card, with no
// hairlines. The content is one card on it, the `background` fill in a
// rounded rectangle (radius 10) with a 1-point ring in the `line` color
// inside its edge, everything inside clipped to it: 8 from the window's
// trailing and bottom edges, none below the toolbar's band (the band ends
// where the card starts), and none after the sidebar or the rail (whose
// rows keep their own inset); as the sidebar shows and hides, the card
// follows its edge and stops 8 from the window's. The panes in it lie edge
// to edge, divided by hairlines, as in the flat layout.
//
// With Commit Info showing, the card spans the detail's column and the
// inspector's: the detail's part has the leading corners and no ring on its
// trailing edge, and Commit Info's part has the trailing corners, its
// leading ring the hairline between the two. Everything follows a change of
// look at once, keeping its views: every modifier stays, with values that
// draw nothing in another layout.

import SwiftUI

/// The inset card layout's measures.
enum InsetCard {
    /// Whether the current look sets the content in one inset card.
    static var isOn: Bool {
        Theme.current.paneLayout == .insetCard
    }

    /// The card's distance from the window's edges.
    static let margin: CGFloat = 8

    /// The card's corner radius.
    static let radius: CGFloat = 10

    /// The detail area's margins around its part of the card, its leading
    /// edge `minX` from the window's: none below the toolbar's band, none
    /// after the sidebar's edge, growing to the margin as that edge comes
    /// within it of the window's, and none before Commit Info.
    static func detailMargins(minX: CGFloat, beforeInspector: Bool) -> EdgeInsets {
        EdgeInsets(top: 0, leading: max(margin - minX, 0), bottom: margin, trailing: beforeInspector ? 0 : margin)
    }

    /// Commit Info's margins around its part of the card.
    static let inspectorMargins = EdgeInsets(top: 0, leading: 0, bottom: margin, trailing: margin)

    /// A part of the card.
    nonisolated enum Part {
        /// The whole card.
        case whole
        /// The detail's part before Commit Info: the leading corners, no
        /// ring on its trailing edge.
        case leading
        /// Commit Info's part: the trailing corners, its leading ring the
        /// hairline before it.
        case trailing
    }
}

extension PaneLayout {
    /// Whether the window's chrome is the theme's backdrop, with no
    /// hairlines between it and the panes: the floating and inset card
    /// layouts.
    var chromeIsBackdrop: Bool {
        self != .flat
    }
}

extension View {
    /// Makes the view a part of the inset card in the inset card layout;
    /// in another, the view as it is.
    func insetCard(_ part: InsetCard.Part = .whole) -> some View {
        modifier(InsetCardModifier(part: part))
    }
}

/// A part of the inset card: the `background` fill, clipped to the card's
/// shape, with the ring inside its edge. In another layout every modifier
/// stays, drawing nothing.
private struct InsetCardModifier: ViewModifier {
    let part: InsetCard.Part

    func body(content: Content) -> some View {
        let isOn = InsetCard.isOn
        let theme = Theme.current
        content
            .background(isOn ? Color(nsColor: theme.background) : .clear)
            // In another layout, the clip is a rectangle far outside the
            // view.
            .clipShape(InsetCardShape(part: part, radius: isOn ? InsetCard.radius : 0).inset(by: isOn ? 0 : -100_000))
            .overlay {
                if isOn {
                    InsetCardRing(part: part, radius: InsetCard.radius)
                        .stroke(Color(nsColor: theme.line), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A part of the card's outline: rounded at the corners the part has; a
/// rectangle when the radius is 0, however far it's inset.
nonisolated struct InsetCardShape: InsettableShape {
    let part: InsetCard.Part
    let radius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = radius > 0 ? max(radius - insetAmount, 0) : 0
        let leading = part == .trailing ? 0 : radius
        let trailing = part == .leading ? 0 : radius
        return UnevenRoundedRectangle(
            topLeadingRadius: leading,
            bottomLeadingRadius: leading,
            bottomTrailingRadius: trailing,
            topTrailingRadius: trailing,
            style: .circular
        )
        .path(in: rect.insetBy(dx: insetAmount, dy: insetAmount))
    }

    func inset(by amount: CGFloat) -> InsetCardShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// A part of the card's ring, stroked 1 point wide: its outline half a
/// point inside, open at the trailing edge of the detail's part before
/// Commit Info, where Commit Info's ring divides them.
nonisolated struct InsetCardRing: Shape {
    let part: InsetCard.Part
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let ring = rect.insetBy(dx: 0.5, dy: 0.5)
        let radius = max(radius - 0.5, 0)
        guard part == .leading else {
            return InsetCardShape(part: part, radius: radius).path(in: ring)
        }
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: ring.minY))
        path.addLine(to: CGPoint(x: ring.minX + radius, y: ring.minY))
        path.addArc(tangent1End: CGPoint(x: ring.minX, y: ring.minY), tangent2End: CGPoint(x: ring.minX, y: ring.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: ring.minX, y: ring.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: ring.minX, y: ring.maxY), tangent2End: CGPoint(x: ring.minX + radius, y: ring.maxY), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: ring.maxY))
        return path
    }
}
