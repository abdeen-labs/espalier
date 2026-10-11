// Ported from desktop/app/src/ui/diff/image-diffs/onion-skin.tsx
//
// The new image over the old one, with a slider for its opacity. The new
// image starts at 1%.

import GitKit
import SwiftUI

/// The new image over the old, faded by the slider.
struct OnionSkinView: View {
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
    /// The new image's opacity, 0 to 1.
    @State private var opacity: Double = 0.01

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
                CapsuleSlider("Opacity of the new image", value: $opacity)
                    .frame(width: max(size.width / 2, 160))
                ZStack {
                    CheckeredImage(image: previousImage, size: size)
                    CheckeredImage(image: currentImage, size: size)
                        .opacity(opacity)
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
