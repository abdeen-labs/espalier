// Espalier's slider: a thin capsule track, faint neutral gray, filled in the
// same gray up to a round knob on the quiet fill with the quiet capsules'
// ring and small shadow (the image diff's opacity and swipe). A press on the
// track moves the knob there and drags it. The knob takes the hover wash,
// fading in and out, and darkens while pressed, as capsules do. It's one
// stop in the key view loop with keyboard navigation on, with the focus ring
// around the knob: the arrows step it by 1% of its range, Page Up and Page
// Down by 10%, and Home and End go to its ends. VoiceOver sees a slider with
// its value.

import SwiftUI

/// A slider over a range of values.
public struct CapsuleSlider: View {
    private let label: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let valueDescription: (Double) -> String
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var isPressed = false

    /// - Parameters:
    ///   - label: What VoiceOver calls the slider.
    ///   - range: The values from the leading end to the trailing one.
    ///   - valueDescription: The value as VoiceOver reads it; nil for the
    ///     percentage of the range ("40%").
    public init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double> = 0...1, valueDescription: ((Double) -> String)? = nil) {
        self.label = label
        _value = value
        self.range = range
        self.valueDescription = valueDescription ?? { [range] value in
            "\(Int((Self.fraction(of: value, in: range) * 100).rounded()))%"
        }
    }

    public var body: some View {
        let fraction = Self.fraction(of: value, in: range)
        GeometryReader { proxy in
            CapsuleSliderDrawing(fraction: fraction, isHovered: isHovered, isPressed: isPressed, isFocused: isFocused)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard isEnabled else {
                                return
                            }
                            isPressed = true
                            let moved = Self.fraction(atX: drag.location.x, width: proxy.size.width)
                            value = Self.value(atFraction: moved, in: range)
                        }
                        .onEnded { _ in
                            isPressed = false
                        }
                )
        }
        .frame(height: Metrics.CapsuleSlider.height)
        .onHover { isHovered = $0 }
        .opacity(isEnabled ? 1 : Palette.disabledOpacity)
        // Focus only with keyboard navigation on.
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(.decrement) }
        .onKeyPress(.downArrow) { step(.decrement) }
        .onKeyPress(.rightArrow) { step(.increment) }
        .onKeyPress(.upArrow) { step(.increment) }
        .onKeyPress(.pageDown) { step(.pageDecrement) }
        .onKeyPress(.pageUp) { step(.pageIncrement) }
        .onKeyPress(.home) { step(.minimum) }
        .onKeyPress(.end) { step(.maximum) }
        .accessibilityRepresentation {
            Slider(value: $value, in: range) {
                Text(label)
            }
            .accessibilityValue(valueDescription(value))
        }
    }

    private func step(_ step: Step) -> KeyPress.Result {
        guard isEnabled else {
            return .ignored
        }
        value = Self.value(after: step, from: value, in: range)
        return .handled
    }
}

extension CapsuleSlider {
    /// A move the keyboard makes.
    nonisolated enum Step: Sendable, CaseIterable {
        /// The arrows: 1% of the range.
        case increment, decrement
        /// Page Up and Page Down: 10% of the range.
        case pageIncrement, pageDecrement
        /// Home and End: the range's ends.
        case minimum, maximum
    }

    /// How far along `range` `value` is, 0 to 1 (0 for an empty range).
    nonisolated static func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else {
            return 0
        }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    /// The value `fraction` of the way along `range`.
    nonisolated static func value(atFraction fraction: Double, in range: ClosedRange<Double>) -> Double {
        let fraction = min(max(fraction, 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * fraction
    }

    /// How far along the track a point `x` across a slider `width` wide is:
    /// the knob's center travels from half a knob in from each end.
    nonisolated static func fraction(atX x: CGFloat, width: CGFloat, knob: CGFloat = Metrics.CapsuleSlider.knob) -> Double {
        let travel = width - knob
        guard travel > 0 else {
            return 0
        }
        return Double(min(max((x - knob / 2) / travel, 0), 1))
    }

    /// The value after `step` from `value`, kept in `range`.
    nonisolated static func value(after step: Step, from value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        let moved: Double
        switch step {
        case .increment: moved = value + span * Metrics.CapsuleSlider.step
        case .decrement: moved = value - span * Metrics.CapsuleSlider.step
        case .pageIncrement: moved = value + span * Metrics.CapsuleSlider.pageStep
        case .pageDecrement: moved = value - span * Metrics.CapsuleSlider.pageStep
        case .minimum: moved = range.lowerBound
        case .maximum: moved = range.upperBound
        }
        return min(max(moved, range.lowerBound), range.upperBound)
    }
}

/// The slider's drawing in one state: the track, its filled part, and the
/// knob `fraction` of the way along.
struct CapsuleSliderDrawing: View {
    let fraction: Double
    var isHovered = false
    var isPressed = false
    var isFocused = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let size = Metrics.CapsuleSlider.self
        let color = Color(nsColor: Palette.text2)
        GeometryReader { proxy in
            let travel = max(proxy.size.width - size.knob, 0)
            let knobX = travel * fraction
            ZStack(alignment: .leading) {
                Capsule(style: .circular)
                    .fill(color.opacity(Metrics.Progress.trackOpacity))
                    .frame(height: size.trackHeight)
                Capsule(style: .circular)
                    .fill(color)
                    .frame(width: knobX + size.knob / 2, height: size.trackHeight)
                Circle()
                    .fill(.clear)
                    .surface(.quiet, elevation: .quiet, in: Circle())
                    .overlay(
                        Circle()
                            .fill(stateOverlay)
                            .pressMotion(isPressed)
                            .hoverMotion(isHovered)
                    )
                    .focusRing(isFocused, in: Circle())
                    .frame(width: size.knob, height: size.knob)
                    .offset(x: knobX)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: size.height)
    }

    /// Hover shades the knob; pressing darkens it.
    private var stateOverlay: Color {
        guard isEnabled else {
            return .clear
        }
        if isPressed {
            return Color(nsColor: Palette.hover).opacity(2)
        }
        return isHovered ? Color(nsColor: Palette.hover) : .clear
    }
}

extension Metrics {
    /// The capsule slider.
    public enum CapsuleSlider {
        /// The control's height, the knob's shadow included.
        public static let height: CGFloat = 20
        public static let trackHeight: CGFloat = 4
        /// The knob's diameter.
        nonisolated public static let knob: CGFloat = 16
        /// The arrows step by this fraction of the range.
        nonisolated public static let step: Double = 0.01
        /// Page Up and Page Down step by this fraction of the range.
        nonisolated public static let pageStep: Double = 0.1
    }
}
