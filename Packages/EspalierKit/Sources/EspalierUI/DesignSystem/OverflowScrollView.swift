// A scroll view that scrolls only while its content is longer than it shows,
// along its axis: content that fits holds still under a scroll instead of
// moving or bouncing. Half a point of difference counts as fitting, so a
// length rounded to whole points doesn't make it scroll.
//
// It never moves past its content's ends or across its axis
// (`unbouncedScrollContent(axis:)`): SwiftUI's scroll view rubber-bands
// whatever its bounce behavior, and AppKit's elasticity set once doesn't
// hold. A horizontal one can fade its content out at an end with more beyond
// it, in a look with a scroll edge fade (`Theme.scrollEdgeFade`), each band
// as deep as the content past its end, up to the theme's.

import SwiftUI

/// A scroll view that scrolls only while its content is longer than it
/// shows, and never past its ends or across its axis.
struct OverflowScrollView<Content: View>: View {
    private let axis: Axis
    private let fadesEdges: Bool
    private let content: Content
    @State private var overflows = false
    /// How far the content reaches past the leading and trailing ends of a
    /// horizontal one.
    @State private var beyond = HorizontalOverflow()

    /// - Parameters:
    ///   - axis: The axis it scrolls along.
    ///   - fadesEdges: Whether a horizontal one's content fades out at an
    ///     end with more beyond it.
    init(_ axis: Axis = .vertical, fadesEdges: Bool = false, @ViewBuilder content: () -> Content) {
        self.axis = axis
        self.fadesEdges = fadesEdges
        self.content = content()
    }

    var body: some View {
        let scrollView = ScrollView(axis == .vertical ? .vertical : .horizontal) {
            content
                .unbouncedScrollContent(axis: axis)
        }
        .scrollIndicators(axis == .vertical ? .automatic : .never)
        .scrollDisabled(!overflows)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { [axis] geometry in
            axis == .vertical
                ? geometry.contentSize.height > geometry.containerSize.height + 0.5
                : geometry.contentSize.width > geometry.containerSize.width + 0.5
        } action: { _, overflows in
            self.overflows = overflows
        }
        if axis == .horizontal, fadesEdges {
            scrollView
                .onScrollGeometryChange(for: HorizontalOverflow.self) { geometry in
                    HorizontalOverflow(
                        leading: geometry.contentOffset.x + geometry.contentInsets.leading,
                        trailing: geometry.contentSize.width - geometry.contentOffset.x - geometry.containerSize.width
                    )
                } action: { _, beyond in
                    self.beyond = beyond
                }
                .mask {
                    EdgeFadeMask(leading: band(beyond.leading), trailing: band(beyond.trailing))
                }
        } else {
            scrollView
        }
    }

    /// An end's fade band: as deep as the content past it, up to the
    /// theme's; none for half a point or less.
    private func band(_ beyond: CGFloat) -> CGFloat {
        beyond > 0.5 ? min(beyond, Theme.current.scrollEdgeFade) : 0
    }
}

/// How far a horizontal scroll view's content reaches past its ends.
private struct HorizontalOverflow: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

/// Opaque but for a band at each end, clear at the edge.
private struct EdgeFadeMask: View {
    let leading: CGFloat
    let trailing: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: leading)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: trailing)
        }
    }
}
