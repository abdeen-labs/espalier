// Ported from desktop/app/src/ui/diff/image-diffs/two-up.tsx
//
// The old and new images side by side, each with its size, and the
// difference in bytes.

import GitKit
import SwiftUI

/// "Deleted" and "Added" side by side.
struct TwoUpView: View {
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
            let pane = CGSize(
                width: max((proxy.size.width - 3 * Metrics.insetLarge) / 2, 1),
                height: max(proxy.size.height - 110, 1)
            )
            let previousSize = getAspectFitSize(previousImage?.pixelSize ?? CGSize(width: 64, height: 64), pane)
            let currentSize = getAspectFitSize(currentImage?.pixelSize ?? CGSize(width: 64, height: 64), pane)
            VStack(spacing: Metrics.insetMedium) {
                HStack(alignment: .top, spacing: Metrics.insetLarge) {
                    side("Deleted", image: previous, decoded: previousImage, size: previousSize)
                    side("Added", image: current, decoded: currentImage, size: currentSize)
                }
                summary
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Metrics.insetLarge)
    }

    private func side(_ title: String, image: DiffImage, decoded: DecodedImage?, size: CGSize) -> some View {
        VStack(spacing: Metrics.insetSmall) {
            Text(title)
                .font(Typography.heading)
            CheckeredImage(image: decoded, size: size)
                .accessibilityElement()
                .accessibilityLabel(imageAccessibilityLabel(title, image: decoded, bytes: image.bytes))
                .accessibilityAddTraits(.isImage)
            Text(imageFooter(image: decoded, bytes: image.bytes))
                .font(Typography.secondary.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// "Diff: +2.5 KiB (120%)" or "No size difference" (the percentage is
    /// the new size relative to the old).
    private var summary: some View {
        let diffBytes = current.bytes - previous.bytes
        return HStack(spacing: 4) {
            Text("Diff:")
            if diffBytes != 0 {
                Text(sizeDifference)
                    .foregroundStyle(Color(nsColor: diffBytes > 0 ? DiffColors.addedMarker : DiffColors.deletedMarker))
            } else {
                Text("No size difference")
            }
        }
        .font(Typography.secondary.monospacedDigit())
    }

    /// "+2.5 KiB (120%)".
    var sizeDifference: String {
        let diffBytes = current.bytes - previous.bytes
        let sign = diffBytes >= 0 ? "+" : ""
        return "\(sign)\(formatBytes(Double(diffBytes), 2)) (\(percentDiff(previous.bytes, current.bytes)))"
    }
}

/// The new size as a percentage of the old one.
nonisolated func percentDiff(_ previous: Int, _ current: Int) -> String {
    guard previous != 0 else {
        return "∞%"
    }
    let ratio = (Double(current) / Double(previous) * 100).rounded(.toNearestOrAwayFromZero)
    return "\(Int(abs(ratio)))%"
}
