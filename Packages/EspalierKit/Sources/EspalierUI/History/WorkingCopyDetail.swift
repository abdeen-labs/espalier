// The working copy's detail in History: a read-only summary of the
// uncommitted changes (the files beside the selected file's diff, with
// nothing to stage), and Review Changes (⌘1), which goes to Changes with the
// composer focused.

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// What the working copy's header says.
nonisolated struct WorkingCopyHeaderContent: Sendable, Equatable {
    var summary: WorkingCopySummary
}

/// The working copy's header: what changed, and Review Changes.
struct WorkingCopyHeader: View {
    let content: WorkingCopyHeaderContent
    var reviewChanges: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.insetSmall) {
            VStack(alignment: .leading, spacing: Metrics.CommitDetail.titleSpacing) {
                Text(content.summary.title)
                    .font(Typography.commitSummary)
                    .foregroundStyle(content.summary.isDirty ? .text : .text3)
                if let detail = content.summary.detail {
                    Label {
                        Text(detail)
                    } icon: {
                        if content.summary.conflictedFiles > 0 {
                            WarningGlyph()
                        }
                    }
                    .font(Typography.secondary)
                    .foregroundStyle(.text3)
                }
            }
            Spacer(minLength: Metrics.insetSmall)
            Button(action: reviewChanges) {
                Text("Review Changes")
            }
            .buttonStyle(.quiet)
            .controlSize(.small)
            .tooltip("Review Changes (⌘1)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The working copy's changes, read-only.
struct WorkingCopyDetail: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        let changes = repository.changes
        let files = changes.workingDirectory.files
        let summary = GraphPresentation(repository: repository, place: .history).workingCopy
        VStack(spacing: 0) {
            WorkingCopyHeader(content: WorkingCopyHeaderContent(summary: summary)) {
                context.actions.perform(.reviewChanges)
            }
            .padding(.horizontal, Metrics.CommitDetail.horizontalPadding)
            .padding(.top, Metrics.CommitDetail.topPadding)
            .padding(.bottom, Metrics.CommitDetail.bottomPadding)
            Hairline()
            if files.isEmpty {
                CenteredMessage(
                    "No Local Changes",
                    systemImage: "checkmark",
                    description: "There are no uncommitted changes in this repository.",
                    tint: Color(espalier: Palette.success)
                )
                .fillingSpace()
            } else {
                SplitView(autosaveName: "Espalier.Split.workingCopyFiles", leadingColumn: Metrics.Column.commitFileList) {
                    WorkingCopyFiles(repository: repository)
                } trailing: {
                    WorkingCopyDiff(repository: repository)
                }
            }
        }
    }
}

/// The changed files beside the diff, selectable to see their diff.
private struct WorkingCopyFiles: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        let files = repository.changes.workingDirectory.files
        VStack(spacing: 0) {
            CommitFilesHeader(summary: CommitFilesSummary(fileCount: files.count, linesAdded: 0, linesDeleted: 0))
            Hairline()
            HistoryFileList(
                files: files.map { file in
                    HistoryFileContent(file: CommittedFileRowContent(
                        id: file.id,
                        path: file.path,
                        oldPath: file.status.oldPath,
                        status: FileStatusKind(file.status)
                    ))
                },
                selection: selectedFileID,
                actions: HistoryFilesActions(select: { id in
                    repository.changes.select(fileIDs: id.map { [$0] } ?? [])
                }),
                focusRequest: context.state.history.fileListFocusRequest
            )
        }
    }

    /// The file whose diff shows, when one alone is selected.
    private var selectedFileID: String? {
        if case .workingDirectory(let ids) = repository.changes.selection, ids.count == 1 {
            return ids.first
        }
        return nil
    }
}

/// The selected file's diff, without staging.
private struct WorkingCopyDiff: View {
    let repository: RepositoryModel

    var body: some View {
        let changes = repository.changes
        let file = changes.diffFileID.flatMap { id in changes.workingDirectory.files.first { $0.id == id } }
        DiffContainer(changes.diff, file: file.map(DiffFileInfo.init), context: .changes)
    }
}
