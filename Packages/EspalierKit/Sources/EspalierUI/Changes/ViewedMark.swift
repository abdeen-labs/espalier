// All Work's viewed mark: a round check, so it never reads as Uncommitted's
// square include checkbox. Not viewed, a ring; viewed, a leaf disc
// with a white check that pops as it turns on.

import AppKit
import SwiftUI

/// The viewed mark as an AppKit button: a toggle VoiceOver sees as a
/// checkbox, drawn round. Rows keep it out of the key view loop.
final class ViewedMarkButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.switch)
        title = ""
        isBordered = false
        focusRingType = .none
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        false
    }

    override var state: NSControl.StateValue {
        didSet {
            needsDisplay = true
        }
    }

    override var isHighlighted: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CheckboxDrawing.size, height: CheckboxDrawing.size)
    }

    /// Sets the state; when `animated` and motion runs here, the old mark
    /// crossfades into the new one over 0.15 s, and turning on pops.
    func setState(_ newState: NSControl.StateValue, animated: Bool) {
        let wasOn = state == .on
        state = newState
        guard animated, wasOn != (newState == .on), Motion.animates(self) else {
            return
        }
        Motion.crossfade(layer, duration: Motion.leave)
        displayIfNeeded()
        if newState == .on, !CheckboxDrawing.isFlat {
            pop()
        }
    }

    /// Swells the mark and lets it settle back, about its center, as a
    /// checkbox does.
    private func pop() {
        guard let layer else {
            return
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        func scaled(_ scale: CGFloat) -> NSValue {
            var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
            return NSValue(caTransform3D: transform)
        }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = Motion.CheckboxPop.scales.map(scaled)
        animation.keyTimes = Motion.CheckboxPop.keyTimes.map { NSNumber(value: $0) }
        animation.duration = Motion.CheckboxPop.duration
        animation.timingFunctions = Array(repeating: Motion.timingFunction, count: Motion.CheckboxPop.scales.count - 1)
        layer.add(animation, forKey: "pop")
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height, CheckboxDrawing.size)
        let rect = CGRect(x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        ViewedMarkDrawing.draw(isOn: state == .on, in: rect, isPressed: isHighlighted)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// How the viewed mark draws.
enum ViewedMarkDrawing {
    /// The ring's width while not viewed: the key's rim, or the flat box's
    /// border.
    static var ringWidth: CGFloat {
        CheckboxDrawing.isFlat ? 1 : 1.75
    }

    /// The viewed disc's color.
    static var color: NSColor {
        Palette.success
    }

    /// Draws the mark filling `rect`, a square, in the current context
    /// (flipped).
    static func draw(isOn: Bool, in rect: CGRect, isPressed: Bool = false) {
        let circle = NSBezierPath(ovalIn: rect)
        if isOn {
            color.setFill()
            circle.fill()
            NSColor.white.setStroke()
            let mark = NSBezierPath()
            mark.lineWidth = CheckboxDrawing.markWidth
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            for (index, point) in CheckboxDrawing.markPoints(.on).enumerated() {
                let location = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
                if index == 0 {
                    mark.move(to: location)
                } else {
                    mark.line(to: location)
                }
            }
            mark.stroke()
        } else {
            let inset = ringWidth / 2
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            Palette.line2.setStroke()
            ring.lineWidth = ringWidth
            ring.stroke()
        }
        if isPressed {
            NSColor.black.withAlphaComponent(Metrics.Checkbox.pressedOpacity).setFill()
            circle.fill()
        }
    }
}
