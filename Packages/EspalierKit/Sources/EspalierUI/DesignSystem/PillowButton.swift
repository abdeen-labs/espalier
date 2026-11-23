// The pillow: a big prominent button, a rounded rectangle 44 high in the
// prominent fill, that stands on a lip a shade deeper (where the theme
// gives controls one) and sinks onto it as it's pressed. Commit is one. Its
// label is the caller's; hover lightens it, a press darkens it at once and
// eases back, and with keyboard focus it shows Espalier's ring.

import AppKit
import SwiftUI

/// The pillow button style.
public struct PillowButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        FocusRingButton(configuration: configuration, style: PillowButtonDrawing())
    }
}

extension PrimitiveButtonStyle where Self == PillowButtonStyle {
    /// A big prominent pillow: Commit.
    public static var pillow: PillowButtonStyle { PillowButtonStyle() }
}

private struct PillowButtonDrawing: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillowButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct PillowButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.PillowButtons.radius, style: .continuous)
        let overlay: Color = !isEnabled ? .clear : isPressed ? .black.opacity(0.14) : isHovered ? .white.opacity(0.08) : .clear
        label
            .pillowChrome(isEnabled: isEnabled)
            .overlay(
                shape.fill(overlay)
                    .pressMotion(isPressed)
                    .hoverMotion(isHovered)
                    .allowsHitTesting(false)
            )
            .contentShape(shape)
            .opacity(isEnabled ? 1 : Palette.disabledOpacity)
            .focusRing(isFocused, in: shape)
            .modifier(PillowLip(isPressed: isPressed, isEnabled: isEnabled))
            .onHover { isHovered = $0 }
    }
}

/// Stands the pillow on its lip and sinks it as it's pressed. While the
/// pillow is disabled, the lip tucks up under it and fades with it; it
/// comes and goes over 0.12 s as the pillow turns on and off.
private struct PillowLip: ViewModifier {
    let isPressed: Bool
    let isEnabled: Bool
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        let depth = Metrics.PillowButtons.lip
        content
            .offset(y: isPressed && isEnabled ? depth * 0.7 : 0)
            .pressMotion(isPressed)
            .background {
                if depth > 0 {
                    RoundedRectangle(cornerRadius: Metrics.PillowButtons.radius, style: .continuous)
                        .fill(Color(nsColor: Metrics.PillowButtons.lipColor))
                        .offset(y: isEnabled ? depth : 0)
                        .opacity(isEnabled ? 1 : 0)
                        .animation(motion.animation(Motion.mark), value: isEnabled)
                }
            }
    }
}

extension View {
    /// A pillow's look without the button: the prominent fill, its text
    /// color and font, 44 high (Commit's working state shows in it).
    public func pillowChrome(isEnabled: Bool = true) -> some View {
        self
            .font(Typography.prominentButton)
            .foregroundStyle(Color.prominentText)
            .lineLimit(1)
            .padding(.horizontal, Metrics.PillowButtons.horizontalPadding)
            .frame(height: Metrics.PillowButtons.height)
            .frame(maxWidth: .infinity)
            .background {
                let shape = RoundedRectangle(cornerRadius: Metrics.PillowButtons.radius, style: .continuous)
                if let shadow = Theme.current.controls.prominentShadow {
                    // The theme's shadow under a prominent control.
                    shape.fill(Color(nsColor: Palette.button))
                        .shadow(color: Color(nsColor: shadow), radius: 1, y: 1)
                } else {
                    shape.fill(Color(nsColor: Palette.button))
                }
            }
    }
}

extension Metrics {
    /// The pillow button.
    public enum PillowButtons {
        public static let height: CGFloat = 44
        public static let radius: CGFloat = 15
        public static let horizontalPadding: CGFloat = 16
        /// The lip's depth: the theme's controls' lip, a little deeper for
        /// a bigger button.
        public static var lip: CGFloat {
            Theme.current.controls.lip * 1.5
        }

        /// The lip: the prominent fill a shade deeper.
        public static var lipColor: NSColor {
            let base = Palette.button
            return NSColor.espalierDynamic { variant in
                let resolved = base.resolved(in: variant)
                return resolved.blended(withFraction: variant.isDark ? 0.45 : 0.3, of: .black) ?? resolved
            }
        }
    }
}
