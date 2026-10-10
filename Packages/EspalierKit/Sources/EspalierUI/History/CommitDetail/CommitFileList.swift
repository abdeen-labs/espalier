// The selected commits' changed files, as chips over the diff or, for many
// files, rows beside it (HistoryFiles.swift): the count, the lines added
// and removed, and a context menu with Show in Finder, Open in the editor,
// Open with Default App, the two Copy items, and View on GitHub, or "File
// Does Not Exist on Disk".

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// A changed file of a commit, as its chip or row shows it.
nonisolated struct CommittedFileRowContent: Sendable, Equatable, Identifiable {
    var id: String
    var path: String
    /// A rename's or copy's old path.
    var oldPath: String?
    var status: FileStatusKind

    init(id: String, path: String, oldPath: String? = nil, status: FileStatusKind) {
        self.id = id
        self.path = path
        self.oldPath = oldPath
        self.status = status
    }

    init(_ file: CommittedFileChange) {
        self.init(id: file.id, path: file.path, oldPath: file.status.oldPath, status: FileStatusKind(file.status))
    }

    var fileName: String {
        POSIXPath.basename(path)
    }

    var directory: String {
        let directory = POSIXPath.dirname(path)
        return directory == "." ? "" : directory
    }

    /// The tooltip: the path, or "old → new" for a rename.
    var tooltip: String {
        oldPath.map { "\($0) → \(path)" } ?? path
    }
}

/// What the files' label says.
nonisolated struct CommitFilesSummary: Sendable, Equatable {
    var fileCount: Int
    var linesAdded: Int
    var linesDeleted: Int

    /// "3 changed files".
    var title: String {
        fileCount == 1 ? "1 changed file" : "\(formatCount(fileCount)) changed files"
    }
}

/// The selected commits' changed files: their label and chips, or rows
/// (`style`). The chips' layout and the diff below them are
/// `CommitDetailView`'s.
struct CommitFiles: View {
    let repository: RepositoryModel
    let style: HistoryFilesStyle
    @Environment(WindowContext.self) private var context

    var body: some View {
        let history = repository.history
        let selection = history.selection
        if let changeset = selection.changeset.value {
            let summary = CommitFilesSummary(fileCount: changeset.files.count, linesAdded: changeset.linesAdded, linesDeleted: changeset.linesDeleted)
            VStack(alignment: .leading, spacing: style == .chips ? Metrics.insetSmall : 0) {
                CommitFilesHeader(summary: summary)
                    .padding(.horizontal, style == .rows ? Metrics.HistoryHeader.horizontalPadding : 0)
                    .frame(height: style == .rows ? Metrics.HistoryHeader.height : nil)
                if style == .rows {
                    Hairline()
                }
                if !changeset.files.isEmpty {
                    HistoryFiles(
                        files: changeset.files.map { HistoryFileContent($0, in: changeset) },
                        selection: selection.file?.id,
                        style: style,
                        actions: HistoryFilesActions(
                            select: { id in
                                history.selectFile(id.flatMap { id in changeset.files.first { $0.id == id } })
                            },
                            open: { id in
                                if let file = changeset.files.first(where: { $0.id == id }) {
                                    context.actions.perform(.openInEditor(path: POSIXPath.join(repository.record.path, file.path)))
                                }
                            }
                        ),
                        focusRequest: context.state.history.fileListFocusRequest
                    ) { file in
                        if let change = changeset.files.first(where: { $0.id == file.id }) {
                            CommittedFileContextMenu(content: menuContent(for: change))
                        }
                    }
                }
            }
        } else if let error = selection.changeset.failure {
            Label {
                Text(error.title)
                    .foregroundStyle(.text2)
            } icon: {
                WarningGlyph()
            }
            .font(Typography.secondary)
            .help(error.message)
        } else if selection.changeset.isLoading {
            DelayedProgressView()
                .controlSize(.small)
                .frame(height: Metrics.ControlHeight.regular)
        }
    }

    private func menuContent(for file: CommittedFileChange) -> CommittedFileMenuContent {
        let history = repository.history
        let shas = history.selection.shas
        let pushed = shas.count == 1 ? shas.first.flatMap { history.isLocalCommit($0) ? nil : $0 } : nil
        return CommittedFileMenuContent(file, repositoryPath: repository.record.path, commit: pushed, in: repository.record.gitHubRepository)
    }
}

/// What a committed file's context menu acts on.
nonisolated struct CommittedFileMenuContent: Sendable, Equatable {
    var fullPath: String
    var relativePath: String
    var existsOnDisk: Bool
    /// The file in the commit on GitHub, when the commit was pushed to a
    /// GitHub repository.
    var gitHubURL: URL?
    var gitHubTitle: String
}

extension CommittedFileMenuContent {
    /// The menu for `file` of the repository at `repositoryPath`, with View
    /// on GitHub at `commit` (a pushed commit; nil disables it) in
    /// `gitHubRepository`.
    init(_ file: CommittedFileChange, repositoryPath: String, commit: String?, in gitHubRepository: GitHubRepository?) {
        let path = POSIXPath.join(repositoryPath, file.path)
        self.init(
            fullPath: path,
            relativePath: file.path,
            existsOnDisk: FileManager.default.fileExists(atPath: path),
            gitHubURL: gitHubRepository.flatMap { gitHubRepository in
                commit.flatMap { GitHubWebURLs.commit($0, in: gitHubRepository, filePath: file.path) }
            },
            gitHubTitle: GitHubLabels.viewOnGitHub(gitHubRepository?.endpoint)
        )
    }
}

/// A committed file's context menu.
struct CommittedFileContextMenu: View {
    let content: CommittedFileMenuContent
    @Environment(WindowContext.self) private var context

    var body: some View {
        if content.existsOnDisk {
            ActionButton(.showInFinder(path: content.fullPath))
            ActionButton(.openInEditor(path: content.fullPath))
            ActionButton(.openWithDefaultProgram(path: content.fullPath))
            Divider()
            Button("Copy File Path") {
                copy(content.fullPath)
            }
            Button("Copy Relative File Path") {
                copy(content.relativePath)
            }
            Divider()
            Button(content.gitHubTitle) {
                if let url = content.gitHubURL {
                    context.app.integrations.openInBrowser(url)
                }
            }
            .disabled(content.gitHubURL == nil)
        } else {
            Button("File Does Not Exist on Disk") {}
                .disabled(true)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Labels for GitHub pages.
nonisolated enum GitHubLabels {
    /// "View on GitHub", or "View on GitHub Enterprise" for another
    /// endpoint.
    static func viewOnGitHub(_ endpoint: String?) -> String {
        guard let endpoint, !isDotCom(endpoint) else {
            return "View on GitHub"
        }
        return "View on GitHub Enterprise"
    }
}
