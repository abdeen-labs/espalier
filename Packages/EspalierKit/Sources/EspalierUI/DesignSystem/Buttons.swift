// Espalier's capsule buttons. Three styles at four heights, from the control
// size: quiet (the quiet fill, ring, and small shadow, medium weight),
// prominent (the deeper accent, white semibold; one per area), and
// secondary (the soft fill, no shadow: Cancel in sheets, Undo). The sync
// button's split variant adds a chevron menu.

import AppKit
import SwiftUI

/// A capsule button's look.
nonisolated public enum CapsuleButtonKind: Sendable {
    case quiet, prominent, secondary
}

/// A capsule button style. Heights follow the control size: small 26,
/// regular 28, large 32 (the toolbar), extra large 34 (Commit).
public struct CapsuleButtonStyle: ButtonStyle {
    private let kind: CapsuleButtonKind

    public init(_ kind: CapsuleButtonKind) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(kind: kind, label: configuration.label, isPressed: configuration.isPressed)
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    /// The quiet fill, ring, and small shadow, medium weight.
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
        kind == .prominent ? .white : .text
    }

    /// The symbol's color: secondary text on quiet and secondary capsules.
    var symbolColor: Color {
        kind == .prominent ? .white : .text2
    }

    var fill: Color {
        switch kind {
        case .quiet: .quiet
        case .prominent: Color(nsColor: Palette.button)
        case .secondary: .soft
        }
    }

    var elevation: Elevation? {
        kind == .quiet ? .quiet : nil
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
    @State private var isHovered = false

    var body: some View {
        let appearance = CapsuleButtonAppearance(kind: kind, controlSize: controlSize, isPressed: isPressed, isHovered: isHovered, isEnabled: isEnabled)
        label
            .labelStyle(CapsuleLabelStyle(symbolColor: appearance.symbolColor))
            .font(appearance.font)
            .foregroundStyle(appearance.foreground)
            .lineLimit(1)
            .padding(.horizontal, appearance.horizontalPadding)
            .frame(height: appearance.height)
            .frame(minWidth: appearance.height)
            .surface(appearance.fill, elevation: appearance.elevation)
            .motion(Motion.kindChange, value: kind)
            .overlay(
                Capsule(style: .circular).fill(appearance.stateOverlay)
                    .pressMotion(isPressed)
                    .hoverMotion(isHovered)
                    .allowsHitTesting(false)
            )
            .contentShape(Capsule(style: .circular))
            .opacity(appearance.opacity)
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

/// A capsule with a main action and a chevron that opens a menu (the sync
/// button): one surface, a hairline between the parts. The main action can
/// take a keyboard shortcut (Return, as a sheet's default button).
public struct SplitCapsuleButton<Label: View, MenuContent: View>: View {
    private let kind: CapsuleButtonKind
    private let action: () -> Void
    private let label: Label
    private let menu: MenuContent
    private let menuLabel: String
    private let shortcut: KeyboardShortcut?
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isChevronHovered = false

    /// - Parameters:
    ///   - menuLabel: What VoiceOver calls the chevron.
    ///   - shortcut: The main action's keyboard shortcut, if any
    ///     (`.defaultAction` for Return).
    public init(
        _ kind: CapsuleButtonKind,
        menuLabel: String = "More Options",
        shortcut: KeyboardShortcut? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label,
        @ViewBuilder menu: () -> MenuContent
    ) {
        self.kind = kind
        self.menuLabel = menuLabel
        self.shortcut = shortcut
        self.action = action
        self.label = label()
        self.menu = menu()
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
            .keyboardShortcut(shortcut)
            .onHover { isHovered = $0 }

            Rectangle()
                .fill(kind == .prominent ? Color.white.opacity(0.35) : .line2)
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)

            Menu {
                menu
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(kind == .prominent ? Color.white : .text3)
                    .frame(width: 26)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(menuLabel)
            .onHover { isChevronHovered = $0 }
        }
        .font(appearance.font)
        .foregroundStyle(appearance.foreground)
        .lineLimit(1)
        .padding(.trailing, 3)
        .frame(height: appearance.height)
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
    }
}

// MARK: - Icon buttons

/// A bare symbol button, 28 points square, in secondary text with a hover
/// wash: the toolbar's overflow menu and its other symbol items.
public struct IconButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    /// A bare symbol, 28 points square, with a hover wash.
    public static var icon: IconButtonStyle { IconButtonStyle() }
}

private struct IconButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        label
            .labelStyle(.iconOnly)
            .font(.system(size: 15))
            .foregroundStyle(.text2)
            .frame(width: Metrics.ControlHeight.regular, height: Metrics.ControlHeight.regular)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isEnabled && (isHovered || isPressed) ? Color(nsColor: Palette.hover).opacity(isPressed ? 2 : 1) : .clear)
                    .pressMotion(isPressed)
                    .hoverMotion(isHovered)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : Palette.disabledOpacity)
            .onHover { isHovered = $0 }
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

    func body(content: Content) -> some View {
        let appearance = CapsuleButtonAppearance(kind: kind, controlSize: controlSize)
        content
            .font(appearance.font)
            .foregroundStyle(appearance.foreground)
            .lineLimit(1)
            .padding(.horizontal, appearance.horizontalPadding)
            .frame(height: appearance.height)
            .surface(appearance.fill, elevation: appearance.elevation)
    }
}
