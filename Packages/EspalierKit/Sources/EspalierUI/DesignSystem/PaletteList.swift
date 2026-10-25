// The grouped lists of the location control's popovers (the repository
// switcher and the branch switcher), of the branch picker and the clone
// list in sheets, and of Keyboard Shortcuts: a capsule filter field over the
// rows, each group under its label (its mark in the rows' glyph column, if
// it has one, and its title as written), and the highlighted row in the
// soft accent (`selectableRow(isSelected:)`), as in the app's other lists.

import GitHubKit
import SwiftUI

/// What leads a group's label, in its rows' glyph column.
nonisolated enum ListGroupMark: Sendable, Equatable {
    /// An owner's avatar.
    case owner(AvatarUser)
    /// A symbol: the worktrees', Recent's, a host's, Other Branches'.
    case symbol(String)
}

/// A group's label in a grouped list (an owner, "Other Branches", a menu):
/// its mark in the rows' glyph column, its title as written (an owner's
/// login keeps its case), and what trails it (a worktree list's New
/// Worktree…). Put the list's row inset around it, as around its rows.
struct ListGroupLabel<Accessory: View>: View {
    private let title: String
    private let mark: ListGroupMark?
    private let accessory: Accessory

    /// - Parameter mark: What leads the label; nil for a list whose rows
    ///   have no glyph column.
    init(_ title: String, mark: ListGroupMark? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.mark = mark
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            if let mark {
                Group {
                    switch mark {
                    case .owner(let owner):
                        Avatar(owner, size: Metrics.PaletteList.markAvatarSize)
                    case .symbol(let systemImage):
                        Image(systemName: systemImage)
                            .font(Typography.secondary)
                            .foregroundStyle(.text3)
                    }
                }
                .frame(width: Metrics.Sidebar.glyphSize, alignment: .center)
                .accessibilityHidden(true)
            }
            Text(title)
                .font(Typography.secondary.weight(.semibold))
                .foregroundStyle(.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Metrics.grid)
            accessory
        }
        .frame(minHeight: Metrics.PaletteList.labelHeight)
        .padding(.horizontal, Metrics.ListRow.horizontalPadding)
        .padding(.top, Metrics.PaletteList.groupSpacing)
    }
}

extension Metrics {
    /// Grouped lists: a group's label and the room above it, and an owner's
    /// avatar in it; the room above and below a sidebar's section label in
    /// a list (Acknowledgements).
    public enum PaletteList {
        public static let labelHeight: CGFloat = 24
        public static let groupSpacing: CGFloat = 8
        public static let markAvatarSize: CGFloat = 18
        public static let sectionTopPadding: CGFloat = 10
        public static let sectionBottomPadding: CGFloat = 4
    }
}
