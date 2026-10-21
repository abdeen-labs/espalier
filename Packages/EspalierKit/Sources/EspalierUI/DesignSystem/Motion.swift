// Espalier's motion. One ease-out curve, cubic (0.2, 0, 0, 1), for SwiftUI
// and Core Animation; 0.22 s for what arrives or moves, 0.15 s for what
// leaves or swaps, 0.25 s ease-in-out for scrolls; hover fades in over
// 0.08 s and out over 0.15 s; a press shows at once and eases back over
// 0.15 s; a spinner's arc turns once every 0.9 s, and an indeterminate bar
// sweeps every 1.4 s; the floating panes lean 6 points against the
// sidebar's travel over 0.08 s and spring back, bouncing a little.
// One answer to "animate?": never with Reduce Motion on (hover and
// press included), never in a window that isn't on screen (tests draw
// offscreen), and never where motion is turned off (menus and popovers
// opened from such a window, a screen switching repositories).
// Motion never changes a result: models update at once, and only drawing
// animates.

import AppKit
import ObjectiveC
import QuartzCore
import SwiftUI

/// Espalier's motion: the durations, the curve, and whether to animate.
public enum Motion {
    // MARK: Durations

    /// What arrives or moves: a bar growing in, a segment sliding, rows
    /// closing a gap or sliding down.
    nonisolated public static let arrive: TimeInterval = 0.22
    /// What leaves or swaps: a bar leaving, a crossfade, a chevron turning.
    nonisolated public static let leave: TimeInterval = 0.15
    /// A scroll to a row nearby (ease-in-out).
    nonisolated public static let scroll: TimeInterval = 0.25
    /// Hover fades in.
    nonisolated public static let hoverIn: TimeInterval = 0.08
    /// Hover fades out.
    nonisolated public static let hoverOut: TimeInterval = 0.15
    /// A press eases back (it shows at once).
    nonisolated public static let pressRelease: TimeInterval = 0.15
    /// A capsule changing kind (quiet ↔ prominent), its label and symbol
    /// with it; counts rolling; a generated message replacing the shimmer.
    nonisolated public static let kindChange: TimeInterval = 0.2
    /// Small marks crossfading: the diff's hunk checkboxes and number
    /// cells, a field's key cap and clear button.
    nonisolated public static let mark: TimeInterval = 0.12
    /// A focus ring fades out.
    nonisolated public static let focusOut: TimeInterval = 0.1
    /// A menu fades and grows in from its anchor (it fades out over
    /// `leave`).
    nonisolated public static let menuArrive: TimeInterval = 0.1
    /// A focus ring settles from this scale to 1 as it fades in.
    nonisolated public static let focusRingScale: CGFloat = 1.04
    /// How long a copy button shows its check.
    nonisolated public static let copiedCheck: Duration = .milliseconds(1_500)
    /// One turn of a spinner's arc, at a constant speed.
    nonisolated public static let spin: TimeInterval = 0.9
    /// One sweep of an indeterminate progress bar's segment, eased in and
    /// out.
    nonisolated public static let sweep: TimeInterval = 1.4
    /// How far the floating panes lean against the sidebar's travel as it
    /// shows or hides.
    nonisolated public static let sidebarNudge: CGFloat = 6
    /// How long the panes take to lean, on the curve.
    nonisolated public static let sidebarNudgeOut: TimeInterval = 0.08
    /// The spring the panes come back on: its perceptual duration and its
    /// bounce.
    nonisolated public static let sidebarNudgeBack: TimeInterval = 0.35
    nonisolated public static let sidebarNudgeBounce: CGFloat = 0.3

    // MARK: The curve

    /// The curve's control points: a cubic ease-out.
    nonisolated public static let controlPoints: (x1: Double, y1: Double, x2: Double, y2: Double) = (0.2, 0, 0, 1)

    /// The curve as a SwiftUI animation lasting `duration`.
    nonisolated public static func animation(_ duration: TimeInterval) -> Animation {
        .timingCurve(controlPoints.x1, controlPoints.y1, controlPoints.x2, controlPoints.y2, duration: duration)
    }

    /// The curve as a Core Animation timing function.
    nonisolated public static var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(
            controlPoints: Float(controlPoints.x1), Float(controlPoints.y1),
            Float(controlPoints.x2), Float(controlPoints.y2)
        )
    }

    /// A scroll's ease-in-out, for Core Animation.
    nonisolated public static var scrollTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(name: .easeInEaseOut)
    }

    // MARK: Whether to animate

    /// Whether motion runs: the one answer behind SwiftUI's and AppKit's.
    /// Never with Reduce Motion on, and never where it's turned off.
    ///
    /// - Parameters:
    ///   - reduceMotion: The system's Reduce Motion setting.
    ///   - isSuppressed: Motion is turned off here, or the view isn't on
    ///     screen.
    nonisolated public static func allows(reduceMotion: Bool, isSuppressed: Bool) -> Bool {
        !reduceMotion && !isSuppressed
    }

    /// Whether AppKit motion runs in `view`: it's in a window on screen
    /// (or a test turned motion on for its window), and Reduce Motion is
    /// off.
    @MainActor
    public static func animates(_ view: NSView?) -> Bool {
        guard let window = view?.window else {
            return false
        }
        if let override = window.motionOverride {
            return override
        }
        return allows(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, isSuppressed: !window.isVisible)
    }

    /// Runs `changes` in an `NSAnimationContext` group lasting `duration`
    /// on the curve when motion runs in `view`, else in a group of no
    /// duration, so AppKit's own implicit animations (a table's rows
    /// moving) don't run either.
    ///
    /// - Parameter changes: Told whether it animates.
    @MainActor
    public static func run(
        _ duration: TimeInterval,
        in view: NSView?,
        timingFunction: CAMediaTimingFunction = Motion.timingFunction,
        _ changes: (_ animates: Bool) -> Void
    ) {
        let animates = Self.animates(view)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animates ? duration : 0
            context.timingFunction = timingFunction
            context.allowsImplicitAnimation = animates
            changes(animates)
        }
    }

    /// A crossfade of `layer`'s next change of contents (its sublayers'
    /// included), lasting `duration` on the curve.
    @MainActor
    public static func crossfade(_ layer: CALayer?, duration: TimeInterval) {
        guard let layer else {
            return
        }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = timingFunction
        layer.add(fade, forKey: kCATransition)
    }
}

// MARK: - SwiftUI

extension Motion {
    /// A floating capsule (a toast, the operation capsule) rising in from
    /// the bottom over 0.22 s and sinking out over 0.15 s, fading.
    public static var floatingTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity).animation(animation(arrive)),
            removal: .move(edge: .bottom).combined(with: .opacity).animation(animation(leave))
        )
    }

    /// A bar or banner arriving (fading in over 0.22 s while what's below
    /// moves down with it) or leaving (fading out over 0.15 s). Pair it
    /// with `barMotion(_:)` on the stack holding it, so the content beside
    /// it moves with it.
    public static var barTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(animation(arrive)),
            removal: .opacity.animation(animation(leave))
        )
    }
}

/// Whether motion runs in a view tree, as SwiftUI sees it
/// (`EnvironmentValues.motion`).
nonisolated public struct MotionPolicy: Sendable, Equatable {
    /// The system's Reduce Motion setting.
    public var reduceMotion: Bool
    /// Motion is turned off here (`motionSuppressed`).
    public var isSuppressed: Bool

    public init(reduceMotion: Bool = false, isSuppressed: Bool = false) {
        self.reduceMotion = reduceMotion
        self.isSuppressed = isSuppressed
    }

    /// Whether views animate.
    public var animates: Bool {
        Motion.allows(reduceMotion: reduceMotion, isSuppressed: isSuppressed)
    }

    /// The curve lasting `duration`, or nil (no animation) when motion
    /// doesn't run.
    public func animation(_ duration: TimeInterval) -> Animation? {
        animates ? Motion.animation(duration) : nil
    }

    /// `animation` when motion runs, else nil.
    public func animation(_ animation: Animation) -> Animation? {
        animates ? animation : nil
    }

    /// Hover's fade: in over 0.08 s, out over 0.15 s.
    public func hover(_ isHovered: Bool) -> Animation? {
        animation(isHovered ? Motion.hoverIn : Motion.hoverOut)
    }

    /// A press: shows at once, eases back over 0.15 s.
    public func press(_ isPressed: Bool) -> Animation? {
        isPressed ? nil : animation(Motion.pressRelease)
    }
}

extension EnvironmentValues {
    /// Turns motion off below: the menus, popovers, and suggestion lists
    /// opened from a window motion doesn't run in, and a screen for the
    /// update in which it switches repositories (`motionScope(_:)`).
    @Entry public var motionSuppressed = false

    /// Whether motion runs here: off with Reduce Motion, and where it's
    /// suppressed.
    public var motion: MotionPolicy {
        MotionPolicy(reduceMotion: accessibilityReduceMotion, isSuppressed: motionSuppressed)
    }
}

/// Changes `body` makes, animated on the curve over `duration` when
/// `policy` lets motion run, else at once.
@MainActor
public func withMotion<Result>(_ policy: MotionPolicy, _ duration: TimeInterval, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(policy.animation(duration), body)
}

extension View {
    /// Animates the changes `value` brings on the curve over `duration`,
    /// unless motion is off.
    public func motion(_ duration: TimeInterval, value: some Equatable) -> some View {
        modifier(MotionModifier(duration: duration, value: value))
    }

    /// Animates a hover's change of `isHovered`: in over 0.08 s, out over
    /// 0.15 s, unless motion is off.
    public func hoverMotion(_ isHovered: Bool) -> some View {
        modifier(HoverMotionModifier(isHovered: isHovered))
    }

    /// Animates a press: it shows at once and eases back over 0.15 s,
    /// unless motion is off.
    public func pressMotion(_ isPressed: Bool) -> some View {
        modifier(PressMotionModifier(isPressed: isPressed))
    }

    /// Animates a bar or banner in the stack this modifies arriving (0.22
    /// s) or leaving (0.15 s) as `isShown` changes: the bar fades
    /// (`Motion.barTransition`) and the content beside it moves with it.
    public func barMotion(_ isShown: Bool) -> some View {
        modifier(BarMotionModifier(isShown: isShown))
    }

    /// The bar transition where motion runs; none otherwise.
    public func barTransition() -> some View {
        modifier(BarTransitionModifier())
    }

    /// Draws no motion below for the update in which `scope` changes: a
    /// screen kept for another repository changes at once, as navigation
    /// between repositories does.
    public func motionScope(_ scope: AnyHashable?) -> some View {
        modifier(MotionScopeModifier(scope: scope))
    }
}

private struct MotionScopeModifier: ViewModifier {
    let scope: AnyHashable?
    /// The scope shown last; nil before the first.
    @State private var shownScope: AnyHashable??
    @Environment(\.motionSuppressed) private var isSuppressed

    func body(content: Content) -> some View {
        let isNewScope = shownScope.map { $0 != scope } ?? false
        content
            .environment(\.motionSuppressed, isSuppressed || isNewScope)
            .onChange(of: scope, initial: true) {
                shownScope = .some(scope)
            }
    }
}

private struct BarMotionModifier: ViewModifier {
    let isShown: Bool
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.animation(motion.animation(isShown ? Motion.arrive : Motion.leave), value: isShown)
    }
}

private struct BarTransitionModifier: ViewModifier {
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.transition(motion.animates ? Motion.barTransition : .identity)
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let duration: TimeInterval
    let value: Value
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.animation(motion.animation(duration), value: value)
    }
}

private struct HoverMotionModifier: ViewModifier {
    let isHovered: Bool
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.animation(motion.hover(isHovered), value: isHovered)
    }
}

private struct PressMotionModifier: ViewModifier {
    let isPressed: Bool
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.animation(motion.press(isPressed), value: isPressed)
    }
}

// MARK: - Tests' override

extension NSWindow {
    private static var motionOverrideKey: UInt8 = 0

    /// Whether AppKit motion runs in this window whatever its visibility
    /// and Reduce Motion: tests turn it on for an offscreen window to run
    /// the animated paths. Nil (the default) follows `Motion.animates(_:)`'s
    /// rule.
    @MainActor
    public var motionOverride: Bool? {
        get {
            (objc_getAssociatedObject(self, &Self.motionOverrideKey) as? NSNumber)?.boolValue
        }
        set {
            objc_setAssociatedObject(self, &Self.motionOverrideKey, newValue.map { NSNumber(value: $0) }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
