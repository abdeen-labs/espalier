// The line under a field or a row's control, in sheets and in Settings
// alike: a problem with what was typed, a warning, a check that passed, or
// what will happen. It takes the width it's given, so a long message wraps
// in a form's column instead of running past it.

import SwiftUI

/// A line under a field. Never color alone: each kind has its own symbol.
public struct FieldMessage: View {
    /// What the line says.
    nonisolated public enum Kind: Sendable, Equatable {
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
                .foregroundStyle(kind == .error ? Color(espalier: Palette.error) : .text2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            icon
        }
        .font(Typography.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .foregroundStyle(.text2)
                .accessibilityHidden(true)
        }
    }
}
