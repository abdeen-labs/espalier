// Espalier's switch: a capsule 32 by 19, the accent when on and `line2` when
// off, with a white knob, in every window, active or not. Every switch in
// Espalier is one (Settings' rows). The switch is a button, so it joins the
// key view loop with keyboard navigation on and Space toggles it;
// VoiceOver sees a switch.

import AppKit
import SwiftUI

/// Espalier's switch: the label (unless labels are hidden), then the
/// capsule.
public struct CapsuleSwitchStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        CapsuleSwitchBody(configuration: configuration)
    }
}

extension ToggleStyle where Self == CapsuleSwitchStyle {
    /// Espalier's switch: the accent when on, `line2` when off, a white
    /// knob.
    public static var capsuleSwitch: CapsuleSwitchStyle { CapsuleSwitchStyle() }
}

/// The label and the capsule.
private struct CapsuleSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.labelsVisibility) private var labelsVisibility

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            if labelsVisibility != .hidden {
                configuration.label
                Spacer(minLength: 0)
            }
            CapsuleSwitchTrack(isOn: configuration.isOn) {
                configuration.isOn.toggle()
            }
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }
}

/// The capsule and its knob, as a button that toggles.
private struct CapsuleSwitchTrack: View {
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            EmptyView()
        }
        .buttonStyle(CapsuleSwitchButtonStyle(isOn: isOn))
    }
}

/// Draws the switch for its state, pressed and disabled included.
private struct CapsuleSwitchButtonStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        CapsuleSwitchDrawing(isOn: isOn, isPressed: configuration.isPressed)
    }
}

/// The switch's drawing: the track, then the knob at its end.
struct CapsuleSwitchDrawing: View {
    let isOn: Bool
    var isPressed = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let size = Metrics.Switch.self
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .circular)
                .fill(isOn ? Color.accentColor : .line2)
            Circle()
                .fill(.white)
                .frame(width: size.knob, height: size.knob)
                .shadow(color: .black.opacity(size.knobShadowOpacity), radius: size.knobShadowRadius, y: size.knobShadowOffset)
                .padding(size.knobInset)
            if isPressed {
                Capsule(style: .circular)
                    .fill(.black.opacity(size.pressedOpacity))
            }
        }
        // The knob slides and the track's color crossfades over 0.22 s.
        .motion(Motion.arrive, value: isOn)
        .frame(width: size.width, height: size.height)
        .contentShape(Capsule(style: .circular))
        .contentShape(.focusEffect, Capsule(style: .circular))
        .opacity(isEnabled ? 1 : Palette.disabledOpacity)
    }
}

extension Metrics {
    /// Espalier's switch: 32 by 19, a white knob.
    public enum Switch {
        public static let width: CGFloat = 32
        public static let height: CGFloat = 19
        /// The knob's diameter, and its inset from the track's edge.
        public static let knob: CGFloat = 15
        public static let knobInset: CGFloat = 2
        /// The knob's shadow: black 25%, 1 down, 2 blurred (CSS's blur, so
        /// SwiftUI's radius is half).
        public static let knobShadowOpacity: Double = 0.25
        public static let knobShadowRadius: CGFloat = 1
        public static let knobShadowOffset: CGFloat = 1
        /// Darkens the track while the mouse is down on it.
        public static let pressedOpacity: Double = 0.1
    }
}
