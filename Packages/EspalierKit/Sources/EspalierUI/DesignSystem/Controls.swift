// Espalier's small controls: key caps, the capsule search field, the
// capsule segmented control, and file chips.

import AppKit
import SwiftUI

// MARK: - Key cap

/// A visible keyboard shortcut: 10.5-point text in a rounded rectangle
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
                RoundedRectangle(cornerRadius: Metrics.Radius.keyCap, style: .continuous)
                    .strokeBorder(color?.opacity(0.5) ?? .line2, lineWidth: 1)
            )
            .fixedSize()
            .accessibilityHidden(true)
    }
}

// MARK: - Search field

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
    @Environment(\.controlSize) private var controlSize

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
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.text3)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(.text3))
                .textFieldStyle(.plain)
                // AppKit's one-line mode: a pasted line break becomes a
                // space.
                .lineLimit(1)
                .font(Typography.row)
                .foregroundStyle(.text)
                .focused($isFocused)
                .onExitCommand {
                    text = ""
                }
                // The line's inset from the capsule's top, rather than
                // centered, as in a capsule field: the field draws its text
                // at its own top, so one measured a little shorter or
                // taller (as a field can be for a moment) would otherwise
                // draw its text lower or higher.
                .padding(.top, (Metrics.ControlHeight.height(for: controlSize) - Metrics.CapsuleField.lineHeight) / 2)
                .frame(maxHeight: .infinity, alignment: .top)
            trailing
        }
        .motion(Motion.mark, value: trailingKind)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: Metrics.ControlHeight.height(for: controlSize))
        .background(Capsule(style: .circular).fill(.field))
        .fieldRegion()
        .overlay {
            CapsuleFocusRing(isFocused: isFocused)
        }
        .contentShape(Capsule(style: .circular))
        .onTapGesture {
            isFocused = true
        }
        .onChange(of: focusRequest, initial: true) {
            if focusRequest {
                isFocused = true
                focusRequest = false
            }
        }
    }

    /// What the field ends with.
    private enum Trailing: Equatable {
        case clear, keyCap, none
    }

    private var trailingKind: Trailing {
        if !text.isEmpty {
            return .clear
        }
        return keyCap != nil && !isFocused ? .keyCap : .none
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
            .buttonStyle(.plain)
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

/// A capsule field's focus ring: the accent ring that fades in, settling
/// from 1.04× to its size, over 0.15 s, and fades out over 0.1 s.
struct CapsuleFocusRing: View {
    let isFocused: Bool
    @Environment(\.motion) private var motion

    var body: some View {
        ZStack {
            if isFocused {
                Capsule(style: .circular)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2)
                    .transition(.asymmetric(
                        insertion: .scale(scale: Motion.focusRingScale).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(motion.animation(isFocused ? Motion.leave : Motion.focusOut), value: isFocused)
        .allowsHitTesting(false)
    }
}

// MARK: - Segmented control

/// One segment of a `CapsuleSegmentedControl`.
public struct CapsuleSegment<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String
    public let systemImage: String?

    public init(_ title: String, systemImage: String? = nil, value: Value) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
    }

    public var id: Value { value }
}

/// A capsule segmented control (Simple | Graph, Unified | Split): a `field`
/// track 28 high with the selected segment raised on a quiet capsule. The
/// raised capsule slides to a new choice over 0.22 s, the labels' colors
/// crossfading with it, as the native control's does. Like the native
/// control, it takes focus only with keyboard navigation on (System
/// Settings › Keyboard), and then shows a capsule field's ring; the left
/// and right arrows move the selection. VoiceOver sees a native segmented
/// control.
public struct CapsuleSegmentedControl<Value: Hashable>: View {
    private let label: String
    private let segments: [CapsuleSegment<Value>]
    @Binding private var selection: Value
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @Namespace private var namespace

    /// - Parameter label: What VoiceOver calls the control.
    public init(_ label: String, selection: Binding<Value>, segments: [CapsuleSegment<Value>]) {
        self.label = label
        _selection = selection
        self.segments = segments
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isSelected = segment.value == selection
                HStack(spacing: 5) {
                    if let systemImage = segment.systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11))
                    }
                    Text(segment.title)
                }
                .font(Typography.smallButton)
                .foregroundStyle(isSelected ? Color.text : .text2)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background {
                    if isSelected {
                        Capsule(style: .circular)
                            .fill(.clear)
                            .surface(.quiet, elevation: .quiet)
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
        .opacity(isEnabled ? 1 : 0.45)
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
                    Text(segment.title).tag(segment.value)
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

// MARK: - Chips

/// What a file chip shows: the status badge, the name, and the counts.
nonisolated public struct FileChipContent: Sendable, Equatable {
    public var name: String
    public var status: FileStatusKind
    /// Lines added and deleted; nil when unknown (binary files).
    public var added: Int?
    public var deleted: Int?

    public init(name: String, status: FileStatusKind, added: Int? = nil, deleted: Int? = nil) {
        self.name = name
        self.status = status
        self.added = added
        self.deleted = deleted
    }

    /// "+6 −1", leaving out zero counts.
    public var countsText: String? {
        var parts: [String] = []
        if let added, added > 0 {
            parts.append("+\(added)")
        }
        if let deleted, deleted > 0 {
            parts.append("−\(deleted)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// A file chip: a quiet capsule with the status badge, the name, and its
/// counts in SF Mono; the selected one tinted with the accent.
public struct FileChip: View {
    private let content: FileChipContent
    private let isSelected: Bool

    public init(_ content: FileChipContent, isSelected: Bool = false) {
        self.content = content
        self.isSelected = isSelected
    }

    public var body: some View {
        HStack(spacing: 6) {
            StatusGlyph(content.status)
            Text(content.name)
                .font(Typography.smallButton)
                .lineLimit(1)
                .truncationMode(.middle)
            if let counts = content.countsText {
                Text(counts)
                    .font(Typography.tinyCount)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.75)) : AnyShapeStyle(.text3))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.text))
        .padding(.leading, 6)
        .padding(.trailing, 11)
        .frame(height: Metrics.ControlHeight.regular)
        .background {
            if isSelected {
                Capsule(style: .circular).fill(.accentSoft)
            } else {
                Capsule(style: .circular).fill(.clear).surface(.quiet, elevation: .quiet)
            }
        }
        .overlay {
            if isSelected {
                Capsule(style: .circular).inset(by: -0.5).stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([content.name, content.status.title, content.countsText].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A neutral chip: SF Mono text on the `field` fill (commit IDs).
public struct MonoChip<Accessory: View>: View {
    private let text: String
    private let accessory: Accessory

    public init(_ text: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.text = text
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(Typography.sha)
            accessory
        }
        .foregroundStyle(.text2)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule(style: .circular).fill(.field))
    }
}

// MARK: - Icon circles

/// A symbol in a soft circle (the AI and co-author buttons, the empty
/// state's check, simple mode's merge rows).
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

// MARK: - Repository badges

/// A repository's badge: its first letter, white and bold, on a rounded
/// square in a color chosen by its name.
public struct RepositoryBadge: View {
    private let title: String
    private let size: CGFloat

    public init(title: String, size: CGFloat = Metrics.Sidebar.badgeSize) {
        self.title = title
        self.size = size
    }

    public var body: some View {
        Text(Self.letter(of: title))
            .font(.system(size: size * 0.56, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Sidebar.badgeCornerRadius * size / Metrics.Sidebar.badgeSize, style: .continuous)
                    .fill(Self.color(of: title))
            )
            .accessibilityHidden(true)
    }

    /// The title's first character, uppercased ("." for ".dotfiles").
    nonisolated static func letter(of title: String) -> String {
        title.first.map { String($0).uppercased() } ?? "?"
    }

    /// The badges' hues, in degrees: blue, teal, pink, orange, violet,
    /// green, indigo, cyan, rose, and amber (no muddy yellows).
    nonisolated static let hues: [Double] = [212, 168, 330, 26, 268, 142, 238, 192, 350, 40]

    /// A color by the title: one of `hues`, chosen by a stable hash, at 55%
    /// saturation and 52% lightness.
    nonisolated static func color(of title: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in title.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        let hue = hues[Int(hash % UInt32(hues.count))] / 360
        // HSL(h, 55%, 52%) as HSB.
        let lightness = 0.52
        let saturation = 0.55
        let brightness = lightness + saturation * min(lightness, 1 - lightness)
        let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
        return Color(hue: hue, saturation: hsbSaturation, brightness: brightness)
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
    @Environment(\.fixedNow) private var fixedNow

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
                } else if motion.animates, fixedNow == nil {
                    // Panes hosted in AppKit carry the fixed clock but not
                    // the suppressed motion: still under either.
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
