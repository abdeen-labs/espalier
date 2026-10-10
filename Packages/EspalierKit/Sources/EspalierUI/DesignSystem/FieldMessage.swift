// The line under a form field: a problem with what was typed, a warning, a
// check that passed, or what will happen. Settings has its own
// `InlineMessage`.

import SwiftUI

/// A line under a field. Never color alone: each kind has its own symbol.
public struct FieldMessage: View {
    /// What the line says.
    public enum Kind: Sendable, Equatable {
        /// What was typed can't be used.
        case error
        /// It can be used, but deserves attention.
        case warning
        /// A check passed.
        case success
        /// What will happen.
        case note
    }

    private let text: String
    private let kind: Kind

    public init(_ text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        Label {
            Text(text)
                .foregroundStyle(kind == .error ? Color(espalier: Palette.error) : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            icon
        }
        .font(Typography.subheadline)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Color(espalier: Palette.error))
                .accessibilityLabel("Error")
        case .warning:
            WarningGlyph()
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(espalier: Palette.success))
                .accessibilityLabel("OK")
        case .note:
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
