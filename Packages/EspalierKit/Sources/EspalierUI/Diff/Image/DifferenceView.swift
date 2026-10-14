// Ported from desktop/app/src/ui/diff/image-diffs/difference-blend.tsx
//
// The new image blended over the old with the difference mode, from the same
// top-left corner, each at its own size, so unchanged pixels go black. The
// checkerboard is under the old image.

import GitKit
import SwiftUI

/// The images' difference.
struct DifferenceView: View {
    let previousShown: ShownImage
    let currentShown: ShownImage
    @Environment(\.numberFormat) private var numberFormat

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
            let sizes = OverlaidImageSizes(previous: previousImage, current: currentImage, available: proxy.size)
            ZStack(alignment: .topLeading) {
                Checkerboard()
                    .frame(width: sizes.previous.width, height: sizes.previous.height)
                if let previousImage {
                    Image(nsImage: previousImage.image)
                        .resizable()
                        .frame(width: sizes.previous.width, height: sizes.previous.height)
                }
                if let currentImage {
                    Image(nsImage: currentImage.image)
                        .resizable()
                        .frame(width: sizes.current.width, height: sizes.current.height)
                        .blendMode(.difference)
                }
            }
            .frame(width: sizes.box.width, height: sizes.box.height, alignment: .topLeading)
            .compositingGroup()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel("Difference of the images. " + imageAccessibilityLabel("Deleted", image: previousImage, bytes: previous.bytes, numberFormat: numberFormat)
                + "; " + imageAccessibilityLabel("Added", image: currentImage, bytes: current.bytes, numberFormat: numberFormat))
        }
        .padding(Metrics.insetLarge)
    }
}
