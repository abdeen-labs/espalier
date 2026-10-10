// Ported in part from desktop/app/src/ui/diff/image-diffs/
//
// Image diffs. A modified image shows in the mode chosen in the header
// (2-Up, Swipe, Onion Skin, Difference; the `image-diff-type` preference),
// an added or deleted one in a single pane. Images sit on a checkerboard so
// transparency shows.

import AppKit
import GitKit
import ImageIO
import SwiftUI

/// An image of a diff, decoded once (not on every redraw, as a slider
/// moves).
struct ShownImage {
    let image: DiffImage
    let decoded: DecodedImage?

    init(_ image: DiffImage) {
        self.image = image
        decoded = DecodedImage.decode(image)
    }
}

/// An image diff's images, decoded.
struct ImageDiffContent {
    let previous: ShownImage?
    let current: ShownImage?

    init(_ diff: ImageDiff) {
        previous = diff.previous.map(ShownImage.init)
        current = diff.current.map(ShownImage.init)
    }
}

/// An image diff: one of the four modes, or one pane.
struct ImageDiffView: View {
    let content: ImageDiffContent
    let status: FileStatusKind
    let mode: ImageDiffType

    init(content: ImageDiffContent, status: FileStatusKind, mode: ImageDiffType) {
        self.content = content
        self.status = status
        self.mode = mode
    }

    init(diff: ImageDiff, status: FileStatusKind, mode: ImageDiffType) {
        self.init(content: ImageDiffContent(diff), status: status, mode: mode)
    }

    var body: some View {
        Group {
            if let previous = content.previous, let current = content.current {
                switch mode {
                case .twoUp:
                    TwoUpView(previous: previous, current: current)
                case .swipe:
                    SwipeView(previous: previous, current: current)
                case .onionSkin:
                    OnionSkinView(previous: previous, current: current)
                case .difference:
                    DifferenceView(previous: previous, current: current)
                }
            } else if let current = content.current, status == .new || status == .untracked {
                SingleImagePane(title: "Added", image: current)
            } else if let previous = content.previous, status == .deleted {
                SingleImagePane(title: "Deleted", image: previous)
            } else if let image = content.current ?? content.previous {
                // Other statuses show their image in one pane too: it says
                // more than a blank diff.
                SingleImagePane(title: content.current != nil ? "Added" : "Deleted", image: image)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Palette.background))
    }
}

/// The modes, in the order the header shows them (their titles are the
/// View menu's).
nonisolated extension ImageDiffType {
    static let allModes: [ImageDiffType] = [.twoUp, .swipe, .onionSkin, .difference]
}

// MARK: - Decoding

/// A decoded image and its size in pixels.
struct DecodedImage {
    let image: NSImage
    let pixelSize: CGSize

    /// Decodes image data. Nil when the data isn't an image macOS can read.
    static func decode(_ diffImage: DiffImage) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(diffImage.rawContents as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        return DecodedImage(image: NSImage(cgImage: cgImage, size: size), pixelSize: size)
    }
}

// MARK: - Sizing

/// Get the size which fits in the container without scaling and maintaining
/// aspect ratio.
nonisolated func getAspectFitSize(_ imageSize: CGSize, _ containerSize: CGSize) -> CGSize {
    let heightRatio = containerSize.height < imageSize.height ? imageSize.height / containerSize.height : 1
    let widthRatio = containerSize.width < imageSize.width ? imageSize.width / containerSize.width : 1

    var ratio = max(1, widthRatio)
    if widthRatio < heightRatio {
        ratio = max(1, heightRatio)
    }

    return CGSize(width: imageSize.width / ratio, height: imageSize.height / ratio)
}

/// Get the size which will fit the bigger of the two images while maintaining
/// aspect ratio.
nonisolated func getMaxFitSize(_ previousImageSize: CGSize, _ currentImageSize: CGSize, _ containerSize: CGSize) -> CGSize {
    let previousSize = getAspectFitSize(previousImageSize, containerSize)
    let currentSize = getAspectFitSize(currentImageSize, containerSize)
    return CGSize(width: max(previousSize.width, currentSize.width), height: max(previousSize.height, currentSize.height))
}

// MARK: - Shared pieces

/// A checkerboard of the quiet fill, behind transparent images.
struct Checkerboard: View {
    static let square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let color = Color(nsColor: DiffColors.checkerboard)
            let columns = Int((size.width / Self.square).rounded(.up))
            let rows = Int((size.height / Self.square).rounded(.up))
            var path = Path()
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    path.addRect(CGRect(x: CGFloat(column) * Self.square, y: CGFloat(row) * Self.square, width: Self.square, height: Self.square))
                }
            }
            context.fill(path, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// An image on the checkerboard, at most its own size.
struct CheckeredImage: View {
    let image: DecodedImage?
    let size: CGSize

    var body: some View {
        ZStack {
            Checkerboard()
            if let image {
                Image(nsImage: image.image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
    }
}

/// "Deleted image, 640 by 480 pixels, 24 KiB".
func imageAccessibilityLabel(_ title: String, image: DecodedImage?, bytes: Int) -> String {
    let kind = title == "Deleted" ? "Deleted image" : "Added image"
    guard let image else {
        return "\(kind), \(formatBytes(Double(bytes), 2))"
    }
    return "\(kind), \(Int(image.pixelSize.width)) by \(Int(image.pixelSize.height)) pixels, \(formatBytes(Double(bytes), 2))"
}

/// "W: 640px | H: 480px | Size: 24 KiB".
func imageFooter(image: DecodedImage?, bytes: Int) -> String {
    let width = Int(image?.pixelSize.width ?? 0)
    let height = Int(image?.pixelSize.height ?? 0)
    return "W: \(width)px | H: \(height)px | Size: \(formatBytes(Double(bytes), 2))"
}

/// One image with a header (an added or deleted file).
struct SingleImagePane: View {
    let title: String
    let shown: ShownImage

    init(title: String, image: ShownImage) {
        self.title = title
        shown = image
    }

    var body: some View {
        let decoded = shown.decoded
        let image = shown.image
        GeometryReader { proxy in
            let available = CGSize(width: max(proxy.size.width - 2 * Metrics.insetLarge, 1), height: max(proxy.size.height - 80, 1))
            let size = getAspectFitSize(decoded?.pixelSize ?? CGSize(width: 64, height: 64), available)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Metrics.insetLarge)
    }
}
