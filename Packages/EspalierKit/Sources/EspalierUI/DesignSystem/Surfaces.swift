// Espalier's flat surfaces and shadows. Surfaces are opaque; only things
// that float (toasts, the operation capsule, cards over content) cast a
// shadow. No glass or materials of Espalier's own.

import AppKit
import SwiftUI

/// How far a surface stands off what's behind it.
nonisolated public enum Elevation: Sendable, CaseIterable {
    /// Quiet controls and cards: a 1-point ring and a small shadow.
    case quiet
    /// Floating cards and toasts: the ring and a soft, wide shadow.
    case floating
    /// Sheets.
    case sheet

    /// The 1-point ring around the shape: black 8% (white 9% in dark).
    public var ring: NSColor? {
        switch self {
        case .quiet, .floating:
            .espalierDynamic(
                light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.09),
                highContrastLight: NSColor.black.withAlphaComponent(0.3), highContrastDark: NSColor.white.withAlphaComponent(0.35)
            )
        case .sheet:
            nil
        }
    }

    /// The shadow's color.
    public var shadowColor: NSColor {
        switch self {
        case .quiet:
            .espalierDynamic(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.black.withAlphaComponent(0.4))
        case .floating:
            .espalierDynamic(light: NSColor.black.withAlphaComponent(0.12), dark: NSColor.black.withAlphaComponent(0.45))
        case .sheet:
            NSColor.black.withAlphaComponent(0.2)
        }
    }

    /// The shadow's blur (CSS's blur radius, so SwiftUI's radius is half).
    public func blur(dark: Bool) -> CGFloat {
        switch self {
        case .quiet: 3
        case .floating: dark ? 28 : 24
        case .sheet: 60
        }
    }

    /// The shadow's offset downward.
    public func offset(dark: Bool) -> CGFloat {
        switch self {
        case .quiet: 1
        case .floating: dark ? 10 : 8
        case .sheet: 24
        }
    }
}

/// Fills a shape and gives it an elevation's ring and shadow.
struct SurfaceModifier<S: InsettableShape>: ViewModifier {
    let fill: Color
    let elevation: Elevation?
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .background {
                if let elevation {
                    shape
                        .fill(fill)
                        .shadow(
                            color: Color(nsColor: elevation.shadowColor),
                            radius: elevation.blur(dark: dark) / 2,
                            y: elevation.offset(dark: dark)
                        )
                } else {
                    shape.fill(fill)
                }
            }
            .overlay {
                if let ring = elevation?.ring {
                    shape
                        .inset(by: -0.5)
                        .stroke(Color(nsColor: ring), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// Puts the view on a flat surface: `fill` in `shape`, with an
    /// elevation's ring and shadow.
    public func surface(_ fill: Color, elevation: Elevation? = nil, in shape: some InsettableShape = Capsule(style: .circular)) -> some View {
        modifier(SurfaceModifier(fill: fill, elevation: elevation, shape: shape))
    }

    /// Floats the view on a quiet capsule with the floating shadow: the
    /// operation capsule and toasts.
    public func floatingSurface(in shape: some InsettableShape = Capsule(style: .circular)) -> some View {
        surface(.quiet, elevation: .floating, in: shape)
    }

    /// A card: the quiet fill with the quiet ring, radius 14.
    public func cardSurface(cornerRadius: CGFloat = Metrics.Radius.card) -> some View {
        surface(.quiet, elevation: .quiet, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A 1-point divider in the `line` color.
public struct Hairline: View {
    private let axis: Axis

    public init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        Rectangle()
            .fill(.line)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .accessibilityHidden(true)
    }
}
