// WCAG contrast ratios: text ≥ 4.5:1 and graphical marks ≥ 3:1 against the
// row background, in both appearances.

import AppKit
@testable import EspalierUI

/// Contrast between colors as an appearance resolves them.
enum ContrastCheck {
    /// The WCAG contrast ratio of `foreground` (composited over
    /// `background` when translucent) against `background`, in `variant`.
    static func ratio(_ foreground: NSColor, against background: NSColor, in variant: AppearanceVariant) -> Double {
        let back = components(background.resolved(in: variant))
        let front = composite(components(foreground.resolved(in: variant)), over: back)
        let lighter = max(luminance(front), luminance(back))
        let darker = min(luminance(front), luminance(back))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// sRGB components, with alpha.
    private static func components(_ color: NSColor) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent), Double(srgb.alphaComponent))
    }

    private static func composite(
        _ front: (red: Double, green: Double, blue: Double, alpha: Double),
        over back: (red: Double, green: Double, blue: Double, alpha: Double)
    ) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let alpha = front.alpha
        return (
            front.red * alpha + back.red * (1 - alpha),
            front.green * alpha + back.green * (1 - alpha),
            front.blue * alpha + back.blue * (1 - alpha),
            1
        )
    }

    /// WCAG relative luminance.
    private static func luminance(_ color: (red: Double, green: Double, blue: Double, alpha: Double)) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }
}
