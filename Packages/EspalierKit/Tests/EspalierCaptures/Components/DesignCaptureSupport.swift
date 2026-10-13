// What the design system's captures do around drawing: stack images drawn
// in windows of their own.

import AppKit
@testable import EspalierUI

/// Helpers for the design system's captures.
@MainActor
enum DesignCapture {
    /// `images` one under another, left-aligned on the window background,
    /// as wide as the widest.
    static func stacked(_ images: [NSBitmapImageRep], appearance: CaptureAppearance) -> NSBitmapImageRep {
        let size = CGSize(
            width: images.map(\.size.width).max() ?? 0,
            height: images.map(\.size.height).reduce(0, +)
        )
        let result = Capture.bitmap(size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
        appearance.appearance.performAsCurrentDrawingAppearance {
            Palette.background.setFill()
            CGRect(origin: .zero, size: size).fill()
        }
        // From the top: AppKit's bitmap context counts up from the bottom.
        var top = size.height
        for image in images {
            top -= image.size.height
            image.draw(in: CGRect(origin: CGPoint(x: 0, y: top), size: image.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return result
    }
}
