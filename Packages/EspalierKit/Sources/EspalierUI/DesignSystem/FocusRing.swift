// Espalier's focus ring: a 2-point accent ring at 55% in the control's own
// shape, shown while the control has keyboard focus (with keyboard
// navigation on, for controls other than fields). It fades in, settling
// from 1.04× to its size, over 0.15 s, and fades out over 0.1 s. A field
// draws it on its edge; a control with a fill of its own (a button, a
// switch, a checkbox) draws it 1 point outside, so it reads on an accent
// fill too. The system's ring never draws: SwiftUI controls turn their
// focus effect off.

import AppKit
import SwiftUI

extension Metrics {
    /// The focus ring.
    public enum FocusRing {
        /// The ring's width.
        public static let lineWidth: CGFloat = 2
        /// How far the ring's outer edge stands off a control with a fill
        /// of its own, leaving a 1-point gap.
        public static let outset: CGFloat = 3
        /// The accent's opacity in the ring.
        public static let opacity: CGFloat = 0.55
    }
}

extension EnvironmentValues {
    /// Draws every focus ring below as if its control had keyboard focus:
    /// snapshots of the rings, which tests can't give keyboard focus.
    @Entry public var showsFocusRings = false
}

/// The ring in `shape`, `outset` outside it, while `isFocused`.
struct FocusRing<RingShape: InsettableShape>: View {
    let isFocused: Bool
    let shape: RingShape
    var outset: CGFloat = 0
    @Environment(\.motion) private var motion
    @Environment(\.showsFocusRings) private var showsFocusRings

    var body: some View {
        let isShown = isFocused || showsFocusRings
        ZStack {
            if isShown {
                shape
                    .inset(by: -outset)
                    .strokeBorder(Color.accentColor.opacity(Metrics.FocusRing.opacity), lineWidth: Metrics.FocusRing.lineWidth)
                    .transition(.asymmetric(
                        insertion: .scale(scale: Motion.focusRingScale).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(motion.animation(isShown ? Motion.leave : Motion.focusOut), value: isShown)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Espalier's focus ring over the view, in `shape` (sized to the view),
    /// while `isFocused`.
    ///
    /// - Parameter outset: How far the ring's outer edge stands off the
    ///   shape: 0 for a field, whose edge it draws on; `Metrics.FocusRing.outset`
    ///   (the default) for a control with a fill of its own.
    public func focusRing(_ isFocused: Bool, in shape: some InsettableShape, outset: CGFloat = Metrics.FocusRing.outset) -> some View {
        overlay {
            FocusRing(isFocused: isFocused, shape: shape, outset: outset)
        }
    }
}

// MARK: - Buttons

/// Wraps a button in a primitive style so its focus effect turns off where
/// the button reads it (a style's body is inside the button, too late), and
/// draws it with `style`, whose body shows Espalier's ring while the
/// `isFocused` environment value (the inner button's focus) is true.
/// Keyboard shortcuts, roles, and focus bindings on the outer button reach
/// the inner one.
struct FocusRingButton<Style: ButtonStyle>: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let style: Style

    var body: some View {
        Button(configuration)
            .buttonStyle(style)
            .focusEffectDisabled()
    }
}

/// A button that draws only its label, faded while pressed and when
/// disabled, with Espalier's focus ring around it: rows that are buttons,
/// copy buttons, small symbols.
public struct BareButtonStyle: PrimitiveButtonStyle {
    /// The ring's shape around the label.
    public enum RingShape: Sendable {
        /// A rounded rectangle with this corner radius.
        case rounded(CGFloat)
        case capsule
        case circle
    }

    private let ringShape: RingShape
    private let outset: CGFloat

    /// - Parameters:
    ///   - ringShape: The focus ring's shape, sized to the label.
    ///   - outset: How far the ring stands off the label; 0 draws it on
    ///     the label's edge (a row that fills its frame).
    public init(_ ringShape: RingShape = .rounded(Metrics.Radius.small), outset: CGFloat = 0) {
        self.ringShape = ringShape
        self.outset = outset
    }

    public func makeBody(configuration: Configuration) -> some View {
        FocusRingButton(configuration: configuration, style: BareButtonDrawing(ringShape: ringShape, outset: outset))
    }
}

extension PrimitiveButtonStyle where Self == BareButtonStyle {
    /// Only the label, with the focus ring in a rounded rectangle (radius
    /// 5) on its edge.
    public static var bare: BareButtonStyle { BareButtonStyle() }

    /// Only the label, with the focus ring in `ringShape`.
    public static func bare(_ ringShape: BareButtonStyle.RingShape, outset: CGFloat = 0) -> BareButtonStyle {
        BareButtonStyle(ringShape, outset: outset)
    }
}

private struct BareButtonDrawing: ButtonStyle {
    let ringShape: BareButtonStyle.RingShape
    let outset: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        BareButtonBody(label: configuration.label, isPressed: configuration.isPressed, ringShape: ringShape, outset: outset)
    }
}

private struct BareButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let ringShape: BareButtonStyle.RingShape
    let outset: CGFloat
    /// Whether the button has keyboard focus.
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .opacity(isEnabled ? (isPressed ? Metrics.FocusRing.pressedOpacity : 1) : Palette.disabledOpacity)
            .pressMotion(isPressed)
            .overlay {
                ring
            }
    }

    @ViewBuilder
    private var ring: some View {
        switch ringShape {
        case .rounded(let radius):
            Color.clear.focusRing(isFocused, in: RoundedRectangle(cornerRadius: radius, style: .continuous), outset: outset)
        case .capsule:
            Color.clear.focusRing(isFocused, in: Capsule(style: .circular), outset: outset)
        case .circle:
            Color.clear.focusRing(isFocused, in: Circle(), outset: outset)
        }
    }
}

extension Metrics.FocusRing {
    /// A bare button's label while pressed.
    public static let pressedOpacity: CGFloat = 0.6
}
