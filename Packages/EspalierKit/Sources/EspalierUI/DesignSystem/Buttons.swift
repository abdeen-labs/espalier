// Espalier's capsule buttons. Three styles at four heights, from the control
// size: quiet (the theme's quiet control fill, with the ring and small
// shadow where the theme raises them, medium weight),
// prominent (the deeper accent, white semibold; one per area), and
// secondary (the soft fill, no shadow: Cancel in sheets, Undo). The sync
// button's split variant adds a chevron menu. With keyboard focus, each
// shows Espalier's ring (`FocusRing`) 1 point outside its shape.

import AppKit
import SwiftUI

/// A capsule button's look.
nonisolated public enum CapsuleButtonKind: Sendable {
    case quiet, prominent, secondary
}

/// A capsule button style. Heights follow the control size: small 26,
/// regular 28, large 32 (the toolbar), extra large 34 (Commit).
public struct CapsuleButtonStyle: PrimitiveButtonStyle {
    private let kind: CapsuleButtonKind

    public init(_ kind: CapsuleButtonKind) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        FocusRingButton(configuration: configuration, style: CapsuleButtonDrawing(kind: kind))
    }
}

/// Draws a capsule button, its focus ring included.
private struct CapsuleButtonDrawing: ButtonStyle {
    let kind: CapsuleButtonKind

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(kind: kind, label: configuration.label, isPressed: configuration.isPressed)
    }
}

extension PrimitiveButtonStyle where Self == CapsuleButtonStyle {
    /// The theme's quiet control (the quiet fill, ring, and small shadow
    /// by default), medium weight.
    public static var quiet: CapsuleButtonStyle { CapsuleButtonStyle(.quiet) }
    /// The deeper accent with white semibold text: one per area.
    public static var prominent: CapsuleButtonStyle { CapsuleButtonStyle(.prominent) }
    /// The soft fill, no shadow: Cancel in sheets, Undo.
    public static var secondary: CapsuleButtonStyle { CapsuleButtonStyle(.secondary) }
}

/// A capsule's look in one state, shared by buttons, the split button, and
/// menus styled as capsules.
struct CapsuleButtonAppearance {
    let kind: CapsuleButtonKind
    let controlSize: ControlSize
    var isPressed = false
    var isHovered = false
    var isEnabled = true
    /// Whether a quiet capsule draws flat on the `field` fill, in a card
    /// (`PaneCards.drawsQuietFlat`).
    var isFlat = false

    var height: CGFloat {
        Metrics.ControlHeight.height(for: controlSize)
    }

    var horizontalPadding: CGFloat {
        Metrics.ControlHeight.horizontalPadding(for: controlSize)
    }

    var isSmall: Bool {
        controlSize == .small || controlSize == .mini
    }

    var font: Font {
        switch (kind, isSmall) {
        case (.prominent, false): Typography.prominentButton
        case (.prominent, true): Typography.smallProminentButton
        case (_, false): Typography.button
        case (_, true): Typography.smallButton
        }
    }

    /// The title's color.
    var foreground: Color {
        kind == .prominent ? .prominentText : .text
    }

    /// The symbol's color: secondary text on quiet and secondary capsules.
    var symbolColor: Color {
        kind == .prominent ? .prominentText : .text2
    }

    var fill: Color {
        switch kind {
        case .quiet: isFlat ? .field : Color(nsColor: Theme.current.quietControl)
        case .prominent: Color(nsColor: Palette.button)
        case .secondary: .soft
        }
    }

    /// A quiet capsule's ring and small shadow, where the theme raises
    /// quiet controls.
    var elevation: Elevation? {
        kind == .quiet && !isFlat && Theme.current.quietControlIsRaised ? .quiet : nil
    }

    /// The theme's shadow under a prominent capsule, if any.
    var shadow: NSColor? {
        kind == .prominent ? Theme.current.controls.prominentShadow : nil
    }

    /// Hover lightens a prominent capsule and shades the others; pressing
    /// darkens.
    var stateOverlay: Color {
        switch (kind, isPressed, isHovered) {
        case (_, _, _) where !isEnabled: .clear
        case (.prominent, true, _): .black.opacity(0.14)
        case (.prominent, false, true): .white.opacity(0.08)
        case (_, true, _): Color(nsColor: Palette.hover).opacity(2)
        case (_, false, true): Color(nsColor: Palette.hover)
        default: .clear
        }
    }

    /// A disabled capsule fades, as every disabled control does.
    var opacity: CGFloat {
        isEnabled ? 1 : Palette.disabledOpacity
    }
}

/// A capsule button's body: label, fill, ring, and state. Hover fades in
/// and out, a press shows at once and eases back, and a change of kind
/// (quiet ↔ prominent) crossfades the fill, text, and symbol over 0.2 s.
struct CapsuleButtonBody<Label: View>: View {
    let kind: CapsuleButtonKind
    let label: Label
    let isPressed: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    /// Whether the button has keyboard focus.
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isInPaneCard) private var isInPaneCard
    @State private var isHovered = false

    var body: some View {
        let appearance = CapsuleButtonAppearance(
            kind: kind,
            controlSize: controlSize,
            isPressed: isPressed,
            isHovered: isHovered,
            isEnabled: isEnabled,
            isFlat: PaneCards.drawsQuietFlat(isInPaneCard: isInPaneCard)
        )
        label
            .labelStyle(CapsuleLabelStyle(symbolColor: appearance.symbolColor))
            .font(appearance.font)
            .foregroundStyle(appearance.foreground)
            .lineLimit(1)
            .padding(.horizontal, appearance.horizontalPadding)
            .frame(height: appearance.height)
            .frame(minWidth: appearance.height)
            .surface(appearance.fill, elevation: appearance.elevation)
            .capsuleShadow(appearance.shadow)
            .motion(Motion.kindChange, value: kind)
            .overlay(
                Capsule(style: .circular).fill(appearance.stateOverlay)
                    .pressMotion(isPressed)
                    .hoverMotion(isHovered)
                    .allowsHitTesting(false)
            )
            .contentShape(Capsule(style: .circular))
            .opacity(appearance.opacity)
            .focusRing(isFocused, in: Capsule(style: .circular))
            .onHover { isHovered = $0 }
    }
}

extension Metrics.ControlHeight {
    /// Between a capsule's symbol and its title (buttons, fields, the
    /// location control).
    public static let symbolSpacing: CGFloat = 7
}

/// A capsule's label: the symbol (in the capsule's symbol color) 7 points
/// before the title.
struct CapsuleLabelStyle: LabelStyle {
    let symbolColor: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Metrics.ControlHeight.symbolSpacing) {
            configuration.icon
                .foregroundStyle(symbolColor)
                .imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - The split button

/// A capsule with a main action and a chevron that opens a menu below the
/// capsule (the sync button): one surface, a hairline between the parts.
/// The main action can take a keyboard shortcut (Return, as a sheet's
/// default button). Each part takes keyboard focus: the main action shows
/// the ring around the whole capsule, the chevron a ring around itself.
public struct SplitCapsuleButton<Label: View>: View {
    /// The part with keyboard focus.
    private enum Part: Hashable {
        case main, menu
    }

    private let kind: CapsuleButtonKind
    private let action: () -> Void
    private let label: Label
    private let menu: () -> MenuContent
    private let menuLabel: String
    private let shortcut: KeyboardShortcut?
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isChevronHovered = false
    @FocusState private var focusedPart: Part?
    @Environment(\.showsFocusRings) private var showsFocusRings
    /// The whole capsule, which the menu opens below.
    @State private var capsule = WeakView<NSView>()

    /// - Parameters:
    ///   - menuLabel: What VoiceOver calls the chevron.
    ///   - shortcut: The main action's keyboard shortcut, if any
    ///     (`.defaultAction` for Return).
    ///   - menu: The chevron's menu, built as it opens.
    public init(
        _ kind: CapsuleButtonKind,
        menuLabel: String = "More Options",
        shortcut: KeyboardShortcut? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label,
        @MenuBuilder menu: @escaping () -> MenuContent
    ) {
        self.kind = kind
        self.menuLabel = menuLabel
        self.shortcut = shortcut
        self.action = action
        self.label = label()
        self.menu = menu
    }

    public var body: some View {
        let appearance = CapsuleButtonAppearance(kind: kind, controlSize: controlSize, isHovered: isHovered, isEnabled: isEnabled)
        HStack(spacing: 0) {
            Button(action: action) {
                label
                    .labelStyle(CapsuleLabelStyle(symbolColor: appearance.symbolColor))
                    .padding(.leading, appearance.horizontalPadding)
                    .padding(.trailing, 9)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .focused($focusedPart, equals: .main)
            .keyboardShortcut(shortcut)
            .onHover { isHovered = $0 }

            Rectangle()
                .fill(kind == .prominent ? Color.prominentText.opacity(0.35) : .line2)
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)

            MenuOpeningButton(kind: .pullDown, accessibilityLabel: menuLabel, placementView: capsule, menu: menu) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(kind == .prominent ? Color.prominentText : .text3)
                    .frame(width: 26)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .focused($focusedPart, equals: .menu)
            .focusRing(focusedPart == .menu, in: Capsule(style: .circular), outset: -Metrics.SplitCapsule.chevronRingInset)
            .fixedSize(horizontal: true, vertical: false)
            .onHover { isChevronHovered = $0 }
        }
        .font(appearance.font)
        .foregroundStyle(appearance.foreground)
        .lineLimit(1)
        .padding(.trailing, 3)
        .frame(height: appearance.height)
        .background {
            MenuPlacementAnchor(holder: capsule)
                .accessibilityHidden(true)
        }
        .surface(appearance.fill, elevation: appearance.elevation)
        .motion(Motion.kindChange, value: kind)
        .overlay(
            Capsule(style: .circular).fill(appearance.stateOverlay)
                .hoverMotion(isHovered)
                .allowsHitTesting(false)
        )
        .overlay(
            Capsule(style: .circular).fill(CapsuleButtonAppearance(kind: kind, controlSize: controlSize, isHovered: isChevronHovered, isEnabled: isEnabled).stateOverlay)
                .allowsHitTesting(false)
                .opacity(isHovered ? 0 : 1)
                .hoverMotion(isChevronHovered)
        )
        .opacity(appearance.opacity)
        .focusRing(focusedPart == .main || (showsFocusRings && focusedPart == nil), in: Capsule(style: .circular))
        .environment(\.showsFocusRings, false)
    }
}

extension Metrics {
    /// The split capsule button.
    public enum SplitCapsule {
        /// The chevron's focus ring sits this far inside the chevron's
        /// part of the capsule.
        public static let chevronRingInset: CGFloat = 2
    }
}

// MARK: - Icon buttons

/// A bare symbol button in secondary text with a hover wash: 28 points
/// square (the toolbar's overflow menu and its other symbol items), or, small,
/// the symbol at its own size with the wash just around it (hints inside a
/// field).
public struct IconButtonStyle: PrimitiveButtonStyle {
    /// An icon button's size.
    public enum Size: Sendable {
        /// 28 points square, the symbol at 15 points.
        case regular
        /// The symbol at its own size and font, the wash 2 points around it.
        case small
    }

    private let size: Size

    public init(_ size: Size = .regular) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        FocusRingButton(configuration: configuration, style: IconButtonDrawing(size: size))
    }
}

extension PrimitiveButtonStyle where Self == IconButtonStyle {
    /// A bare symbol, 28 points square, with a hover wash.
    public static var icon: IconButtonStyle { IconButtonStyle() }

    /// A bare symbol at its own size, with a hover wash just around it.
    public static var smallIcon: IconButtonStyle { IconButtonStyle(.small) }
}

/// Draws an icon button, its focus ring included.
private struct IconButtonDrawing: ButtonStyle {
    let size: IconButtonStyle.Size

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(label: configuration.label, isPressed: configuration.isPressed, size: size)
    }
}

private struct IconButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let size: IconButtonStyle.Size
    @Environment(\.isEnabled) private var isEnabled
    /// Whether the button has keyboard focus.
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size == .regular ? 7 : Metrics.Radius.small, style: .continuous)
        sized(label.labelStyle(.iconOnly))
            .foregroundStyle(.text2)
            .background(
                shape
                    .fill(isEnabled && (isHovered || isPressed) ? Color(nsColor: Palette.hover).opacity(isPressed ? 2 : 1) : .clear)
                    .pressMotion(isPressed)
                    .hoverMotion(isHovered)
                    .padding(size == .regular ? 0 : -Metrics.IconButton.smallWashInset)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : Palette.disabledOpacity)
            .focusRing(isFocused, in: shape, outset: size == .regular ? 0 : Metrics.IconButton.smallWashInset + Metrics.FocusRing.outset)
            .onHover { isHovered = $0 }
    }

    /// The symbol at 15 points in a 28-point square, or as it is.
    @ViewBuilder
    private func sized(_ symbol: some View) -> some View {
        switch size {
        case .regular:
            symbol
                .font(.system(size: 15))
                .frame(width: Metrics.ControlHeight.regular, height: Metrics.ControlHeight.regular)
        case .small:
            symbol
        }
    }
}

extension Metrics {
    /// Icon buttons.
    public enum IconButton {
        /// A small icon button's hover wash reaches this far past its
        /// symbol.
        public static let smallWashInset: CGFloat = 2
    }
}

// MARK: - Static capsules

extension View {
    /// Draws the view as a capsule button looks at rest, without being one:
    /// the sync button while an operation runs shows its progress this way,
    /// legible rather than faded.
    public func capsuleChrome(_ kind: CapsuleButtonKind) -> some View {
        modifier(CapsuleChrome(kind: kind))
    }
}

private struct CapsuleChrome: ViewModifier {
    let kind: CapsuleButtonKind
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isInPaneCard) private var isInPaneCard

    func body(content: Content) -> some View {
        let appearance = CapsuleButtonAppearance(kind: kind, controlSize: controlSize, isFlat: PaneCards.drawsQuietFlat(isInPaneCard: isInPaneCard))
        content
            .font(appearance.font)
            .foregroundStyle(appearance.foreground)
            .lineLimit(1)
            .padding(.horizontal, appearance.horizontalPadding)
            .frame(height: appearance.height)
            .surface(appearance.fill, elevation: appearance.elevation)
            .capsuleShadow(appearance.shadow)
    }
}

extension View {
    /// The theme's shadow under a prominent capsule, 1 point down and
    /// blurred 2 (as CSS blurs), behind the capsule; nothing when nil.
    func capsuleShadow(_ color: NSColor?) -> some View {
        background {
            if let color {
                Capsule(style: .circular)
                    .fill(Color(nsColor: Palette.button))
                    .shadow(color: Color(nsColor: color), radius: 1, y: 1)
            }
        }
    }
}
