// A pop-up drawn as a capsule field. A `field` capsule 28 high with the
// chosen item's title and an up-and-down chevron, in place of the system's
// pop-up button. The menu stays as macOS draws it, with a check beside the
// chosen item; VoiceOver sees a native pop-up button.

import SwiftUI

/// A pop-up as a capsule field: the chosen item's title and an up-and-down
/// chevron on the `field` fill.
///
/// The items are tagged views, as a `Picker`'s are (sections and dividers
/// included). The title is passed in, because a picker's chosen item can't
/// be read back from its views.
public struct CapsulePopUp<Value: Hashable, Items: View>: View {
    private let label: String
    private let title: String
    private let items: Items
    @Binding private var selection: Value

    /// - Parameters:
    ///   - label: What VoiceOver calls the pop-up ("Email").
    ///   - title: The chosen item's title, shown in the capsule.
    public init(_ label: String, selection: Binding<Value>, title: String, @ViewBuilder items: () -> Items) {
        self.label = label
        self.title = title
        self.items = items()
        _selection = selection
    }

    public var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                items
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
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
        .menuStyle(.button)
        .buttonStyle(FieldCapsuleButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                items
            }
            .pickerStyle(.menu)
        }
    }
}

/// A button drawn as a capsule field: the `field` fill, primary text, the
/// hover wash, and darker while pressed. A capsule pop-up's look.
struct FieldCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FieldCapsuleButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct FieldCapsuleButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
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
            .contentShape(.focusEffect, Capsule(style: .circular))
            .opacity(isEnabled ? 1 : 0.45)
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
