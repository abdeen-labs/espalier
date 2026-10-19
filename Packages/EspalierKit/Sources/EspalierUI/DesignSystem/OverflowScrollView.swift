// A vertical scroll view that scrolls only while its content is taller than
// it shows: content that fits holds still under a scroll instead of moving
// or bouncing. Half a point of difference counts as fitting, so a height
// rounded to whole points doesn't make it scroll.
//
// It never moves past its content's ends or sideways
// (`unbouncedScrollContent()`): SwiftUI's scroll view rubber-bands whatever
// its bounce behavior, and AppKit's elasticity set once doesn't hold.

import SwiftUI

/// A vertical scroll view that scrolls only while its content is taller
/// than it shows, and never past its ends or sideways.
struct OverflowScrollView<Content: View>: View {
    private let content: Content
    @State private var overflows = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .unbouncedScrollContent()
        }
        .scrollDisabled(!overflows)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height > geometry.containerSize.height + 0.5
        } action: { _, overflows in
            self.overflows = overflows
        }
    }
}
