// Repository Settings' Ignored Files pane: the root .gitignore in a
// monospaced editor that fills the pane under the line about it, and the
// link to git's documentation.

import EspalierCore
import SwiftUI

/// The Ignored Files pane.
struct IgnoredFilesPane: View {
    @Binding var text: String
    var isLoaded = true

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetSmall) {
            // The link is git's documentation of .gitignore files.
            Text("The .gitignore file lists untracked files for Git to ignore. Files Git already tracks aren't affected. [Learn more about .gitignore files](https://git-scm.com/docs/gitignore)")
                .font(Typography.secondary)
                .foregroundStyle(.text2)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(Typography.code())
                .scrollContentBackground(.hidden)
                .textAreaSurface()
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Ignored files")
                            .font(Typography.code())
                            .foregroundStyle(.text3)
                            .padding(.horizontal, Metrics.TextArea.horizontalInset + Metrics.TextArea.lineFragmentPadding)
                            .padding(.vertical, Metrics.TextArea.verticalInset)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxHeight: .infinity)
                .disabled(!isLoaded)
                .accessibilityLabel("Ignored files")
                .autocorrectionDisabled(true)
                .writingToolsBehavior(.disabled)
        }
    }
}
