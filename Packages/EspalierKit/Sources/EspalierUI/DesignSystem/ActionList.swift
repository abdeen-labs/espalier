// A list of actions in one cream card: each row its symbol in secondary
// text, a title and an optional line under it, and its key cap or a
// chevron, set apart by space, with a hover wash. Get Started uses it.

import AppKit
import SwiftUI

/// One action in an `ActionList`.
public struct ActionListItem: Identifiable {
    public let id: String
    public let systemImage: String
    public let title: String
    public let subtitle: String?
    /// The action's shortcut, shown as a key cap ("⇧⌘O").
    public let keyCap: String?
    public let action: () -> Void

    public init(
        id: String? = nil,
        systemImage: String,
        title: String,
        subtitle: String? = nil,
        keyCap: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id ?? title
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.keyCap = keyCap
        self.action = action
    }
}

/// Actions as rows in one card.
public struct ActionList: View {
    private let items: [ActionListItem]

    public init(_ items: [ActionListItem]) {
        self.items = items
    }

    public var body: some View {
        VStack(spacing: Metrics.ActionList.rowSpacing) {
            ForEach(items) { item in
                ActionListRow(item: item)
            }
        }
        .padding(Metrics.ActionList.inset)
        .surface(Color(espalier: Palette.background), elevation: .card, in: RoundedRectangle(cornerRadius: Metrics.Radius.card, style: .continuous))
    }
}

private struct ActionListRow: View {
    let item: ActionListItem
    @State private var isHovered = false

    var body: some View {
        Button(action: item.action) {
            HStack(spacing: Metrics.insetMedium) {
                Image(systemName: item.systemImage)
                    .font(.system(size: Metrics.ActionList.symbolSize))
                    .foregroundStyle(.text2)
                    .frame(width: Metrics.ActionList.symbolWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(Typography.row.weight(.semibold))
                        .foregroundStyle(.text)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(Typography.meta)
                            .foregroundStyle(.text3)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: Metrics.insetSmall)
                if let keyCap = item.keyCap {
                    KeyCap(keyCap)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: Metrics.ActionList.chevronSize, weight: .semibold))
                        .foregroundStyle(.text3)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Metrics.ActionList.rowPadding)
            .frame(minHeight: Metrics.ActionList.rowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
                    .fill(isHovered ? AnyShapeStyle(Color(espalier: Palette.hover)) : AnyShapeStyle(.clear))
                    .hoverMotion(isHovered)
            )
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
        .onHover { isHovered = $0 }
        .accessibilityHint(item.subtitle ?? "")
    }
}

extension Metrics {
    /// The action list's card.
    public enum ActionList {
        /// Inside the card, around the rows.
        public static let inset: CGFloat = 8
        /// Between rows.
        public static let rowSpacing: CGFloat = 2
        public static let rowHeight: CGFloat = 48
        public static let rowPadding: CGFloat = 10
        /// The symbol's point size, and the column it's centered in.
        public static let symbolSize: CGFloat = 18
        public static let symbolWidth: CGFloat = 24
        /// A row's chevron without a shortcut.
        public static let chevronSize: CGFloat = 11
    }
}
