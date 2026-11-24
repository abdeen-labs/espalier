// Espalier's flat surfaces and shadows. Surfaces are opaque; only things
// that float (toasts, the operation capsule, popovers, sheets) cast a
// shadow, and quiet capsule buttons a small one, as push buttons do. Cards
// in a pane have the ring alone. Toasts and the operation capsule are
// pillows, standing on a lip as buttons do. No glass or materials of
// Espalier's own but a glass theme's window chrome (ChromeBackdrop.swift).

import AppKit
import SwiftUI

/// How far a surface stands off what's behind it.
nonisolated public enum Elevation: Sendable, CaseIterable {
    /// Cards in a pane: the 1-point ring, no shadow.
    case card
    /// Quiet capsule controls: the ring and a small shadow, as push
    /// buttons have; the ring alone where the theme stands controls on a
    /// lip, which raises them instead.
    case quiet
    /// Things that float (toasts, the operation capsule): the ring and a
    /// soft, wide shadow.
    case floating
    /// Sheets.
    case sheet

    /// The 1-point ring just inside the shape's edge, so it adds nothing
    /// to the shape's size: black 8% (white 9% in dark). A sheet's is drawn
    /// in dark alone, white 10%, where its shadow doesn't show.
    public var ring: NSColor? {
        switch self {
        case .card, .quiet, .floating:
            .espalierDynamic(
                light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.09),
                highContrastLight: NSColor.black.withAlphaComponent(0.3), highContrastDark: NSColor.white.withAlphaComponent(0.35)
            )
        case .sheet:
            .espalierDynamic(
                light: .clear, dark: NSColor.white.withAlphaComponent(0.10),
                highContrastLight: NSColor.black.withAlphaComponent(0.3), highContrastDark: NSColor.white.withAlphaComponent(0.35)
            )
        }
    }

    /// The shadow's color; nil for none.
    public var shadowColor: NSColor? {
        switch self {
        case .card:
            nil
        case .quiet:
            Theme.current.controls.lip > 0 ? nil : .espalierDynamic(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.black.withAlphaComponent(0.4))
        case .floating:
            .espalierDynamic(light: NSColor.black.withAlphaComponent(0.12), dark: NSColor.black.withAlphaComponent(0.45))
        case .sheet:
            NSColor.black.withAlphaComponent(0.2)
        }
    }

    /// The shadow's blur (CSS's blur radius, so SwiftUI's radius is half).
    public func blur(dark: Bool) -> CGFloat {
        switch self {
        case .card: 0
        case .quiet: 3
        case .floating: dark ? 28 : 24
        case .sheet: 60
        }
    }

    /// The shadow's offset downward.
    public func offset(dark: Bool) -> CGFloat {
        switch self {
        case .card: 0
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
                if let elevation, let shadowColor = elevation.shadowColor {
                    shape
                        .fill(fill)
                        .shadow(
                            color: Color(nsColor: shadowColor),
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
                        .strokeBorder(Color(nsColor: ring), lineWidth: 1)
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

    /// Hugs what the view shows, at most `Metrics.Floating.maximumWidth`
    /// wide, however much width it's offered: the operation capsule and
    /// toasts.
    public func floatingWidth() -> some View {
        HuggingWidthLayout(maximumWidth: Metrics.Floating.maximumWidth) { self }
    }

    /// A quiet capsule control's surface (the location control, a
    /// co-author token): the theme's quiet control fill, with the quiet
    /// ring and small shadow where the theme raises quiet controls.
    public func quietControlSurface() -> some View {
        let theme = Theme.current
        return surface(Color(nsColor: theme.quietControl), elevation: theme.quietControlIsRaised ? .quiet : nil)
    }

    /// A card in a pane: the quiet fill with the ring and no shadow, radius
    /// 14.
    public func cardSurface(cornerRadius: CGFloat = Metrics.Radius.card) -> some View {
        surface(.quiet, elevation: .card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Offers its one view at most `maximumWidth` and takes the view's own
/// size, where `frame(maxWidth:)` would grow to `maximumWidth` whenever it's
/// offered more.
private struct HuggingWidthLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maximumWidth, maximumWidth), height: proposal.height)
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

// MARK: - Pillows

extension View {
    /// Floats the view on a chunky pillow: the cream capsule with the
    /// floating ring and shadow, standing on a lip a shade deeper than the
    /// cream where the theme gives controls one. Toasts and the operation
    /// capsule.
    public func pillowSurface(in shape: some InsettableShape = Capsule(style: .circular)) -> some View {
        modifier(PillowSurface(shape: shape))
    }
}

private struct PillowSurface<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        let depth = Theme.current.controls.lip
        content
            .surface(.quiet, elevation: .floating, in: shape)
            .background {
                if depth > 0 {
                    shape
                        .fill(Color(nsColor: Palette.line2))
                        .offset(y: depth)
                }
            }
    }
}

extension Metrics {
    /// Toasts and the operation capsule as pillows.
    public enum Pillow {
        /// The least a pillow is high: its badge, concentric with its end.
        public static let height: CGFloat = 50
        /// Between a pillow's parts.
        public static let spacing: CGFloat = 12
        /// A toast's round close button.
        public static let closeSize: CGFloat = 26
    }
}

extension Typography {
    /// A toast's or the operation capsule's sentence (13, medium).
    public static var pillowMessage: Font { sans(.body, weight: .medium) }
    /// The detail under the operation capsule's sentence (12).
    public static var pillowDetail: Font { secondary }
}
