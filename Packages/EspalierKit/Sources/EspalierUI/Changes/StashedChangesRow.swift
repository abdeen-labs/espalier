// The "Stashed Changes" row at the bottom of the Changes list, shown while
// the current branch has a stash, with how many when it has more than one.
// Like View ▸ Show Stashed Changes (⌃H), it shows the branch's newest stash.

import SwiftUI

/// The row that shows the current branch's newest stash.
public struct StashedChangesRow: View {
    /// How many stashes the current branch has.
    private let count: Int
    private let action: () -> Void
    @Environment(\.numberFormat) private var numberFormat

    public init(count: Int, action: @escaping () -> Void) {
        self.count = count
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: FileRowMetrics.spacing) {
                Image(systemName: "tray.full")
                    .foregroundStyle(.text2)
                    .frame(width: Metrics.Checkbox.size)
                Text("Stashed Changes")
                    .font(Typography.row.weight(.medium))
                    .foregroundStyle(.text)
                Spacer(minLength: Metrics.insetSmall)
                if count > 1 {
                    Text(formatCount(count, numberFormat))
                        .font(Typography.count)
                        .foregroundStyle(.text3)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.text3)
            }
            .padding(.horizontal, FileRowMetrics.contentInset)
            .frame(height: Metrics.FileList.rowHeight + Metrics.insetSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
        .tooltip(count > 1 ? "Show the newest changes stashed on this branch" : "Show the changes stashed on this branch")
        .accessibilityLabel(count > 1 ? "Stashed Changes, \(formatCount(count, numberFormat)) stashes" : "Stashed Changes")
        .accessibilityHint(count > 1 ? "Shows the newest changes stashed on this branch" : "Shows the changes stashed on this branch")
    }
}
