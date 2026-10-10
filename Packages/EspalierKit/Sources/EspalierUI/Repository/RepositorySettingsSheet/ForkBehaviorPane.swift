// Repository Settings' Fork Behavior pane, for forks: "I'll be using this
// fork…", its two choices, and what the choice means
// (`ForkTargetDescription`, which the fork settings step shows too).

import EspalierCore
import SwiftUI

/// The Fork Behavior pane.
struct ForkBehaviorPane: View {
    let content: ForkSettingsContent
    @Binding var target: ForkContributionTarget

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
            FieldLabel("I'll be using this fork…")
            ForkTargetPicker(content: content, target: $target)
            ForkTargetDescription(repository: target == .fork ? content.fork : content.parent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
