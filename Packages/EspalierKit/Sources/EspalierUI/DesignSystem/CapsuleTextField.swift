// Espalier's text fields. A one-line field is a `field` capsule 28 high,
// like the search field, with the accent ring while it has focus; a text
// area (a description, a list of patterns) is the same fill in a rounded
// rectangle.

import AppKit
import CoreText
import SwiftUI

/// A one-line text field as a capsule: the `field` fill, 28 high (26 when
/// small), an optional leading symbol, and the accent ring while it has
/// focus. Works for `TextField` and `SecureField`. Its text is the body
/// font unless the style is given another (a commit ID in SF Mono).
public struct CapsuleTextFieldStyle: TextFieldStyle {
    private let systemImage: String?
    private let font: Font
    private let lineHeight: CGFloat

    /// - Parameters:
    ///   - systemImage: A symbol before the text, in tertiary text (a
    ///     filter's magnifying glass).
    ///   - font: The text's font, a `Typography` role's AppKit twin; nil
    ///     for the body font. The text keeps its line's inset from the
    ///     capsule's top for that font.
    public init(systemImage: String? = nil, font: NSFont? = nil) {
        self.systemImage = systemImage
        self.font = font.map { Font($0 as CTFont) } ?? Typography.row
        self.lineHeight = font.map(Metrics.CapsuleField.measuredLineHeight(for:)) ?? Metrics.CapsuleField.lineHeight
    }

    public func _body(configuration: TextField<Self._Label>) -> some View {
        CapsuleTextFieldBody(systemImage: systemImage, font: font, lineHeight: lineHeight) {
            configuration
        }
    }
}

extension TextFieldStyle where Self == CapsuleTextFieldStyle {
    /// A `field` capsule with the accent ring while it has focus.
    public static var capsule: CapsuleTextFieldStyle { CapsuleTextFieldStyle() }

    /// A `field` capsule with a leading symbol.
    public static func capsule(systemImage: String) -> CapsuleTextFieldStyle {
        CapsuleTextFieldStyle(systemImage: systemImage)
    }

    /// A `field` capsule whose text is in `font` (Go to Commit's ID in SF
    /// Mono: `AppKitTypography.shaField`).
    public static func capsule(font: NSFont) -> CapsuleTextFieldStyle {
        CapsuleTextFieldStyle(font: font)
    }
}

/// The capsule around a field. The ring follows the field's own focus,
/// which callers may also bind with `focused(_:)`.
private struct CapsuleTextFieldBody<Field: View>: View {
    let systemImage: String?
    let font: Font
    let lineHeight: CGFloat
    let field: Field
    @FocusState private var isFocused: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    init(systemImage: String?, font: Font, lineHeight: CGFloat, @ViewBuilder field: () -> Field) {
        self.systemImage = systemImage
        self.font = font
        self.lineHeight = lineHeight
        self.field = field()
    }

    private var height: CGFloat {
        Metrics.ControlHeight.height(for: controlSize)
    }

    var body: some View {
        HStack(spacing: Metrics.ControlHeight.symbolSpacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.text3)
                    .accessibilityHidden(true)
            }
            field
                .textFieldStyle(.plain)
                // AppKit's one-line mode: a pasted line break becomes a
                // space.
                .lineLimit(1)
                .font(font)
                .foregroundStyle(.text)
                .focused($isFocused)
                // The line's inset from the capsule's top, rather than
                // centered: the field draws its text at its own top, so
                // one measured a little taller (as a field can be for a
                // moment) would otherwise draw its text higher.
                .padding(.top, (height - lineHeight) / 2)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, Metrics.ControlHeight.horizontalPadding(for: controlSize))
        .frame(height: height)
        .background(Capsule(style: .circular).fill(.field))
        .fieldRegion()
        .overlay {
            CapsuleFocusRing(isFocused: isFocused)
        }
        .contentShape(Capsule(style: .circular))
        .onTapGesture {
            isFocused = true
        }
        .opacity(isEnabled ? 1 : Palette.disabledOpacity)
    }
}

// MARK: - Text areas

extension View {
    /// A multi-line field's look (a description, ignored files): the
    /// `field` fill in a rounded rectangle (radius 9), the text inset from
    /// its edges. For a `TextEditor`, hide its own background first
    /// (`scrollContentBackground(.hidden)`).
    public func textAreaSurface() -> some View {
        padding(.horizontal, Metrics.TextArea.horizontalInset)
            .padding(.vertical, Metrics.TextArea.verticalInset)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                    .fill(.field)
            )
    }
}

extension Metrics {
    /// One-line fields.
    public enum CapsuleField {
        /// A line of `Typography.row` (body) text, as a field lays it out.
        public static let lineHeight: CGFloat = measuredLineHeight(for: .preferredFont(forTextStyle: .body))

        /// A line of `font`, as a field lays it out.
        public static func measuredLineHeight(for font: NSFont) -> CGFloat {
            ceil(NSLayoutManager().defaultLineHeight(for: font))
        }
    }

    /// Multi-line fields.
    public enum TextArea {
        /// The text's inset from the field's sides.
        public static let horizontalInset: CGFloat = 7
        /// The text's inset from its top and bottom.
        public static let verticalInset: CGFloat = 6
        /// A text view's own inset before its text (AppKit's line fragment
        /// padding), for a placeholder drawn over it.
        public static let lineFragmentPadding: CGFloat = 5
    }
}
