// A vertical scroll view that scrolls only while its content is taller than
// it shows: content that fits holds still under a scroll instead of moving
// or bouncing. Half a point of difference counts as fitting, so a height
// rounded to whole points doesn't make it scroll.

import SwiftUI

extension View {
    /// Lets the vertical scroll view this modifies scroll only while its
    /// content is taller than it shows.
    func scrollsOnlyWhenOverflowing() -> some View {
        modifier(ScrollsOnlyWhenOverflowing())
    }
}

private struct ScrollsOnlyWhenOverflowing: ViewModifier {
    @State private var overflows = false

    func body(content: Content) -> some View {
        content
            .scrollDisabled(!overflows)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height > geometry.containerSize.height + 0.5
            } action: { _, overflows in
                self.overflows = overflows
            }
    }
}
