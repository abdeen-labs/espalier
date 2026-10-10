// A stepper drawn as a capsule field: minus, the value in SF Mono, and plus
// on the `field` fill, in place of the system's stepper arrows. It's one
// stop in the key view loop; the up and down arrows step it, and VoiceOver
// sees a native stepper.

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
            StepperHalf(systemImage: "minus", isEnabled: isEnabled && canDecrement, action: decrement)
            // The value rolls as the user steps it (0.2 s).
            Text(value)
                .font(Typography.count)
                .foregroundStyle(.text)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
                .motion(Motion.kindChange, value: value)
                .frame(minWidth: Metrics.CapsuleStepper.valueWidth)
            StepperHalf(systemImage: "plus", isEnabled: isEnabled && canIncrement, action: increment)
        }
        .frame(height: Metrics.ControlHeight.regular)
        .background(Capsule(style: .circular).fill(.field))
        .contentShape(.focusEffect, Capsule(style: .circular))
        .opacity(isEnabled ? 1 : 0.45)
        // Focus only with keyboard navigation on, as the native stepper.
        .focusable(interactions: .activate)
        .onKeyPress(.upArrow) {
            step(canIncrement, increment)
        }
        .onKeyPress(.downArrow) {
            step(canDecrement, decrement)
        }
        .accessibilityRepresentation {
            Stepper(label, onIncrement: canIncrement ? increment : nil, onDecrement: canDecrement ? decrement : nil)
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
}

/// Minus or plus: a symbol in secondary text with a hover wash, faded when
/// it can't step.
private struct StepperHalf: View {
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: Metrics.CapsuleStepper.symbolSize, weight: .semibold))
            .foregroundStyle(.text2)
            .frame(width: Metrics.CapsuleStepper.buttonWidth, height: Metrics.ControlHeight.regular)
            .background(Capsule(style: .circular).fill(wash).hoverMotion(isHovered))
            .contentShape(Capsule(style: .circular))
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { isHovered = $0 }
            .onTapGesture {
                if isEnabled {
                    action()
                }
            }
            .accessibilityHidden(true)
    }

    private var wash: Color {
        isEnabled && isHovered ? Color(nsColor: Palette.hover) : .clear
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
