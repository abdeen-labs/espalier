// Ported from desktop/app/src/ui/diff/image-diffs/onion-skin.tsx
//
// The new image over the old one from the same top-left corner, each at its
// own size, with a slider for the new one's opacity. The new image starts
// at 1%.

import GitKit
import SwiftUI

/// The new image over the old, faded by the slider.
struct OnionSkinView: View {
    let previousShown: ShownImage
    let currentShown: ShownImage

    /// - Parameter opacity: The new image's opacity at first.
    init(previous: ShownImage, current: ShownImage, opacity: Double = 0.01) {
        previousShown = previous
        currentShown = current
        _opacity = State(initialValue: opacity)
    }

    private var previous: DiffImage {
        previousShown.image
    }

    private var current: DiffImage {
        currentShown.image
    }
    /// The new image's opacity, 0 to 1.
    @State private var opacity: Double = 0.01

    var body: some View {
        let previousImage = previousShown.decoded
        let currentImage = currentShown.decoded
        GeometryReader { proxy in
            let sizes = OverlaidImageSizes(
                previous: previousImage,
                current: currentImage,
                available: CGSize(width: proxy.size.width, height: proxy.size.height - 40)
            )
            VStack(spacing: Metrics.insetMedium) {
                CapsuleSlider("Opacity of the new image", value: $opacity)
                    .frame(width: max(sizes.box.width / 2, 160))
                ZStack(alignment: .topLeading) {
                    CheckeredImage(image: previousImage, size: sizes.previous)
                    CheckeredImage(image: currentImage, size: sizes.current)
                        .opacity(opacity)
                }
                .frame(width: sizes.box.width, height: sizes.box.height, alignment: .topLeading)
                .accessibilityElement()
                .accessibilityLabel(imageAccessibilityLabel("Deleted", image: previousImage, bytes: previous.bytes)
                    + "; " + imageAccessibilityLabel("Added", image: currentImage, bytes: current.bytes))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Metrics.insetLarge)
    }
}
