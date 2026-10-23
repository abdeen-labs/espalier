// Changes | History in the middle of the toolbar while the sidebar is
// hidden (its column, or the icons style's rail), so the two places are
// always one click away: a capsule segmented control, Changes with its
// count in SF Mono, neither segment selected in another place (a branch, a
// stash). Conflicts waiting show in Changes' operation panel, and in the
// operation capsule everywhere else.

import EspalierCore
import SwiftUI

/// Changes | History, for the toolbar.
struct PlaceSwitcher: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        let changes = ChangesPlaceRowContent(repository)
        CapsuleSegmentedControl(
            "Place",
            selection: Binding<SidebarPlace?>(
                get: { context.state.place },
                set: { place in
                    if let place {
                        context.select(place)
                    }
                }
            ),
            segments: [
                CapsuleSegment("Changes", systemImage: "plus.forwardslash.minus", value: .changes) {
                    if let badge = changes.badge {
                        Text(badge)
                            .font(Typography.tinyCount)
                            .foregroundStyle(.text3)
                    }
                },
                CapsuleSegment("History", systemImage: "clock.arrow.circlepath", value: .history),
            ]
        )
        .fixedSize()
        // The toolbar measures its item once: a new identity when the count
        // changes makes it measure again.
        .id(changes)
    }
}
