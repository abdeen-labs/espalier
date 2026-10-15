// A list of actions in one card (radius 14): each row a symbol in a soft
// circle, a title and an optional line under it, and its key cap or a
// chevron, with hairlines between rows and a hover wash. Get Started uses
// it.

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

    public init(id: String? = nil, systemImage: String, title: String, subtitle: String? = nil, keyCap: String? = nil, action: @escaping () -> Void) {
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
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Hairline()
                        .padding(.leading, Metrics.ActionList.dividerInset)
                }
                ActionListRow(item: item)
            }
        }
        .padding(Metrics.ActionList.inset)
        .cardSurface()
    }
}

private struct ActionListRow: View {
    let item: ActionListItem
    @State private var isHovered = false

    var body: some View {
        Button(action: item.action) {
            HStack(spacing: Metrics.insetMedium) {
                IconCircle(item.systemImage, size: Metrics.ActionList.iconSize, tint: .accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(Typography.row.weight(.medium))
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
        public static let inset: CGFloat = 6
        public static let rowHeight: CGFloat = 52
        public static let rowPadding: CGFloat = 10
        /// The soft circle's diameter.
        public static let iconSize: CGFloat = 30
        /// A row's chevron without a shortcut.
        public static let chevronSize: CGFloat = 11
        /// Hairlines start where the titles do.
        public static let dividerInset: CGFloat = rowPadding + iconSize + Metrics.insetMedium
    }
}
