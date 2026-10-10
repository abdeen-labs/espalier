// The detail when commits that aren't next to each other are selected: no
// diff can be shown, and what can be done instead.

import SwiftUI

/// Commits that aren't next to each other are selected: no diff.
struct NonContiguousView: View {
    var body: some View {
        VStack(spacing: Metrics.insetMedium) {
            IconCircle("square.stack.3d.up.slash", size: Metrics.CommitDetail.placeholderSymbolSize)
                .accessibilityHidden(true)
            Text("Can't Show Changes")
                .font(Typography.heading)
                .foregroundStyle(.text)
            VStack(alignment: .leading, spacing: Metrics.grid) {
                Text("The selected commits aren't next to each other in the history. You can:")
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
                        Text("•")
                            .accessibilityHidden(true)
                        Text(suggestion)
                    }
                }
            }
            .font(Typography.secondary)
            .foregroundStyle(.text2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(Metrics.insetLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The four suggestions.
    static let suggestions = [
        "Select one commit, or a range of adjacent commits, to see their changes.",
        "Drag the commits to a branch in the sidebar to cherry-pick them.",
        "Drag the commits within the history to squash or reorder them.",
        "Control-click the commits for more options.",
    ]
}
