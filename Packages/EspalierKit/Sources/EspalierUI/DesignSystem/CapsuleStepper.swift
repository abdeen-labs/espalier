// A stepper drawn as a capsule field: minus, the value in SF Mono, and plus
// on the `field` fill. It's one stop in the key view loop, with a field's
// focus ring; the up and down arrows step it, and VoiceOver sees a stepper.

import SwiftUI

/// A capsule stepper: − value +.
public struct CapsuleStepper: View {
    private let label: String
    private let value: String
    private let canDecrement: Bool
    private let canIncrement: Bool
    private let decrement: () -> Void
    private let increment: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.motion) private var motion
    @FocusState private var isFocused: Bool
    /// Whether the last step went down: the value rolls down with it.
    @State private var steppedDown = false

    /// - Parameters:
    ///   - label: What VoiceOver calls the stepper ("Text Size").
    ///   - value: The value as shown ("125%").
    ///   - canDecrement: False at the smallest value: minus is disabled.
    ///   - canIncrement: False at the largest value: plus is disabled.
    public init(
        _ label: String,
        value: String,
        canDecrement: Bool = true,
        canIncrement: Bool = true,
        decrement: @escaping () -> Void,
        increment: @escaping () -> Void
    ) {
        self.label = label
        self.value = value
        self.canDecrement = canDecrement
        self.canIncrement = canIncrement
        self.decrement = decrement
        self.increment = increment
    }

    public var body: some View {
        HStack(spacing: 0) {
            StepperHalf(systemImage: "minus", canStep: canDecrement) {
                stepDown()
            }
            // The value rolls as the user steps it (0.2 s), down for minus
            // and up for plus.
            Text(value)
                .font(Typography.count)
                .foregroundStyle(.text)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(motion.animates ? .numericText(countsDown: steppedDown) : .identity)
                .motion(Motion.kindChange, value: value)
                .frame(minWidth: Metrics.CapsuleStepper.valueWidth)
            StepperHalf(systemImage: "plus", canStep: canIncrement) {
                stepUp()
            }
        }
        .frame(height: Metrics.ControlHeight.regular)
        .background(Capsule(style: .circular).fill(.field))
        .overlay {
            CapsuleFocusRing(isFocused: isFocused)
        }
        .opacity(isEnabled ? 1 : Palette.disabledOpacity)
        // Focus only with keyboard navigation on.
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            step(canIncrement) { stepUp() }
        }
        .onKeyPress(.downArrow) {
            step(canDecrement) { stepDown() }
        }
        .accessibilityRepresentation {
            let onIncrement: (() -> Void)? = canIncrement ? { stepUp() } : nil
            let onDecrement: (() -> Void)? = canDecrement ? { stepDown() } : nil
            Stepper(label, onIncrement: onIncrement, onDecrement: onDecrement)
                .accessibilityValue(value)
        }
    }

    private func step(_ isAllowed: Bool, _ action: () -> Void) -> KeyPress.Result {
        guard isEnabled else {
            return .ignored
        }
        if isAllowed {
            action()
        }
        return .handled
    }

    private func stepUp() {
        steppedDown = false
        increment()
    }

    private func stepDown() {
        steppedDown = true
        decrement()
    }
}

/// Minus or plus: a symbol in secondary text with a hover wash, faded as a
/// disabled control is when it can't step. A disabled stepper fades whole,
/// its halves with it, not twice.
private struct StepperHalf: View {
    let systemImage: String
    let canStep: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: Metrics.CapsuleStepper.symbolSize, weight: .semibold))
            .foregroundStyle(.text2)
            .frame(width: Metrics.CapsuleStepper.buttonWidth, height: Metrics.ControlHeight.regular)
            .background(Capsule(style: .circular).fill(wash).hoverMotion(isHovered))
            .contentShape(Capsule(style: .circular))
            .opacity(canStep || !isEnabled ? 1 : Palette.disabledOpacity)
            .onHover { isHovered = $0 }
            .onTapGesture {
                if isEnabled && canStep {
                    action()
                }
            }
            .accessibilityHidden(true)
    }

    private var wash: Color {
        isEnabled && canStep && isHovered ? Color(nsColor: Palette.hover) : .clear
    }
}

extension Metrics {
    /// The capsule stepper.
    public enum CapsuleStepper {
        /// Minus and plus, each this wide.
        public static let buttonWidth: CGFloat = 28
        /// The value's column.
        public static let valueWidth: CGFloat = 44
        public static let symbolSize: CGFloat = 10
    }
}
