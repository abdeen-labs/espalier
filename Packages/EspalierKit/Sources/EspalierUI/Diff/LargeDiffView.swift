// Ported from desktop/app/src/ui/diff/index.tsx
//
// Diffs too large to show by default, and too large to show at all.

import GitKit
import SwiftUI

/// A diff too large to show by default, with Show Diff.
struct LargeDiffView: View {
    let showDiff: () -> Void

    var body: some View {
        CenteredMessage(
            "This diff is too large to show automatically.",
            systemImage: "doc.text.magnifyingglass",
            description: "You can show it anyway, but Espalier may slow down."
        ) {
            Button("Show Diff", action: showDiff)
                .buttonStyle(.quiet)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A diff too large to show (over 70 MB).
struct UnrenderableDiffView: View {
    var body: some View {
        CenteredMessage("This diff is too large to show.", systemImage: "doc.text.magnifyingglass")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
