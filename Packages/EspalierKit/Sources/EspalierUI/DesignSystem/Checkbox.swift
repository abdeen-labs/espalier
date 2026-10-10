// Espalier's checkbox, 15 with radius 5. Off, it's an empty box with a
// `line2` border on the content background; on or mixed, it's filled with
// the accent with a white check or dash. One drawing, three renderers: Core
// Graphics for tables that draw their rows (the diff's hunk headers), an
// `NSButton` for AppKit rows and headers (a checkbox to VoiceOver, mixed
// state included), and a SwiftUI view.

import AppKit
import SwiftUI

/// A checkbox's state.
nonisolated public enum CheckboxState: Sendable, Equatable, CaseIterable {
    case off, on, mixed

    /// From a value that can be partial: true on, false off, nil mixed.
    public init(_ value: Bool?) {
        switch value {
        case true?: self = .on
        case false?: self = .off
        case nil: self = .mixed
        }
    }

    /// From an AppKit control's state.
    public init(_ state: NSControl.StateValue) {
        switch state {
        case .on: self = .on
        case .mixed: self = .mixed
        default: self = .off
        }
    }

    /// The AppKit control state.
    public var controlState: NSControl.StateValue {
        switch self {
        case .on: .on
        case .off: .off
        case .mixed: .mixed
        }
    }
}

/// Draws the checkbox into the current graphics context.
@MainActor
public enum CheckboxDrawing {
    /// The box's side.
    public static var size: CGFloat {
        Metrics.Checkbox.size
    }

    /// A disabled checkbox fades, as disabled capsules do.
    static let disabledOpacity: CGFloat = 0.45

    /// Draws a checkbox filling `rect` (a square, `size` on a side) in the
    /// current context, in the current drawing appearance's colors.
    ///
    /// - Parameters:
    ///   - flipped: Whether y grows downward in the context.
    ///   - isPressed: Darkens the box while the mouse is down on it.
    ///   - alpha: The whole checkbox's opacity (a crossfade between two
    ///     states draws both).
    ///   - markScale: The check's or dash's size, about the box's center,
    ///     as it scales in.
    public static func draw(
        _ state: CheckboxState,
        in rect: CGRect,
        isEnabled: Bool = true,
        isPressed: Bool = false,
        flipped: Bool,
        alpha: CGFloat = 1,
        markScale: CGFloat = 1
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        let opacity = (isEnabled ? 1 : disabledOpacity) * alpha
        if opacity < 1 {
            context.setAlpha(opacity)
        }
        let radius = Metrics.Radius.checkbox * rect.width / size
        switch state {
        case .off:
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            Palette.background.setFill()
            box.fill()
            Palette.line2.setStroke()
            box.lineWidth = 1
            box.stroke()
        case .on, .mixed:
            let box = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            Palette.accent.setFill()
            box.fill()
            NSColor.white.setStroke()
            let mark = NSBezierPath()
            mark.lineWidth = 1.75 * rect.width / size
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            for (index, unscaled) in markPoints(state).enumerated() {
                let point = markScale == 1 ? unscaled : CGPoint(x: 0.5 + (unscaled.x - 0.5) * markScale, y: 0.5 + (unscaled.y - 0.5) * markScale)
                let location = CGPoint(
                    x: rect.minX + point.x * rect.width,
                    y: flipped ? rect.minY + point.y * rect.height : rect.maxY - point.y * rect.height
                )
                if index == 0 {
                    mark.move(to: location)
                } else {
                    mark.line(to: location)
                }
            }
            mark.stroke()
        }
        if isPressed {
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// The mark's points as fractions of the box, from its top left: a
    /// check, or a dash.
    nonisolated static func markPoints(_ state: CheckboxState) -> [CGPoint] {
        switch state {
        case .on: [CGPoint(x: 0.29, y: 0.52), CGPoint(x: 0.44, y: 0.67), CGPoint(x: 0.72, y: 0.35)]
        case .mixed: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5)]
        case .off: []
        }
    }
}

/// A checkbox as an AppKit button: Espalier's box, then its title. It
/// stays an `NSButton` of the switch type, so it's a checkbox to VoiceOver
/// (mixed included) and keeps the target, action, and state of one.
public final class CheckboxButton: NSButton {
    /// Space between the box and the title.
    static let titleSpacing: CGFloat = 8

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.switch)
        title = ""
        allowsMixedState = true
        isBordered = false
    }

    /// A checkbox titled `title` that sends `action` to `target`.
    public convenience init(title: String = "", target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var isFlipped: Bool {
        true
    }

    /// The button draws itself in `draw(_:)`.
    public override var wantsUpdateLayer: Bool {
        false
    }

    public override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    public override var attributedTitle: NSAttributedString {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    public override var state: NSControl.StateValue {
        didSet {
            needsDisplay = true
        }
    }

    public override var isEnabled: Bool {
        didSet {
            needsDisplay = true
        }
    }

    public override var isHighlighted: Bool {
        didSet {
            needsDisplay = true
        }
    }

    /// The title as drawn: its attributes, or the row font in primary text.
    private var drawnTitle: NSAttributedString? {
        guard !title.isEmpty else {
            return nil
        }
        let attributed = attributedTitle
        if attributed.length > 0, attributed.attribute(.font, at: 0, effectiveRange: nil) != nil,
           attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil {
            return attributed
        }
        return NSAttributedString(string: title, attributes: [.font: font ?? AppKitTypography.row, .foregroundColor: Palette.text])
    }

    public override var intrinsicContentSize: NSSize {
        let box = CheckboxDrawing.size
        guard let title = drawnTitle else {
            return NSSize(width: box, height: box)
        }
        let size = title.size()
        return NSSize(width: box + Self.titleSpacing + ceil(size.width), height: max(box, ceil(size.height)))
    }

    /// The box's rect: leading, centered vertically, on whole points.
    var boxRect: CGRect {
        let box = CheckboxDrawing.size
        return CGRect(x: 0, y: ((bounds.height - box) / 2).rounded(), width: box, height: box)
    }

    // MARK: The mark's motion

    /// The state the box is changing from, and when the change began,
    /// while it animates.
    private var change: (from: CheckboxState, start: CFTimeInterval)?
    private var changeLink: CADisplayLink?

    /// Sets the state; when `animated` and motion runs here, the box
    /// crossfades and the new mark fades and scales in over 0.15 s. Owners
    /// animate only a change of the same item's state, never a row reused
    /// for another.
    public func setState(_ newState: NSControl.StateValue, animated: Bool) {
        let old = CheckboxState(state)
        state = newState
        guard animated, old != CheckboxState(newState), Motion.animates(self) else {
            endChange()
            return
        }
        change = (old, CACurrentMediaTime())
        if changeLink == nil {
            let link = displayLink(target: self, selector: #selector(changeStep(_:)))
            link.add(to: .main, forMode: .common)
            changeLink = link
        }
        // The last frame, should the display link not fire (a window
        // offscreen).
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.leave + 0.05) { [weak self] in
            self?.changeStep(nil)
        }
    }

    /// How far the change has gone, on the motion curve: 1 when none runs.
    var changeProgress: CGFloat {
        guard let change else {
            return 1
        }
        return CGFloat(Motion.curveProgress((CACurrentMediaTime() - change.start) / Motion.leave))
    }

    @objc private func changeStep(_ link: CADisplayLink?) {
        needsDisplay = true
        if changeProgress >= 1 {
            endChange()
        }
    }

    private func endChange() {
        guard change != nil || changeLink != nil else {
            return
        }
        change = nil
        changeLink?.invalidate()
        changeLink = nil
        needsDisplay = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            endChange()
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let current = CheckboxState(state)
        let progress = changeProgress
        if let change, progress < 1 {
            // The old box fades out under the new one, whose mark scales
            // in from 60%.
            CheckboxDrawing.draw(change.from, in: boxRect, isEnabled: isEnabled, isPressed: isHighlighted, flipped: true, alpha: 1 - progress)
            CheckboxDrawing.draw(current, in: boxRect, isEnabled: isEnabled, isPressed: isHighlighted, flipped: true, alpha: progress, markScale: 0.6 + 0.4 * progress)
        } else {
            CheckboxDrawing.draw(current, in: boxRect, isEnabled: isEnabled, isPressed: isHighlighted, flipped: true)
        }
        guard let title = drawnTitle else {
            return
        }
        let x = boxRect.maxX + Self.titleSpacing
        let height = ceil(title.size().height)
        let rect = CGRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: max(bounds.width - x, 0), height: height)
        let shown = NSMutableAttributedString(attributedString: title)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        shown.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: shown.length))
        if !isEnabled {
            NSGraphicsContext.current?.cgContext.setAlpha(CheckboxDrawing.disabledOpacity)
        }
        shown.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    public override var focusRingMaskBounds: NSRect {
        boxRect
    }

    public override func drawFocusRingMask() {
        let radius = Metrics.Radius.checkbox
        NSBezierPath(roundedRect: boxRect, xRadius: radius, yRadius: radius).fill()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The checkbox as a SwiftUI view, drawn as the AppKit one is. It's only
/// the box: wrap it in a control that says what it toggles.
public struct CheckboxMark: View {
    private let state: CheckboxState
    @Environment(\.isEnabled) private var isEnabled

    public init(_ state: CheckboxState) {
        self.state = state
    }

    public var body: some View {
        let size = Metrics.Checkbox.size
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.checkbox, style: .circular)
        ZStack {
            // The fill crossfades, and the mark fades and scales in, over
            // 0.15 s.
            shape.fill(state == .off ? Color(espalier: Palette.background) : Color.accentColor)
            if state == .off {
                shape.strokeBorder(.line2, lineWidth: 1)
                    .transition(.opacity)
            } else {
                Path { path in
                    let points = CheckboxDrawing.markPoints(state).map { CGPoint(x: $0.x * size, y: $0.y * size) }
                    path.addLines(points)
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                .id(state)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .motion(Motion.leave, value: state)
        .frame(width: size, height: size)
        .opacity(isEnabled ? 1 : CheckboxDrawing.disabledOpacity)
        .accessibilityHidden(true)
    }
}
