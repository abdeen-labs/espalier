// Ported from desktop/app/src/ui/diff/binary-file.tsx
//
// A binary file, which git can't show as text.

import GitKit
import SwiftUI

/// "This binary file has changed" and a button to open it.
struct BinaryDiffView: View {
    /// Opens the file in its default app; nil when it can't be (a deleted
    /// file, or no repository).
    let open: (() -> Void)?

    var body: some View {
        CenteredMessage("This binary file has changed", systemImage: "doc") {
            if let open {
                Button("Open with Default App", action: open)
                    .buttonStyle(.quiet)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
