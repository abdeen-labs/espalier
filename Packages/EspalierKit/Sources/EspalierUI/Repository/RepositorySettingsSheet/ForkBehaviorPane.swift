// Repository Settings' Fork Behavior pane, for forks: "I'll be using this
// fork…", its two choices, and what the choice means
// (`ForkTargetDescription`, which the fork settings step shows too).

import EspalierCore
import SwiftUI

/// The Fork Behavior pane.
struct ForkBehaviorPane: View {
    let content: ForkSettingsContent
    @Binding var target: ForkContributionTarget
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
            FieldLabel("I'll be using this fork…")
            ForkTargetPicker(content: content, target: $target)
            // What the choice means crossfades (0.15 s) to the other
            // repository's.
            ForkTargetDescription(repository: target == .fork ? content.fork : content.parent)
                .contentTransition(motion.animates ? .opacity : .identity)
                .motion(Motion.leave, value: target)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
