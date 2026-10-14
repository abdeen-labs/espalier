// The frame Espalier's sheets share: the title and an optional line under
// it, the content, and the buttons, on the flat `background`. Cancel is a
// secondary capsule, the default button the prominent one. `ModalPresenter`
// shows it in a card on the window's modal layer, named by the title for
// VoiceOver.

import AppKit
import SwiftUI

extension Metrics.Sheet {
    /// Around a sheet's content.
    public static let padding: CGFloat = 20
    /// Between the title, the content, and the buttons.
    public static let spacing: CGFloat = 16
    /// Between the title and the line under it.
    public static let titleSpacing: CGFloat = 4
    /// Between groups inside the content (a field and its label, choices).
    public static let groupSpacing: CGFloat = 6
}

extension Typography {
    /// A sheet's or a welcome step's title (15, semibold).
    public static var sheetTitle: Font { sans(.title3, weight: .semibold) }
    /// A label above a field or a group in a sheet (12, medium, secondary
    /// text).
    public static var fieldLabel: Font { sans(.callout, weight: .medium) }
    /// The welcome flow's and Get Started's headings (26, bold).
    public static var welcomeTitle: Font { sans(.largeTitle, weight: .bold) }
}

/// A sheet: its title, an optional line under it, the content, and a row
/// of buttons at the bottom right.
///
/// Put `SheetButtons` in the button row for Cancel and a default button,
/// or capsule buttons of your own (`.secondary` for Cancel, `.prominent`
/// for the default, `.quiet` for the rest), with a `Spacer` before any
/// that belong on the left.
public struct SheetScaffold<Content: View, Buttons: View>: View {
    private let title: String
    private let message: String?
    private let width: CGFloat?
    private let content: Content
    private let buttons: Buttons

    /// - Parameters:
    ///   - message: A line under the title, in secondary text.
    ///   - width: The sheet's width; nil sizes it to its content.
    public init(
        _ title: String,
        message: String? = nil,
        width: CGFloat? = Metrics.Sheet.standardWidth,
        @ViewBuilder content: () -> Content,
        @ViewBuilder buttons: () -> Buttons
    ) {
        self.title = title
        self.message = message
        self.width = width
        self.content = content()
        self.buttons = buttons()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Sheet.spacing) {
            VStack(alignment: .leading, spacing: Metrics.Sheet.titleSpacing) {
                Text(title)
                    .font(Typography.sheetTitle)
                    .foregroundStyle(.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(Typography.row)
                        .foregroundStyle(.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack(spacing: Metrics.insetSmall) {
                buttons
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, Metrics.grid)
        }
        .padding(Metrics.Sheet.padding)
        .frame(width: width, alignment: .leading)
        .background(Color(espalier: Palette.background))
        .modalTitle(title)
    }
}

/// A sheet's Cancel and default buttons: a spinner on the left while the
/// sheet works, Cancel as a secondary capsule (Escape), and the default
/// button as the prominent one (Return), disabled while the sheet works.
public struct SheetButtons: View {
    private let confirmTitle: String
    private let confirmRole: ButtonRole?
    private let cancelTitle: String
    private let isConfirmDisabled: Bool
    private let confirmHelp: String?
    private let isWorking: Bool
    private let cancel: () -> Void
    private let confirm: () -> Void

    /// - Parameters:
    ///   - confirmRole: The default button's role (destructive for a
    ///     deletion).
    ///   - confirmHelp: The default button's tooltip.
    public init(
        _ confirmTitle: String,
        confirmRole: ButtonRole? = nil,
        cancelTitle: String = "Cancel",
        isConfirmDisabled: Bool = false,
        confirmHelp: String? = nil,
        isWorking: Bool = false,
        cancel: @escaping () -> Void,
        confirm: @escaping () -> Void
    ) {
        self.confirmTitle = confirmTitle
        self.confirmRole = confirmRole
        self.cancelTitle = cancelTitle
        self.isConfirmDisabled = isConfirmDisabled
        self.confirmHelp = confirmHelp
        self.isWorking = isWorking
        self.cancel = cancel
        self.confirm = confirm
    }

    public var body: some View {
        if isWorking {
            ArcProgress(.small)
        }
        Spacer(minLength: 0)
        Button(cancelTitle, role: .cancel, action: cancel)
            .buttonStyle(.secondary)
            .keyboardShortcut(.cancelAction)
        Button(confirmTitle, role: confirmRole, action: confirm)
            .buttonStyle(.prominent)
            .keyboardShortcut(.defaultAction)
            .disabled(isConfirmDisabled || isWorking)
            .tooltip(confirmHelp)
    }
}

/// A label above a field or a group in a sheet: 12, medium, in secondary
/// text.
public struct FieldLabel: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(Typography.fieldLabel)
            .foregroundStyle(.text2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// A list inside a sheet: the sheet's background in a card's shape with
    /// a 1-point ring, the rows `Metrics.SheetList.inset` in from its top and
    /// bottom, so a row scrolled under an edge is cut at the card's edge.
    public func sheetListCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
        return padding(.vertical, Metrics.SheetList.inset)
            .background(Color(espalier: Palette.background))
            .clipShape(shape)
            .overlay(shape.strokeBorder(.line, lineWidth: 1))
    }
}
