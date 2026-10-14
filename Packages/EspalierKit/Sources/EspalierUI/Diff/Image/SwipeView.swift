// Ported from desktop/app/src/ui/diff/image-diffs/swipe.tsx
//
// The two images overlaid from the same top-left corner, each at its own
// size, with a slider that reveals the old image from the left. It starts
// at 0, showing the new image.

import GitKit
import SwiftUI

/// The images overlaid; the slider swipes between them.
struct SwipeView: View {
    let previousShown: ShownImage
    let currentShown: ShownImage

    /// - Parameter fraction: How much of the old image shows at first.
    init(previous: ShownImage, current: ShownImage, fraction: Double = 0) {
        previousShown = previous
        currentShown = current
        _fraction = State(initialValue: fraction)
    }

    private var previous: DiffImage {
        previousShown.image
    }

    private var current: DiffImage {
        currentShown.image
    }
    /// How much of the old image shows, from the left, 0 to 1.
    @State private var fraction: Double = 0

    var body: some View {
        let previousImage = previousShown.decoded
        let currentImage = currentShown.decoded
        GeometryReader { proxy in
            let sizes = OverlaidImageSizes(
                previous: previousImage,
                current: currentImage,
                available: CGSize(width: proxy.size.width, height: proxy.size.height - 40)
            )
            let box = sizes.box
            VStack(spacing: Metrics.insetMedium) {
                CapsuleSlider("Swipe between the images", value: $fraction)
                    .frame(width: max(box.width, 160))
                ZStack(alignment: .topLeading) {
                    CheckeredImage(image: previousImage, size: sizes.previous)
                        .frame(width: box.width, height: box.height, alignment: .topLeading)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: box.width * fraction)
                        }
                    CheckeredImage(image: currentImage, size: sizes.current)
                        .frame(width: box.width, height: box.height, alignment: .topLeading)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: box.width * (1 - fraction))
                        }
                }
                .frame(width: box.width, height: box.height)
                .accessibilityElement()
                .accessibilityLabel(imageAccessibilityLabel("Deleted", image: previousImage, bytes: previous.bytes)
                    + "; " + imageAccessibilityLabel("Added", image: currentImage, bytes: current.bytes))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Metrics.insetLarge)
    }
}
