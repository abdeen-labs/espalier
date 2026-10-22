// The selected commits' changed files, beside the diff (HistoryFiles.swift):
// the count, the lines added and removed, and a context menu with Show in
// Finder, Open in the editor, Open with Default App, the two Copy items, and
// View on GitHub, or "File Does Not Exist on Disk".

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// A changed file of a commit, as its row shows it.
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

    /// "3 changed files", the count in `numberFormat`.
    func title(_ numberFormat: NumberFormat) -> String {
        fileCount == 1 ? "1 changed file" : "\(formatCount(fileCount, numberFormat)) changed files"
    }
}

/// The selected commits' changed files, the column beside the diff: their
/// label, then the list (HistoryFiles.swift), or why it isn't there yet.
struct CommitFiles: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        let history = repository.history
        let selection = history.selection
        if let changeset = selection.changeset.value {
            VStack(spacing: 0) {
                CommitFilesHeader(summary: CommitFilesSummary(
                    fileCount: changeset.files.count,
                    linesAdded: changeset.linesAdded,
                    linesDeleted: changeset.linesDeleted
                ))
                Hairline()
                HistoryFileList(
                    files: changeset.files.map { HistoryFileContent($0, in: changeset, numberFormat: numberFormat) },
                    selection: selection.file?.id,
                    actions: actions(changeset),
                    focusRequest: context.state.history.fileListFocusRequest
                )
            }
        } else if let error = selection.changeset.failure {
            CenteredMessage(error.title, systemImage: "exclamationmark.triangle", description: error.message, tint: Color(espalier: Palette.warningMark))
                .fillingSpace()
        } else {
            DelayedProgressView()
        }
    }

    /// Selecting a file shows its diff; opening it opens it in the editor
    /// when it's on disk, and beeps when it isn't (a file the commit
    /// deleted).
    private func actions(_ changeset: ChangesetData) -> HistoryFilesActions {
        let history = repository.history
        func change(_ id: String) -> CommittedFileChange? {
            changeset.files.first { $0.id == id }
        }
        return HistoryFilesActions(
            select: { id in
                history.selectFile(id.flatMap(change))
            },
            open: { id in
                guard let file = change(id) else {
                    return
                }
                let path = POSIXPath.join(repository.record.path, file.path)
                guard FileManager.default.fileExists(atPath: path) else {
                    NSSound.beep()
                    return
                }
                context.actions.perform(.openInEditor(path: path))
            },
            menu: { id in
                guard let file = change(id) else {
                    return nil
                }
                return CommittedFileContextMenu.content(menuContent(for: file), context: context)
            }
        )
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

/// A committed file's context menu, in the pull request screen's file list
/// and History's.
enum CommittedFileContextMenu {
    @MenuBuilder
    static func content(_ content: CommittedFileMenuContent, context: WindowContext) -> MenuContent {
        if content.existsOnDisk {
            context.actions.menuAction(.showInFinder(path: content.fullPath))
            context.actions.menuAction(.openInEditor(path: content.fullPath))
            context.actions.menuAction(.openWithDefaultProgram(path: content.fullPath))
            MenuDivider()
            MenuAction("Copy File Path") {
                copy(content.fullPath)
            }
            MenuAction("Copy Relative File Path") {
                copy(content.relativePath)
            }
            MenuDivider()
            MenuAction(content.gitHubTitle) {
                if let url = content.gitHubURL {
                    context.app.integrations.openInBrowser(url)
                }
            }
            .disabled(content.gitHubURL == nil)
        } else {
            MenuAction("File Does Not Exist on Disk") {}
                .disabled(true)
        }
    }

    private static func copy(_ text: String) {
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
