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

    /// "Diff: +2.5 KiB (+20%)" or "No size difference".
    private var summary: some View {
        let diffBytes = current.bytes - previous.bytes
        return HStack(spacing: Metrics.grid) {
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

    /// "+2.5 KiB (+20%)", "−1 KiB (−50%)"; without the percentage
    /// when the old image was empty.
    var sizeDifference: String {
        let diffBytes = current.bytes - previous.bytes
        let sign = diffBytes >= 0 ? "+" : "\u{2212}"
        let size = "\(sign)\(formatBytes(Double(abs(diffBytes)), 2))"
        guard let percent = percentChange(previous.bytes, current.bytes) else {
            return size
        }
        return "\(size) (\(sign)\(abs(percent))%)"
    }
}

/// The change in size as a percentage of the old size, rounded: 20 from
/// 100 to 120 bytes, -50 from 100 to 50. Nil when the old size is 0.
nonisolated func percentChange(_ previous: Int, _ current: Int) -> Int? {
    guard previous != 0 else {
        return nil
    }
    return Int((Double(current - previous) / Double(previous) * 100).rounded(.toNearestOrAwayFromZero))
}
