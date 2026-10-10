// The inspector's content. Commit Info shows in History-like places only
// and is hidden by default.

import EspalierCore
import GitKit
import SwiftUI

/// The inspector's content: Commit Info in History-like places.
struct InspectorRouter: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        if let repository = context.repository, repository.isUsable, context.state.place?.showsCommits == true {
            CommitInspector(repository: repository)
        } else {
            PlaceholderNote("No commit selected")
        }
    }
}
