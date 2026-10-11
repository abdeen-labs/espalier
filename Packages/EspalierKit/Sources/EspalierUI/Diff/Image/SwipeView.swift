// Ported from desktop/app/src/ui/diff/image-diffs/swipe.tsx
//
// The two images overlaid, with a slider that reveals the old image from
// the left. It starts at 0, showing the new image.

import GitKit
import SwiftUI

/// The images overlaid; the slider swipes between them.
struct SwipeView: View {
    let previousShown: ShownImage
    let currentShown: ShownImage

    init(previous: ShownImage, current: ShownImage) {
        previousShown = previous
        currentShown = current
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
            let size = getMaxFitSize(
                previousImage?.pixelSize ?? CGSize(width: 64, height: 64),
                currentImage?.pixelSize ?? CGSize(width: 64, height: 64),
                CGSize(width: max(proxy.size.width, 1), height: max(proxy.size.height - 40, 1))
            )
            VStack(spacing: Metrics.insetMedium) {
                CapsuleSlider("Swipe between the images", value: $fraction)
                    .frame(width: max(size.width, 160))
                ZStack(alignment: .topLeading) {
                    CheckeredImage(image: previousImage, size: size)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: size.width * fraction)
                        }
                    CheckeredImage(image: currentImage, size: size)
                        .mask(alignment: .trailing) {
                            Rectangle().frame(width: size.width * (1 - fraction))
                        }
                }
                .frame(width: size.width, height: size.height)
                .accessibilityElement()
                .accessibilityLabel(imageAccessibilityLabel("Deleted", image: previousImage, bytes: previous.bytes)
                    + "; " + imageAccessibilityLabel("Added", image: currentImage, bytes: current.bytes))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Metrics.insetLarge)
    }
}
