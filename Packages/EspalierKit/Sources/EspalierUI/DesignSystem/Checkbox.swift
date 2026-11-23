// Espalier's checkbox: chunky, 18 with radius 6, a little key you press.
// Off, it's the content background in a `line2` rim that's thicker along
// the bottom; on or mixed, it's the accent standing on a lip a shade deeper,
// with a bold check or dash in the theme's marks color (`onAccent`, white
// but on a near-white accent). Toggled, it pops: it swells and settles back
// (none with Reduce Motion). One drawing, three renderers: Core
// Graphics for tables that draw their rows (the diff's hunk headers), an
// `NSButton` for AppKit rows and headers (a checkbox to VoiceOver, mixed
// state included), and a SwiftUI view, which a `Toggle` takes with the
// `.checkboxMark` style. Every checkbox in Espalier is one of them. With
// keyboard focus, the SwiftUI one shows Espalier's focus ring around the
// box.

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
        Metrics.Checkbox.box
    }

    /// Draws a checkbox filling `rect` (a square, `size` on a side) in the
    /// current context, in the current drawing appearance's colors.
    ///
    /// - Parameters:
    ///   - flipped: Whether y grows downward in the context.
    ///   - isPressed: Darkens the box while the mouse is down on it.
    public static func draw(
        _ state: CheckboxState,
        in rect: CGRect,
        isEnabled: Bool = true,
        isPressed: Bool = false,
        flipped: Bool
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        if !isEnabled {
            context.setAlpha(Palette.disabledOpacity)
        }
        let scale = rect.width / size
        let radius = Metrics.Checkbox.radius * scale
        let box = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        // The rim (and the lip under the face), then the face on it.
        let face = faceRect(in: rect, state: state, scale: scale, flipped: flipped)
        let faceRadius = max(radius - Metrics.Checkbox.rim * scale, 1)
        switch state {
        case .off:
            Palette.line2.setFill()
            box.fill()
            Palette.background.setFill()
            NSBezierPath(roundedRect: face, xRadius: faceRadius, yRadius: faceRadius).fill()
        case .on, .mixed:
            lipColor.setFill()
            box.fill()
            Palette.accent.setFill()
            NSBezierPath(roundedRect: face, xRadius: radius, yRadius: radius).fill()
            Theme.current.onAccent.setStroke()
            let mark = NSBezierPath()
            mark.lineWidth = Metrics.Checkbox.markWidth * scale
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            for (index, point) in markPoints(state).enumerated() {
                let location = CGPoint(
                    x: face.minX + point.x * face.width,
                    y: flipped ? face.minY + point.y * face.height : face.maxY - point.y * face.height
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
            NSColor.black.withAlphaComponent(Metrics.Checkbox.pressedOpacity).setFill()
            box.fill()
        }
    }

    /// The box's face: inside the rim when off; on or mixed, the whole box
    /// but the lip along its bottom, which it stands on.
    static func faceRect(in rect: CGRect, state: CheckboxState, scale: CGFloat = 1, flipped: Bool) -> CGRect {
        let lip = Metrics.Checkbox.lip * scale
        switch state {
        case .off:
            let rim = Metrics.Checkbox.rim * scale
            let inset = rect.insetBy(dx: rim, dy: rim)
            return CGRect(x: inset.minX, y: flipped ? inset.minY : inset.minY + lip, width: inset.width, height: inset.height - lip)
        case .on, .mixed:
            return CGRect(x: rect.minX, y: flipped ? rect.minY : rect.minY + lip, width: rect.width, height: rect.height - lip)
        }
    }

    /// The lip under a checked box: the accent, a shade deeper.
    static var lipColor: NSColor {
        let accent = Palette.accent
        return NSColor.espalierDynamic { variant in
            let resolved = accent.resolved(in: variant)
            return resolved.blended(withFraction: variant.isDark ? 0.45 : 0.3, of: .black) ?? resolved
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
/// (mixed included) and keeps the target, action, and state of one. Its
/// owners keep it out of the key view loop (the list handles Space).
public final class CheckboxButton: NSButton {
    /// Space between the box and the title.
    static let titleSpacing = Metrics.Checkbox.titleSpacing

    /// Whether the button draws its title. Without it, the title still
    /// sizes the button, takes its clicks, and names it to VoiceOver, and
    /// its owner draws it in its place (`titleRect(height:in:)`).
    public var drawsTitle = true {
        didSet {
            needsDisplay = true
        }
    }

    /// Where a title `titleHeight` high draws in a button of `size`: after
    /// the box, centered vertically, on whole points.
    public static func titleRect(height titleHeight: CGFloat, in size: CGSize) -> CGRect {
        let x = CheckboxDrawing.size + titleSpacing
        let height = ceil(titleHeight)
        return CGRect(x: x, y: ((size.height - height) / 2).rounded(), width: max(size.width - x, 0), height: height)
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.switch)
        title = ""
        allowsMixedState = true
        isBordered = false
        focusRingType = .none
        wantsLayer = true
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

    /// Sets the state; when `animated` and motion runs here, the old box
    /// crossfades into the new one over 0.15 s, and a box without a drawn
    /// title pops. Owners animate only a change of the same item's state,
    /// never a row reused for another.
    public func setState(_ newState: NSControl.StateValue, animated: Bool) {
        let old = CheckboxState(state)
        state = newState
        guard animated, old != CheckboxState(newState), Motion.animates(self) else {
            return
        }
        Motion.crossfade(layer, duration: Motion.leave)
        // Drawn now, so the crossfade takes this change of contents.
        displayIfNeeded()
        if !drawsTitle || title.isEmpty {
            pop()
        }
    }

    /// Swells the box and lets it settle back, about its center: the
    /// button's whole layer scales, so only a button that draws no title
    /// pops.
    private func pop() {
        guard let layer else {
            return
        }
        let box = boxRect
        // The layer's origin is its anchor; the box is centered vertically,
        // so its middle is the same whichever way y grows.
        let center = CGPoint(x: box.midX, y: bounds.height / 2)
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

    public override func draw(_ dirtyRect: NSRect) {
        CheckboxDrawing.draw(CheckboxState(state), in: boxRect, isEnabled: isEnabled, isPressed: isHighlighted, flipped: true)
        guard drawsTitle, let title = drawnTitle else {
            return
        }
        let rect = Self.titleRect(height: title.size().height, in: bounds.size)
        let shown = NSMutableAttributedString(attributedString: title)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        shown.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: shown.length))
        if !isEnabled {
            NSGraphicsContext.current?.cgContext.setAlpha(Palette.disabledOpacity)
        }
        shown.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
    @Environment(\.motion) private var motion

    public init(_ state: CheckboxState) {
        self.state = state
    }

    public var body: some View {
        let size = CheckboxDrawing.size
        let box = CGRect(x: 0, y: 0, width: size, height: size)
        let face = CheckboxDrawing.faceRect(in: box, state: state, flipped: true)
        let radius = Metrics.Checkbox.radius
        let faceRadius = state == .off ? max(radius - Metrics.Checkbox.rim, 1) : radius
        ZStack(alignment: .topLeading) {
            // The rim and face crossfade, and the mark fades and scales in,
            // over 0.15 s.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(state == .off ? Color.line2 : Color(nsColor: CheckboxDrawing.lipColor))
            RoundedRectangle(cornerRadius: faceRadius, style: .continuous)
                .fill(state == .off ? Color(espalier: Palette.background) : Color.accent)
                .frame(width: face.width, height: face.height)
                .offset(x: face.minX, y: face.minY)
            if state != .off {
                Path { path in
                    let points = CheckboxDrawing.markPoints(state).map {
                        CGPoint(x: face.minX + $0.x * face.width, y: face.minY + $0.y * face.height)
                    }
                    path.addLines(points)
                }
                .stroke(
                    Color(nsColor: Theme.current.onAccent),
                    style: StrokeStyle(lineWidth: Metrics.Checkbox.markWidth, lineCap: .round, lineJoin: .round)
                )
                .id(state)
                .transition(motion.animates ? .scale(scale: 0.6).combined(with: .opacity) : .identity)
            }
        }
        .motion(Motion.leave, value: state)
        .frame(width: size, height: size)
        // Toggled, the box swells and settles back.
        .phaseAnimator(Motion.CheckboxPop.scales, trigger: state) { content, scale in
            content.scaleEffect(scale)
        } animation: { _ in
            motion.animates ? .easeOut(duration: Motion.CheckboxPop.duration / Double(Motion.CheckboxPop.scales.count - 1)) : nil
        }
        .opacity(isEnabled ? 1 : Palette.disabledOpacity)
        .accessibilityHidden(true)
    }
}

// MARK: - Toggles

/// Espalier's checkbox for a SwiftUI `Toggle`: the box, then the label
/// beside its first line. The two are one button, so a click on either
/// toggles it, it joins the key view loop with keyboard navigation on (the
/// focus ring around the box), and Space toggles it; VoiceOver sees a
/// checkbox.
public struct CheckboxMarkToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        CheckboxToggleBody(configuration: configuration)
    }
}

extension ToggleStyle where Self == CheckboxMarkToggleStyle {
    /// Espalier's checkbox: the box, then the label.
    public static var checkboxMark: CheckboxMarkToggleStyle { CheckboxMarkToggleStyle() }
}

/// The toggle as a button, and what VoiceOver sees of it.
private struct CheckboxToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(CheckboxToggleButtonStyle(state: state, isFocused: isFocused))
        .focusEffectDisabled()
        .focused($isFocused)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .toggleStyle(.checkbox)
        }
    }

    private var state: CheckboxState {
        if configuration.isMixed {
            return .mixed
        }
        return configuration.isOn ? .on : .off
    }
}

/// Draws the box for its state, darker while pressed and ringed while
/// focused, then the label.
private struct CheckboxToggleButtonStyle: ButtonStyle {
    let state: CheckboxState
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        CheckboxToggleButtonBody(state: state, label: configuration.label, isPressed: configuration.isPressed, isFocused: isFocused)
    }
}

private struct CheckboxToggleButtonBody<Label: View>: View {
    let state: CheckboxState
    let label: Label
    let isPressed: Bool
    let isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.labelsVisibility) private var labelsVisibility

    var body: some View {
        let markOffset = Metrics.RadioList.markBaselineOffset
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Checkbox.titleSpacing) {
            CheckboxMark(state)
                .overlay {
                    // A press darkens the box at once and eases back.
                    RoundedRectangle(cornerRadius: Metrics.Checkbox.radius, style: .continuous)
                        .fill(.black.opacity(isPressed ? Metrics.Checkbox.pressedOpacity : 0))
                        .pressMotion(isPressed)
                }
                .focusRing(isFocused, in: RoundedRectangle(cornerRadius: Metrics.Checkbox.radius, style: .continuous))
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    // The box's center on the label's first line's middle.
                    dimensions[VerticalAlignment.center] + markOffset
                }
            if labelsVisibility != .hidden {
                label
                    .foregroundStyle(.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(isEnabled ? 1 : Palette.disabledOpacity)
            }
        }
        .contentShape(Rectangle())
    }
}

extension Metrics.Checkbox {
    /// The box's side.
    public static let box: CGFloat = 18
    /// The box's corner radius.
    public static let radius: CGFloat = 6
    /// An empty box's rim.
    public static let rim: CGFloat = 1.5
    /// The lip along the bottom: under a checked box's face, and thickening
    /// an empty box's rim.
    public static let lip: CGFloat = 1.5
    /// The check's and the dash's stroke.
    public static let markWidth: CGFloat = 2.25
    /// Between the box and its title.
    public static let titleSpacing: CGFloat = 8
    /// Darkens the box while the mouse is down on it.
    public static let pressedOpacity: Double = 0.12
}

extension Motion {
    /// A toggled checkbox's pop: it swells, dips a little under its size,
    /// and settles.
    public enum CheckboxPop {
        nonisolated public static let scales: [CGFloat] = [1, 1.18, 0.96, 1]
        nonisolated public static let keyTimes: [Double] = [0, 0.35, 0.7, 1]
        nonisolated public static let duration: TimeInterval = 0.3
    }
}
