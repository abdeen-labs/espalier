// The grouped lists of the location control's popovers (the repository
// switcher and the branch switcher) and of the branch picker in sheets: a
// capsule filter field over the rows, each group under its uppercase label,
// and the highlighted row in the soft accent (`selectableRow(isSelected:)`),
// as in the app's other lists.

import SwiftUI

/// A group's label in a grouped list ("Other Branches", an owner): the
/// uppercase section label, in line with its rows' content, and what trails
/// it (a worktree list's New Worktree…). Put the list's row inset around
/// it, as around its rows.
struct ListGroupLabel<Accessory: View>: View {
    private let title: String
    private let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            SectionLabel(title)
            Spacer(minLength: Metrics.grid)
            accessory
        }
        .padding(.horizontal, Metrics.ListRow.horizontalPadding)
        .padding(.top, Metrics.PaletteList.sectionTopPadding)
        .padding(.bottom, Metrics.PaletteList.sectionBottomPadding)
    }
}

extension Metrics {
    /// Grouped lists: the room above and below a group's label.
    public enum PaletteList {
        public static let sectionTopPadding: CGFloat = 10
        public static let sectionBottomPadding: CGFloat = 4
    }
}
