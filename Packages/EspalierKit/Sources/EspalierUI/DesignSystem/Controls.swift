// Espalier's small controls: key caps, the capsule search field, the
// capsule segmented control, the ID chip, icon circles, and the progress
// bar.

import AppKit
import SwiftUI

// MARK: - Key cap

/// A visible keyboard shortcut: 10-point text in a rounded rectangle
/// (radius 5) with a 1-point `line2` border.
public struct KeyCap: View {
    private let keys: String
    private let color: Color?

    /// - Parameters:
    ///   - color: The text and border color on a filled capsule (white on a
    ///     prominent one); nil for the tertiary text and `line2`.
    public init(_ keys: String, color: Color? = nil) {
        self.keys = keys
        self.color = color
    }

    public var body: some View {
        Text(keys)
            .font(Typography.keyCap)
            .tracking(0.2)
            .foregroundStyle(color ?? .text3)
            .padding(.horizontal, 4)
            .frame(minWidth: 17, minHeight: 17)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.small, style: .continuous)
                    .strokeBorder(color?.opacity(0.5) ?? .line2, lineWidth: 1)
            )
            .fixedSize()
            .accessibilityHidden(true)
    }
}

// MARK: - Search field

extension EnvironmentValues {
    /// Whether a capsule search field is drawn as a quiet capsule, raised,
    /// rather than on the `field` fill: on the floating layout's backdrop,
    /// beside quiet capsules.
    @Entry public var searchFieldIsRaised = false
}

/// A capsule search or filter field: a magnifying glass, the field, and a
/// key cap for its shortcut while it's empty, or a clear button once it
/// isn't. Escape clears it.
public struct CapsuleSearchField: View {
    @Binding private var text: String
    @Binding private var focusRequest: Bool
    private let prompt: String
    private let systemImage: String
    private let keyCap: String?
    @FocusState private var isFocused: Bool
    /// Whether the window's first responder is editing the field, which
    /// SwiftUI's focus state doesn't follow in the toolbar.
    @State private var isEditing = false
    /// Counts the requests to focus the field, which reach it through
    /// AppKit too: SwiftUI's focus state doesn't move it in the toolbar.
    @State private var focusRequests = 0
    @Environment(\.controlSize) private var controlSize
    @Environment(\.searchFieldIsRaised) private var isRaised

    /// - Parameters:
    ///   - focusRequest: Set to true to focus the field; the field sets it
    ///     back to false.
    ///   - keyCap: The shortcut that focuses the field, shown while it's
    ///     empty.
    public init(_ prompt: String, text: Binding<String>, systemImage: String = "magnifyingglass", keyCap: String? = nil, focusRequest: Binding<Bool> = .constant(false)) {
        self.prompt = prompt
        self.systemImage = systemImage
        _text = text
        self.keyCap = keyCap
        _focusRequest = focusRequest
    }

    public var body: some View {
        HStack(spacing: Metrics.ControlHeight.symbolSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.text3)
                .accessibilityHidden(true)
            // The prompt is drawn here, on the typed text's baseline, rather
            // than by the field, so it holds still as editing starts and
            // ends.
            ZStack(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                if text.isEmpty {
                    Text(prompt)
                        .lineLimit(1)
                        .foregroundStyle(.text3)
                        .accessibilityHidden(true)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    // AppKit's one-line mode: a pasted line break becomes a
                    // space.
                    .lineLimit(1)
                    .foregroundStyle(.text)
                    .focused($isFocused)
                    .onExitCommand {
                        text = ""
                    }
                    .accessibilityLabel(prompt)
            }
            .font(Typography.row)
            // The line's inset from the capsule's top, rather than
            // centered, as in a capsule field: the field draws its text at
            // its own top, so one measured a little shorter or taller (as a
            // field can be for a moment) would otherwise draw its text
            // lower or higher.
            .padding(.top, (Metrics.ControlHeight.height(for: controlSize) - Metrics.CapsuleField.lineHeight) / 2)
            .frame(maxHeight: .infinity, alignment: .top)
            trailing
        }
        .motion(Motion.mark, value: trailingKind)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: Metrics.ControlHeight.height(for: controlSize))
        .background {
            if isRaised {
                // A quiet capsule, as the controls beside it on the
                // backdrop.
                Color.clear
                    .surface(.quiet, elevation: .quiet)
            } else {
                Capsule(style: .circular).fill(.field)
            }
        }
        .fieldRegion(focusRequest: focusRequests) { isEditing in
            self.isEditing = isEditing
        }
        .overlay {
            CapsuleFocusRing(isFocused: hasFocus)
        }
        .contentShape(Capsule(style: .circular))
        .onTapGesture {
            focus()
        }
        .onChange(of: focusRequest, initial: true) {
            if focusRequest {
                focus()
                focusRequest = false
            }
        }
    }

    /// Focuses the field, through SwiftUI and AppKit both.
    private func focus() {
        isFocused = true
        focusRequests += 1
    }

    /// Whether the field has keyboard focus, by SwiftUI's account or
    /// AppKit's.
    private var hasFocus: Bool {
        isFocused || isEditing
    }

    /// What the field ends with.
    private enum Trailing: Equatable {
        case clear, keyCap, none
    }

    private var trailingKind: Trailing {
        if !text.isEmpty {
            return .clear
        }
        return keyCap != nil && !hasFocus ? .keyCap : .none
    }

    /// The clear button once there's text, else the key cap while the
    /// field doesn't have focus; each fades in and out over 0.12 s.
    @ViewBuilder
    private var trailing: some View {
        switch trailingKind {
        case .clear:
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.text3)
            }
            .buttonStyle(.bare(.circle))
            .accessibilityLabel("Clear")
            .transition(.opacity)
        case .keyCap:
            if let keyCap {
                KeyCap(keyCap)
                    .transition(.opacity)
            }
        case .none:
            EmptyView()
        }
    }
}

/// A capsule field's focus ring: Espalier's ring on the capsule's edge.
struct CapsuleFocusRing: View {
    let isFocused: Bool

    var body: some View {
        FocusRing(isFocused: isFocused, shape: Capsule(style: .circular))
    }
}

// MARK: - Segmented control

/// One segment of a `CapsuleSegmentedControl`.
public struct CapsuleSegment<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String
    public let systemImage: String?
    /// What follows the title (Changes' count).
    let accessory: AnyView?
    /// What VoiceOver reads for the segment: the title, or what the
    /// accessory adds to it ("Ahead, 3").
    let accessibilityTitle: String

    public init(_ title: String, systemImage: String? = nil, value: Value) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        accessory = nil
        accessibilityTitle = title
    }

    /// - Parameter accessibilityTitle: What VoiceOver reads; the title when
    ///   nil.
    public init(_ title: String, systemImage: String? = nil, value: Value, accessibilityTitle: String? = nil, @ViewBuilder accessory: () -> some View) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.accessory = AnyView(accessory())
        self.accessibilityTitle = accessibilityTitle ?? title
    }

    public var id: Value { value }
}

/// A capsule segmented control (Simple | Graph, Unified | Split): a `field`
/// track 28 high with the selected segment raised on a quiet capsule (or
/// the theme's segment selection). The
/// raised capsule slides to a new choice over 0.22 s, the labels' colors
/// crossfading with it. It's as wide as its labels, or, filling its width,
/// as wide as it's offered, its segments sharing it equally. It takes focus
/// only with keyboard navigation on (System Settings › Keyboard), and then
/// shows a capsule field's ring; the left and right arrows move the
/// selection. VoiceOver sees a segmented control.
public struct CapsuleSegmentedControl<Value: Hashable>: View {
    private let label: String
    private let segments: [CapsuleSegment<Value>]
    private let fillsWidth: Bool
    @Binding private var selection: Value
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @Namespace private var namespace

    /// - Parameters:
    ///   - label: What VoiceOver calls the control.
    ///   - fillsWidth: Whether it takes the width it's offered, its
    ///     segments sharing it equally.
    public init(_ label: String, selection: Binding<Value>, segments: [CapsuleSegment<Value>], fillsWidth: Bool = false) {
        self.label = label
        _selection = selection
        self.segments = segments
        self.fillsWidth = fillsWidth
    }

    public var body: some View {
        let layout = fillsWidth ? AnyLayout(FillingSegmentsLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
            ForEach(segments) { segment in
                let isSelected = segment.value == selection
                HStack(spacing: 5) {
                    if let systemImage = segment.systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11))
                    }
                    Text(segment.title)
                    segment.accessory
                }
                .font(Typography.smallButton)
                .foregroundStyle(isSelected ? Color.text : .text2)
                .lineLimit(1)
                // Filling its width, the segments share what's left over,
                // so they need less of their own.
                .padding(.horizontal, fillsWidth ? 8 : 12)
                .frame(maxWidth: fillsWidth ? .infinity : nil, maxHeight: .infinity)
                .background {
                    if isSelected {
                        SegmentSelection()
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .contentShape(Capsule(style: .circular))
                .onTapGesture {
                    selection = segment.value
                }
            }
        }
        .motion(Motion.arrive, value: selection)
        .padding(2)
        .frame(height: Metrics.ControlHeight.regular)
        .background(Capsule(style: .circular).fill(.field))
        .overlay {
            CapsuleFocusRing(isFocused: isFocused)
        }
        .opacity(isEnabled ? 1 : Palette.disabledOpacity)
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            move(by: -1)
        }
        .onKeyPress(.rightArrow) {
            move(by: 1)
        }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(segments) { segment in
                    Text(segment.accessibilityTitle).tag(segment.value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        guard isEnabled, let index = segments.firstIndex(where: { $0.value == selection }) else {
            return .ignored
        }
        let next = index + offset
        guard segments.indices.contains(next) else {
            return .handled
        }
        selection = segments[next].value
        return .handled
    }
}

/// A segmented control's segments across the width offered: equal widths
/// when the widest fits in an equal share, else each its own width and an
/// equal share of what's left; where even their own widths don't fit, each
/// gives up the same part of its width.
private struct FillingSegmentsLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + totalSpacing(subviews)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        return CGSize(width: width, height: proposal.height ?? sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else {
            return
        }
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let available = max(bounds.width - totalSpacing(subviews), 0)
        let total = ideals.reduce(0, +)
        let share = available / CGFloat(subviews.count)
        let widths: [CGFloat]
        if ideals.allSatisfy({ $0 <= share }) {
            widths = ideals.map { _ in share }
        } else if total <= available {
            let extra = (available - total) / CGFloat(subviews.count)
            widths = ideals.map { $0 + extra }
        } else {
            widths = ideals.map { total > 0 ? $0 * available / total : share }
        }
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func totalSpacing(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(subviews.count - 1, 0))
    }
}

/// The selected segment's capsule: a quiet capsule with its ring and small
/// shadow, or the theme's segment selection, raised as the sidebar's card
/// is.
private struct SegmentSelection: View {
    var body: some View {
        let theme = Theme.current
        let shape = Capsule(style: .circular)
        if let fill = theme.segmentSelection {
            shape
                .fill(Color(nsColor: fill))
                .shadow(color: Color(nsColor: theme.raisedShadow), radius: 1, y: 1)
                .overlay(shape.strokeBorder(Color(nsColor: theme.raisedRing), lineWidth: 1))
        } else {
            shape
                .fill(.clear)
                .surface(.quiet, elevation: .quiet)
        }
    }
}

// MARK: - Chips

/// A neutral chip: SF Mono text on the `field` fill (commit IDs).
public struct MonoChip<Accessory: View>: View {
    private let text: String
    private let isSelectable: Bool
    private let accessory: Accessory

    /// - Parameter isSelectable: Whether its text can be selected and
    ///   copied.
    public init(_ text: String, isSelectable: Bool = false, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.text = text
        self.isSelectable = isSelectable
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: 5) {
            if isSelectable {
                Text(text)
                    .font(Typography.sha)
                    .textSelection(.enabled)
            } else {
                Text(text)
                    .font(Typography.sha)
            }
            accessory
        }
        .foregroundStyle(.text2)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule(style: .circular).fill(.field))
    }
}

// MARK: - Icon circles

/// A symbol in a soft circle: the action list's rows, a sheet's call to
/// action, the cloning and push protection states, History's banners, and
/// small headings and lists (the AI conflict sheet's phase, a squash's
/// co-authors, a submodule's diff).
public struct IconCircle: View {
    private let systemImage: String
    private let size: CGFloat
    private let tint: Color?

    /// - Parameter tint: The symbol's color on its own 9% wash; nil for
    ///   secondary text on the `field` fill.
    public init(_ systemImage: String, size: CGFloat = 24, tint: Color? = nil) {
        self.systemImage = systemImage
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5))
            .foregroundStyle(tint ?? .text2)
            .frame(width: size, height: size)
            .background(Circle().fill(tint.map { $0.opacity(0.12) } ?? .field))
    }
}

// MARK: - Progress

/// A thin progress bar: a capsule fill on a faint capsule track of the same
/// color, neutral gray as the arc is. The fill eases to each new value over
/// 0.15 s. While how far the work has got isn't known, a segment sweeps
/// across the track, eased in and out every 1.4 s; where motion doesn't run
/// it stays still in the middle.
public struct CapsuleProgressBar: View {
    private let value: Double?
    private let tint: NSColor
    @Environment(\.motion) private var motion

    /// - Parameters:
    ///   - value: How far the work has got, 0 to 1; nil sweeps a segment
    ///     across.
    ///   - tint: The fill's color; the track is the same color, faint.
    public init(value: Double?, tint: NSColor = Palette.text2) {
        self.value = value.map { min(max($0, 0), 1) }
        self.tint = tint
    }

    public var body: some View {
        let color = Color(nsColor: tint)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .circular)
                    .fill(color.opacity(Metrics.Progress.trackOpacity))
                if let value {
                    Capsule(style: .circular)
                        .fill(color)
                        .frame(width: max(proxy.size.height, proxy.size.width * value))
                        .opacity(value > 0 ? 1 : 0)
                        .motion(Motion.leave, value: value)
                } else if motion.animates {
                    TimelineView(.animation) { context in
                        segment(color, width: proxy.size.width, position: Self.sweep(at: context.date))
                    }
                } else {
                    segment(color, width: proxy.size.width, position: 0.5)
                }
            }
            .clipShape(Capsule(style: .circular))
        }
        .frame(height: Metrics.Progress.barHeight)
        .accessibilityElement()
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The sweeping segment `position` of the way across: at 0 just before
    /// the track's leading end, at 1 just past its trailing end.
    private func segment(_ color: Color, width: CGFloat, position: Double) -> some View {
        let length = width * Metrics.Progress.barSegment
        return Capsule(style: .circular)
            .fill(color)
            .frame(width: length)
            .offset(x: (width + length) * position - length)
    }

    /// How far across the segment is at `date`: 0 to 1, eased in and out,
    /// a sweep per `Motion.sweep`.
    private static func sweep(at date: Date) -> Double {
        let time = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Motion.sweep) / Motion.sweep
        return time * time * (3 - 2 * time)
    }
}
