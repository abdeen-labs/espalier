// Espalier's checkbox, 15 with radius 5. Off, it's an empty box with a
// `line2` border on the content background; on or mixed, it's filled with
// the accent with a check or dash in the theme's marks color (`onAccent`,
// white but on a near-white accent). One drawing, three renderers: Core
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
        Metrics.Checkbox.size
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
        let radius = Metrics.Radius.small * rect.width / size
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
            Theme.current.onAccent.setStroke()
            let mark = NSBezierPath()
            mark.lineWidth = 1.75 * rect.width / size
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            for (index, point) in markPoints(state).enumerated() {
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
            NSColor.black.withAlphaComponent(Metrics.Checkbox.pressedOpacity).setFill()
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
/// (mixed included) and keeps the target, action, and state of one. Its
/// owners keep it out of the key view loop (the list handles Space).
public final class CheckboxButton: NSButton {
    /// Space between the box and the title.
    static let titleSpacing = Metrics.Checkbox.titleSpacing

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
    /// crossfades into the new one over 0.15 s. Owners animate only a change
    /// of the same item's state, never a row reused for another.
    public func setState(_ newState: NSControl.StateValue, animated: Bool) {
        let old = CheckboxState(state)
        state = newState
        guard animated, old != CheckboxState(newState), Motion.animates(self) else {
            return
        }
        Motion.crossfade(layer, duration: Motion.leave)
        // Drawn now, so the crossfade takes this change of contents.
        displayIfNeeded()
    }

    public override func draw(_ dirtyRect: NSRect) {
        CheckboxDrawing.draw(CheckboxState(state), in: boxRect, isEnabled: isEnabled, isPressed: isHighlighted, flipped: true)
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
        let size = Metrics.Checkbox.size
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.small, style: .circular)
        ZStack {
            // The fill crossfades, and the mark fades and scales in, over
            // 0.15 s.
            shape.fill(state == .off ? Color(espalier: Palette.background) : Color.accent)
            if state == .off {
                shape.strokeBorder(.line2, lineWidth: 1)
                    .transition(motion.animates ? .opacity : .identity)
            } else {
                Path { path in
                    let points = CheckboxDrawing.markPoints(state).map { CGPoint(x: $0.x * size, y: $0.y * size) }
                    path.addLines(points)
                }
                .stroke(Color(nsColor: Theme.current.onAccent), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                .id(state)
                .transition(motion.animates ? .scale(scale: 0.6).combined(with: .opacity) : .identity)
            }
        }
        .motion(Motion.leave, value: state)
        .frame(width: size, height: size)
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
                    RoundedRectangle(cornerRadius: Metrics.Radius.small, style: .circular)
                        .fill(.black.opacity(isPressed ? Metrics.Checkbox.pressedOpacity : 0))
                        .pressMotion(isPressed)
                }
                .focusRing(isFocused, in: RoundedRectangle(cornerRadius: Metrics.Radius.small, style: .circular))
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
    /// Between the box and its title.
    public static let titleSpacing: CGFloat = 8
    /// Darkens the box while the mouse is down on it.
    public static let pressedOpacity: Double = 0.12
}
