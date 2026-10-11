// A pop-up drawn as a capsule field: a `field` capsule 28 high with the
// chosen item's title and an up-and-down chevron. Settings' rows, sheets'
// forms, and popovers show their choices in it; in a form it fills the
// column, as the capsule text fields beside it do. Its menu is Espalier's
// card, below the capsule and at least as wide, with a check beside the
// chosen item; VoiceOver sees a pop-up button with the chosen title.

import SwiftUI

/// A pop-up as a capsule field: the chosen item's title and an up-and-down
/// chevron on the `field` fill.
///
/// The items are `MenuChoice`s, with sections and dividers, and actions
/// for items that do something rather than choose ("Other…"). The title is
/// passed in, as the chosen item's title may differ from its choice's.
public struct CapsulePopUp<Value: Hashable>: View {
    private let label: String
    private let title: String
    private let items: () -> MenuContent
    @Binding private var selection: Value

    /// - Parameters:
    ///   - label: What VoiceOver calls the pop-up ("Email").
    ///   - title: The chosen item's title, shown in the capsule.
    ///   - items: The menu's choices, built as it opens.
    public init(_ label: String, selection: Binding<Value>, title: String, @MenuBuilder items: @escaping () -> MenuContent) {
        self.label = label
        self.title = title
        self.items = items
        _selection = selection
    }

    public var body: some View {
        MenuOpeningButton(kind: .popUp, accessibilityLabel: label, accessibilityValue: title, menu: { [items, $selection] in
            items().resolvingOptions(selection: $selection)
        }) {
            HStack(spacing: Metrics.CapsuleMenu.chevronSpacing) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: Metrics.CapsuleMenu.chevronSize, weight: .semibold))
                    .foregroundStyle(.text3)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(FieldCapsuleButtonStyle())
    }
}

/// A button drawn as a capsule field: the `field` fill, primary text, the
/// hover wash, darker while pressed, and a field's focus ring on its edge.
/// A capsule pop-up's look.
struct FieldCapsuleButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusRingButton(configuration: configuration, style: FieldCapsuleButtonDrawing())
    }
}

/// Draws a capsule field button, its focus ring included.
private struct FieldCapsuleButtonDrawing: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FieldCapsuleButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct FieldCapsuleButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    /// Whether the button has keyboard focus.
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        label
            .font(Typography.row)
            .foregroundStyle(.text)
            .padding(.leading, Metrics.ControlHeight.horizontalPadding(for: controlSize))
            .padding(.trailing, Metrics.CapsulePopUp.trailingPadding)
            .frame(height: Metrics.ControlHeight.height(for: controlSize))
            .background(Capsule(style: .circular).fill(.field))
            .overlay(
                Capsule(style: .circular).fill(overlay)
                    .pressMotion(isPressed)
                    .hoverMotion(isHovered)
                    .allowsHitTesting(false)
            )
            .contentShape(Capsule(style: .circular))
            .opacity(isEnabled ? 1 : Palette.disabledOpacity)
            .overlay {
                CapsuleFocusRing(isFocused: isFocused)
            }
            .onHover { isHovered = $0 }
    }

    private var overlay: Color {
        guard isEnabled else {
            return .clear
        }
        if isPressed {
            return Color(nsColor: Palette.hover).opacity(2)
        }
        return isHovered ? Color(nsColor: Palette.hover) : .clear
    }
}

extension Metrics {
    /// Pop-ups drawn as capsule fields.
    public enum CapsulePopUp {
        /// Between the chevron and the capsule's trailing end.
        public static let trailingPadding: CGFloat = 10
    }
}
