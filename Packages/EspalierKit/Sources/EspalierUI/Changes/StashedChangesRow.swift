// The "Stashed Changes" row at the bottom of the Changes list, shown while
// the current branch has a stash. Like View ▸ Show Stashed Changes (⌃H), it
// shows the branch's stash.

import SwiftUI

/// The row that shows the current branch's stash.
public struct StashedChangesRow: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
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
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.text3)
            }
            .padding(.horizontal, FileRowMetrics.contentInset)
            .frame(height: Metrics.FileList.rowHeight + Metrics.insetSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bare(.rounded(Metrics.Radius.row)))
        .tooltip("Show the changes stashed on this branch")
        .accessibilityLabel("Stashed Changes")
        .accessibilityHint("Shows the changes stashed on this branch")
    }
}
