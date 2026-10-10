// Repository Settings' Remote pane: the primary remote's URL, or, without a
// remote, Publish.

import EspalierCore
import GitKit
import SwiftUI

/// The Remote pane.
struct RemotePane: View {
    let remote: Remote?
    @Binding var url: String
    var publish: () -> Void = {}

    var body: some View {
        if let remote {
            VStack(alignment: .leading, spacing: Metrics.Sheet.groupSpacing) {
                FieldLabel("Primary Remote Repository (\(remote.name)) URL")
                TextField("Primary Remote Repository (\(remote.name)) URL", text: $url, prompt: Text("Remote URL"))
                    .textFieldStyle(.capsule)
                    .labelsHidden()
                    .autocorrectionDisabled(true)
            }
        } else {
            VStack(spacing: Metrics.insetMedium) {
                IconCircle("icloud.and.arrow.up", size: 36)
                Text("Publish your repository to GitHub.")
                    .foregroundStyle(.text2)
                Button("Publish", action: publish)
                    .buttonStyle(.quiet)
            }
            .frame(maxWidth: .infinity)
            .padding(Metrics.insetLarge)
        }
    }
}
