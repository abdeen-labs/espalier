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
            Form {
                // The label in the form's column; the field is a capsule.
                LabeledContent("Primary Remote Repository (\(remote.name)) URL") {
                    TextField("Primary Remote Repository (\(remote.name)) URL", text: $url, prompt: Text("Remote URL"))
                        .labelsHidden()
                        .autocorrectionDisabled(true)
                }
            }
            .formStyle(.columns)
            .textFieldStyle(.capsule)
        } else {
            SheetCallToAction(systemImage: "icloud.and.arrow.up", message: "Publish your repository to GitHub.") {
                Button("Publish", action: publish)
                    .buttonStyle(.quiet)
            }
        }
    }
}
