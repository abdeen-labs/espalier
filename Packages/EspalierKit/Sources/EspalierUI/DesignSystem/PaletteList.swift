// The palette look of the location control's popovers: a search field
// across the top with a hairline under it, uppercase section labels, and
// rows with radius 11, the highlighted one filled with the accent (one of
// the two places a row is solid blue, with menus). Rows read
// `backgroundProminence` to turn their text white on the accent.

import AppKit
import SwiftUI

/// A palette's search field: a symbol, the field at 15 points, and a key
/// cap (Escape closes the popover), across the top of the palette with a
/// hairline under it. Bind its focus with `focused(_:)`.
public struct PaletteSearchField: View {
    private let prompt: String
    private let systemImage: String
    private let keyCap: String?
    @Binding private var text: String

    /// - Parameter keyCap: A hint on the right ("esc").
    public init(_ prompt: String, text: Binding<String>, systemImage: String = "magnifyingglass", keyCap: String? = "esc") {
        self.prompt = prompt
        _text = text
        self.systemImage = systemImage
        self.keyCap = keyCap
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.PaletteList.fieldSpacing) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.text2)
                    .accessibilityHidden(true)
                TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(.text3))
                    .textFieldStyle(.plain)
                    // AppKit's one-line mode: a pasted line break becomes a
                    // space.
                    .lineLimit(1)
                    .font(Typography.paletteField)
                    .foregroundStyle(.text)
                if let keyCap {
                    KeyCap(keyCap)
                }
            }
            .padding(.horizontal, Metrics.PaletteList.fieldHorizontalPadding)
            .frame(height: Metrics.PaletteList.fieldHeight)
            Hairline()
        }
    }
}

extension Typography {
    /// A palette's search field (15).
    public static let paletteField: Font = .title3
}

extension View {
    /// A palette row: padded, at least 32 high, radius 11, filled with the
    /// accent while highlighted (its content then sees an increased
    /// `backgroundProminence`).
    public func paletteRow(isHighlighted: Bool) -> some View {
        modifier(PaletteRowModifier(isHighlighted: isHighlighted))
    }
}

private struct PaletteRowModifier: ViewModifier {
    let isHighlighted: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.backgroundProminence, isHighlighted ? .increased : .standard)
            .padding(.horizontal, Metrics.PaletteList.rowHorizontalPadding)
            .frame(minHeight: Metrics.PaletteList.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.pickerRow, style: .continuous)
                    .fill(isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.Radius.pickerRow, style: .continuous))
    }
}

/// Text colors for a row that may sit on the accent: primary, secondary,
/// and tertiary text, white (or white faded) on the accent.
public struct PaletteRowColors {
    private let onAccent: Bool

    public init(_ prominence: BackgroundProminence) {
        onAccent = prominence == .increased
    }

    public var primary: Color { onAccent ? .white : .text }
    public var secondary: Color { onAccent ? .white.opacity(0.85) : .text2 }
    public var tertiary: Color { onAccent ? .white.opacity(0.75) : .text3 }
    /// A mark in its own color (a branch's dot, an ahead count), white on
    /// the accent.
    public func mark(_ color: Color) -> Color { onAccent ? .white : color }
    /// A small tag's fill ("current", a count): `field`, or white at 20% on
    /// the accent.
    public var tagFill: Color { onAccent ? .white.opacity(0.2) : .field }
}

extension Metrics {
    /// The palette popovers.
    public enum PaletteList {
        /// The search field's row.
        public static let fieldHeight: CGFloat = 48
        public static let fieldHorizontalPadding: CGFloat = 16
        public static let fieldSpacing: CGFloat = 10
        /// Rows.
        public static let rowHeight: CGFloat = 32
        public static let rowHorizontalPadding: CGFloat = 10
        /// The rows' inset from the popover's edges.
        public static let inset: CGFloat = 8
        /// A section label's padding above its rows.
        public static let sectionTopPadding: CGFloat = 10
        public static let sectionBottomPadding: CGFloat = 4
    }
}
