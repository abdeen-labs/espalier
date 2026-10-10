// The commit detail: the header of one commit (or a range), its changed
// files as chips, then the selected file's diff (`DiffContainer`, with its
// own header row). A commit with many files lists them beside the diff
// instead, in a split whose divider is remembered.

import EspalierCore
import GitKit
import SwiftUI

extension EnvironmentValues {
    /// The prefix the detail's inner splits (the files beside the diff)
    /// remember their dividers under; snapshots use their own, so a
    /// divider another test moved doesn't move theirs.
    @Entry var historySplitAutosavePrefix = "Espalier.Split"
}

/// The detail of the selected commit, or of a contiguous range.
struct CommitDetailView: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @Environment(\.historySplitAutosavePrefix) private var autosavePrefix

    var body: some View {
        let history = repository.history
        let selection = history.selection
        let style = HistoryFilesStyle.style(forFileCount: selection.changeset.value?.files.count ?? 0)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.CommitDetail.filesSpacing) {
                if selection.shas.count == 1, let commit = history.commit(selection.shas[0]) {
                    CommitHeader(
                        content: CommitHeaderContent(commit, repository: repository, underlinesLinks: context.app.preferences.underlineLinks),
                        palette: .history(of: repository)
                    )
                    .environment(\.openURL, OpenURLAction { url in
                        context.app.integrations.openInBrowser(url)
                        return .handled
                    })
                } else {
                    RangeSummary(content: RangeSummaryContent(selection: selection, history: history))
                }
                if style == .chips {
                    CommitFiles(repository: repository, style: .chips)
                }
            }
            .padding(.horizontal, Metrics.CommitDetail.horizontalPadding)
            .padding(.top, Metrics.CommitDetail.topPadding)
            .padding(.bottom, Metrics.CommitDetail.bottomPadding)
            Hairline()
            switch style {
            case .chips:
                CommitDiff(repository: repository)
            case .rows:
                SplitView(autosaveName: "\(autosavePrefix).commitFiles", leadingColumn: Metrics.Column.commitFileList) {
                    CommitFiles(repository: repository, style: .rows)
                } trailing: {
                    CommitDiff(repository: repository)
                }
            }
        }
    }
}

/// The selected file's diff, read-only.
private struct CommitDiff: View {
    let repository: RepositoryModel

    var body: some View {
        let selection = repository.history.selection
        if selection.file == nil, let changeset = selection.changeset.value, changeset.files.isEmpty {
            PlaceholderNote("No files changed")
        } else {
            DiffContainer(selection.diff, file: selection.file.map(DiffFileInfo.init), context: .history)
        }
    }
}
