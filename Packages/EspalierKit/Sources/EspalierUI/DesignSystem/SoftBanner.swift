// A friendly banner: a soft card in a faint tint of its color, its symbol
// in the color (or another mark, such as the arc while work runs), the
// message, and an action at its end. The composer's warnings, hook line,
// AI failure, and amend note, and the Changes list's note about hidden
// files, are banners.

import AppKit
import SwiftUI

/// A soft banner: its mark, its message, and its action.
public struct SoftBanner<Mark: View, Message: View, Accessory: View>: View {
    private let color: NSColor
    private let mark: Mark
    private let message: Message
    private let accessory: Accessory

    /// - Parameters:
    ///   - color: The banner's color: its tint fills the banner.
    ///   - mark: What leads the banner (`SoftBannerSymbol` for a symbol).
    ///   - message: The banner's text.
    ///   - accessory: What follows the text: its action, if any.
    public init(
        color: NSColor,
        @ViewBuilder mark: () -> Mark,
        @ViewBuilder message: () -> Message,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.color = color
        self.mark = mark()
        self.message = message()
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Metrics.SoftBanner.spacing) {
            mark
                .frame(width: Metrics.SoftBanner.mark, height: Metrics.SoftBanner.mark)
            message
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(.leading, Metrics.SoftBanner.leadingPadding)
        .padding(.trailing, Metrics.SoftBanner.trailingPadding)
        .padding(.vertical, Metrics.SoftBanner.verticalPadding)
        .frame(minHeight: Metrics.SoftBanner.minimumHeight)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous)
                .fill(Color(nsColor: Palette.tint(color, light: Metrics.SoftBanner.tint.light, dark: Metrics.SoftBanner.tint.dark)))
        )
    }
}

extension SoftBanner where Accessory == EmptyView {
    /// A banner without an action.
    public init(color: NSColor, @ViewBuilder mark: () -> Mark, @ViewBuilder message: () -> Message) {
        self.init(color: color, mark: mark, message: message) { EmptyView() }
    }
}

/// A banner's symbol, in its color.
public struct SoftBannerSymbol: View {
    private let systemImage: String
    private let color: NSColor

    public init(_ systemImage: String, color: NSColor) {
        self.systemImage = systemImage
        self.color = color
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: Metrics.SoftBanner.symbolSize, weight: .semibold))
            .foregroundStyle(Color(nsColor: color))
            .accessibilityHidden(true)
    }
}

extension Metrics {
    /// Soft banners.
    public enum SoftBanner {
        /// The mark's room, and its symbol's point size.
        public static let mark: CGFloat = 18
        public static let symbolSize: CGFloat = 14
        /// Between the mark, the message, and the action.
        public static let spacing: CGFloat = 10
        public static let leadingPadding: CGFloat = 9
        public static let trailingPadding: CGFloat = 8
        public static let verticalPadding: CGFloat = 7
        public static let minimumHeight: CGFloat = 40
        /// The fill's alpha, light and dark.
        public static let tint: (light: CGFloat, dark: CGFloat) = (0.12, 0.2)
    }
}
