// Espalier's spinner and progress ring: an arc on a faint ring, neutral gray
// unless tinted. While how far the work has got isn't known, an arc about a
// quarter of the way round turns clockwise once every 0.9 s; with a value,
// the arc fills the ring clockwise from twelve o'clock. `ArcProgress` draws
// both in SwiftUI and `ArcProgressView` the spinner in AppKit, both from
// `Metrics.Progress`. Where motion doesn't run (Reduce Motion, snapshots,
// offscreen windows) the spinner's arc stays still at twelve o'clock.

import AppKit
import QuartzCore
import SwiftUI

/// The spinner, or with a value the progress ring, for SwiftUI.
public struct ArcProgress: View {
    private let size: Metrics.Progress.ArcSize
    private let value: Double?
    private let tint: NSColor
    @Environment(\.motion) private var motion
    @Environment(\.fixedNow) private var fixedNow

    /// - Parameters:
    ///   - size: Mini in a symbol's place, small beside text, large alone.
    ///   - value: How far the work has got, 0 to 1; nil turns the arc.
    ///   - tint: The arc's color; the ring under it is the same color,
    ///     faint.
    public init(_ size: Metrics.Progress.ArcSize, value: Double? = nil, tint: NSColor = Palette.text2) {
        self.size = size
        self.value = value.map { min(max($0, 0), 1) }
        self.tint = tint
    }

    public var body: some View {
        Group {
            if let value {
                // The arc eases to each new value over 0.15 s, as the
                // progress bar's fill does.
                ring(arc: value, turn: 0)
                    .motion(Motion.leave, value: value)
            } else if motion.animates, fixedNow == nil {
                // Panes hosted in AppKit carry the fixed clock but not the
                // suppressed motion: still under either.
                TimelineView(.animation) { context in
                    ring(arc: size.arc, turn: Self.turn(at: context.date))
                }
            } else {
                ring(arc: size.arc, turn: 0)
            }
        }
        .frame(width: size.side, height: size.side)
        // VoiceOver hears the system's busy or progress indicator.
        .accessibilityRepresentation {
            if let value {
                ProgressView(value: value)
            } else {
                ProgressView()
            }
        }
    }

    /// The ring, and the arc covering `arc` of it from twelve o'clock,
    /// turned `turn` of the way round.
    private func ring(arc: Double, turn: Double) -> some View {
        let color = Color(nsColor: tint)
        return ZStack {
            Circle()
                .stroke(color.opacity(Metrics.Progress.trackOpacity), lineWidth: size.stroke)
            Circle()
                .trim(from: 0, to: arc)
                .stroke(color, style: StrokeStyle(lineWidth: size.stroke, lineCap: .round))
                // The trim starts at three o'clock: a quarter turn back
                // starts it at twelve.
                .rotationEffect(.degrees(360 * turn - 90))
        }
        .frame(width: size.radius * 2, height: size.radius * 2)
    }

    /// How far round the turning arc is at `date`: 0 to 1, a turn per
    /// `Motion.spin`.
    private static func turn(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Motion.spin) / Motion.spin
    }
}

/// The spinner, for AppKit: the same ring and turning arc as `ArcProgress`,
/// turned by Core Animation while motion runs in the view
/// (`Motion.animates(_:)`). It starts once its window comes on screen and
/// stops when Reduce Motion is turned on.
final class ArcProgressView: NSView {
    private let size: Metrics.Progress.ArcSize
    private let tint: NSColor
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    /// The window whose visibility the view follows.
    private weak var observedWindow: NSWindow?
    /// The turn the running animation makes in the layers' coordinates: 2π
    /// where y points down, -2π where it points up (clockwise either way).
    private var spinAngle: CGFloat?

    private static let spinKey = "spin"

    /// - Parameters:
    ///   - size: Mini in a symbol's place, small beside text, large alone.
    ///   - tint: The arc's color; the ring under it is the same color,
    ///     faint.
    init(_ size: Metrics.Progress.ArcSize, tint: NSColor = Palette.text2) {
        self.size = size
        self.tint = tint
        super.init(frame: CGRect(x: 0, y: 0, width: size.side, height: size.side))
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = size.stroke
            layer?.addSublayer(shape)
        }
        arc.lineCap = .round
        updateColors()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: size.side, height: size.side)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: observedWindow)
        }
        observedWindow = newWindow
        if let newWindow {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowVisibilityDidChange),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: newWindow
            )
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateShapes()
        updateSpin()
    }

    override func layout() {
        super.layout()
        updateShapes()
        updateSpin()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        updateSpin()
    }

    @objc private func displayOptionsDidChange(_ notification: Notification) {
        updateSpin()
    }

    /// Whether the layers' coordinates have y pointing down, which AppKit
    /// decides from the views above.
    private var isYDown: Bool {
        layer?.contentsAreFlipped() ?? false
    }

    /// The ring, and the arc from twelve o'clock clockwise.
    private func updateShapes() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = size.radius
        // Clockwise on screen is a falling angle where y points up and a
        // rising one where it points down.
        let direction: CGFloat = isYDown ? 1 : -1
        let twelve = -direction * .pi / 2
        let path = CGMutablePath()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: twelve,
            endAngle: twelve + direction * 2 * .pi * size.arc,
            clockwise: direction < 0
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        arc.frame = bounds
        arc.path = path
        CATransaction.commit()
    }

    fileprivate func updateColors() {
        var color = tint.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = tint.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeColor = color
        track.strokeColor = color.copy(alpha: color.alpha * Metrics.Progress.trackOpacity)
        CATransaction.commit()
    }

    /// Turns the arc while motion runs here, else leaves it still. A turn
    /// already running carries on, so the arc never jumps back to twelve.
    private func updateSpin() {
        guard Motion.animates(self) else {
            arc.removeAnimation(forKey: Self.spinKey)
            spinAngle = nil
            return
        }
        let angle: CGFloat = isYDown ? 2 * .pi : -2 * .pi
        guard angle != spinAngle || arc.animation(forKey: Self.spinKey) == nil else {
            return
        }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = angle
        spin.duration = Motion.spin
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: Self.spinKey)
        spinAngle = angle
    }
}

extension ArcProgressView: LookChangeObserving {
    func lookDidChange() {
        updateColors()
    }
}
