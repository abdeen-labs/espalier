// Ported from desktop/app/src/ui/diff/image-diffs/difference-blend.tsx
//
// The new image blended over the old with the difference mode, so
// unchanged pixels go black.

import GitKit
import SwiftUI

/// The images' difference.
struct DifferenceView: View {
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

    var body: some View {
        let previousImage = previousShown.decoded
        let currentImage = currentShown.decoded
        GeometryReader { proxy in
            let size = getMaxFitSize(
                previousImage?.pixelSize ?? CGSize(width: 64, height: 64),
                currentImage?.pixelSize ?? CGSize(width: 64, height: 64),
                CGSize(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1))
            )
            ZStack {
                Checkerboard()
                if let previousImage {
                    Image(nsImage: previousImage.image)
                        .resizable()
                }
                if let currentImage {
                    Image(nsImage: currentImage.image)
                        .resizable()
                        .blendMode(.difference)
                }
            }
            .compositingGroup()
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel("Difference of the images. " + imageAccessibilityLabel("Deleted", image: previousImage, bytes: previous.bytes)
                + "; " + imageAccessibilityLabel("Added", image: currentImage, bytes: current.bytes))
        }
        .padding(Metrics.insetLarge)
    }
}
