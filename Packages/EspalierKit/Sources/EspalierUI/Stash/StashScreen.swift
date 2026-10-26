// A stash entry's place: a header as high as the diff's with the title,
// Restore, Apply, and Discard…; the stash's files in the Changes table's
// rows, without checkboxes; under them the branch (or git's message), the
// count, and what Restore and Apply do; and the selected file's read-only
// diff. Any entry shows, and restores or applies onto the current working
// directory. The toolbar search filters the files; when it hides the
// selected file, the first file it lists is selected, or none when it lists
// none (`filteredSelection`).
//
// The stash shows through `StashModel` (`stash.show`, which also takes the
// Changes list's selection to the stash), and leaving the place goes back
// to the working directory (`stash.hide`).

import AppKit
import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// How many files, in words.
nonisolated enum StashFilesSummary {
    /// "1 file", "4 files", the count in `numberFormat`.
    static func files(_ count: Int, _ numberFormat: NumberFormat) -> String {
        count == 1 ? "1 file" : "\(formatCount(count, numberFormat)) files"
    }
}

/// What the stash's column shows.
nonisolated struct StashColumnContent: Sendable, Equatable {
    /// The stash's files.
    enum Files: Sendable, Equatable {
        case loading
        /// The files matching the filter, and how many the stash has.
        case loaded([CommittedFileChange], total: Int)
        case failed(title: String, message: String)
    }

    /// The SHA of the entry's commit.
    var sha: String
    /// The branch in the entry's marker, or nil for an entry made outside
    /// Espalier and GitHub Desktop.
    var branch: String?
    /// Git's message for the entry ("On main: fix login").
    var message: String
    var files: Files
    var canRestore: Bool
    var canApply: Bool
    var canDiscard: Bool
    /// Why Restore and Apply are disabled, when something says.
    var applyRefusal: String?
    /// Restoring, applying, or discarding it.
    var isBusy: Bool
    /// The toolbar search's text.
    var filter: String
    /// The selected file.
    var selectedFileID: String?

    /// "On main · 4 files" ("On main" until the files load): the branch in
    /// the entry's marker or git's message, else git's message, the count
    /// in `numberFormat`.
    func subtitle(_ numberFormat: NumberFormat) -> String {
        let origin = (branch ?? StashEntry.branch(inMessage: message)).map { "On \($0)" } ?? message
        if case .loaded(_, let total) = files {
            return "\(origin) · \(StashFilesSummary.files(total, numberFormat))"
        }
        return origin
    }

    /// What Restore and Apply do.
    static let explanation = "Restore will move your stashed files to the Changes list. Apply will copy them there and keep the stash."

    /// The stash's files matching `filter` (its path, ignoring case).
    static func files(_ files: [CommittedFileChange], filter: String) -> [CommittedFileChange] {
        files.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }
    }
}

/// The stash's header, as high as the diff's: the title, when there's room
/// for it, then Restore, Apply, and Discard….
struct StashHeader: View {
    let content: StashColumnContent
    var restore: @MainActor () -> Void = {}
    var apply: @MainActor () -> Void = {}
    var discard: @MainActor () -> Void = {}

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            // Shown whole or not at all: a narrow column leaves the room to
            // the buttons.
            ViewThatFits(in: .horizontal) {
                Text("Stashed Changes")
                    .font(Typography.row.weight(.semibold))
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                Color.clear
                    .frame(width: 0, height: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if content.isBusy {
                ArcProgress(.small)
                    .accessibilityLabel("Working")
            }
            Button("Restore", action: restore)
                .buttonStyle(.prominent)
                .disabled(!content.canRestore)
                .tooltip((content.canRestore ? nil : content.applyRefusal) ?? "Move your stashed files to the Changes list")
                .fixedSize()
            Button("Apply", action: apply)
                .buttonStyle(.quiet)
                .disabled(!content.canApply)
                .tooltip((content.canApply ? nil : content.applyRefusal) ?? "Copy your stashed files to the Changes list and keep the stash")
                .fixedSize()
            Button("Discard…", action: discard)
                .buttonStyle(.quiet)
                .disabled(!content.canDiscard)
                .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, FileRowMetrics.contentInset)
        .frame(height: Metrics.PaneHeader.height)
    }
}

/// Under the stash's files: the branch (or git's message) and the count,
/// and what Restore and Apply do.
struct StashFooter: View {
    let content: StashColumnContent
    @Environment(\.numberFormat) private var numberFormat

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.grid / 2) {
            Text(content.subtitle(numberFormat))
                .font(Typography.meta)
                .foregroundStyle(.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(StashColumnContent.explanation)
                .font(Typography.meta)
                .foregroundStyle(.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FileRowMetrics.contentInset)
        .padding(.vertical, Metrics.insetSmall)
        .accessibilityElement(children: .combine)
    }
}

/// The stash's column: the header over its files, and the footer.
struct StashColumn: View {
    let content: StashColumnContent
    var restore: @MainActor () -> Void = {}
    var apply: @MainActor () -> Void = {}
    var discard: @MainActor () -> Void = {}
    var select: @MainActor (String?) -> Void = { _ in }
    var open: @MainActor (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            StashHeader(content: content, restore: restore, apply: apply, discard: discard)
            Hairline()
            files
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            StashFooter(content: content)
        }
        .background(Color(espalier: Palette.pane))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var files: some View {
        switch content.files {
        case .loading:
            DelayedProgressView()
        case .failed(let title, let message):
            CenteredMessage(title, systemImage: "exclamationmark.triangle", description: message, tint: Color(espalier: Palette.warningMark))
        case .loaded(let rows, _) where rows.isEmpty && !content.filter.isEmpty:
            CenteredMessage("No Matching Files", systemImage: "magnifyingglass", description: "No stashed files match “\(content.filter)”.")
        case .loaded(let rows, _):
            // The Changes table's rows, read-only: one file selected at a
            // time, Return or a double-click opens it, ⌘C copies its path.
            FileTable(
                files: .readOnly(rows),
                selectedIDs: content.selectedFileID.map { [$0] } ?? [],
                allowsMultipleSelection: false,
                tableLabel: "Stashed files",
                scope: FileTableScope(filter: FileListFilter(text: content.filter), source: content.sha),
                actions: FileTableActions(
                    select: { ids in select(ids.first) },
                    open: { ids in
                        if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                            open(row.path)
                        }
                    },
                    copy: { ids in Self.copyPaths(of: rows.filter { ids.contains($0.id) }) }
                )
            )
        }
    }

    /// Copies the files' paths in the repository, one per line.
    private static func copyPaths(of files: [CommittedFileChange]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(files.map { POSIXPath.normalize($0.path) }.joined(separator: "\n"), forType: .string)
    }
}

/// A stash entry, by its commit's SHA.
public struct StashScreen: View {
    private let repository: RepositoryModel
    private let sha: String
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel, sha: String) {
        self.repository = repository
        self.sha = sha
    }

    public var body: some View {
        Group {
            if entry != nil {
                SplitView(.stash) {
                    StashColumn(
                        content: content,
                        restore: { context.actions.perform(.restoreStash(sha: sha)) },
                        apply: { context.actions.perform(.applyStash(sha: sha)) },
                        discard: { context.actions.perform(.discardStash(sha: sha)) },
                        select: selectFile,
                        open: openFile
                    )
                } trailing: {
                    if isShowingThisStash {
                        DiffContainer(repository.stash.diff, file: repository.stash.selectedFile.map(DiffFileInfo.init), context: .stash)
                    } else {
                        DiffContainer(.idle, file: nil, context: .stash)
                    }
                }
            } else {
                // Restored or discarded elsewhere (or still loading after a
                // worktree switch): it shows again if it comes back.
                CenteredMessage("No Stashed Changes", systemImage: "tray", description: "These stashed changes are no longer in the stash list.")
                    .fillingSpace()
                    .paneCard()
            }
        }
        .onAppear(perform: showStash)
        .onChange(of: entry?.stashSha) {
            showStash()
        }
        .onChange(of: searchedFileIDs, initial: true) {
            selectSearchedFile()
        }
        .onChange(of: repository.stash.isShowing) {
            // A checkout goes back to the working directory; this place
            // still shows the stash.
            if !repository.stash.isShowing {
                showStash()
            }
        }
        .onDisappear {
            repository.stash.hide()
        }
    }

    /// Opens a stashed file's working copy in the editor. A file stashed
    /// as new or deleted may have none: then nothing opens, with a beep.
    private func openFile(_ path: String) {
        let target = POSIXPath.join(repository.record.path, path)
        guard FileManager.default.fileExists(atPath: target) else {
            NSSound.beep()
            return
        }
        context.actions.perform(.openInEditor(path: target))
    }

    /// The entry, while it's listed.
    private var entry: StashEntry? {
        repository.gitState.stashes.entry(sha)
    }

    /// Whether the model shows this entry.
    private var isShowingThisStash: Bool {
        guard let entry, let shown = repository.stash.shownEntry else {
            return false
        }
        return shown.stashSha == entry.stashSha && repository.stash.isShowing
    }

    private var content: StashColumnContent {
        let stash = repository.stash
        let filter = context.state.searchText
        let files: StashColumnContent.Files
        if !isShowingThisStash {
            files = .loading
        } else {
            switch stash.files {
            case .loaded(let loaded):
                files = .loaded(StashColumnContent.files(loaded, filter: filter), total: loaded.count)
            case .failed(let error):
                files = .failed(title: error.title, message: error.message)
            case .idle, .loading:
                files = .loading
            }
        }
        let actions = context.actions
        return StashColumnContent(
            sha: sha,
            branch: entry?.branchName,
            message: entry?.message ?? "",
            files: files,
            canRestore: actions.canPerform(.restoreStash(sha: sha)),
            canApply: actions.canPerform(.applyStash(sha: sha)),
            canDiscard: actions.canPerform(.discardStash(sha: sha)),
            applyRefusal: actions.disabledReason(.restoreStash(sha: sha)),
            isBusy: StashActions.isBusy(repository),
            filter: filter,
            selectedFileID: isShowingThisStash ? stash.selectedFile?.id : nil
        )
    }

    /// The IDs of the shown stash's files the search lists, once they've
    /// loaded; nil without a search.
    private var searchedFileIDs: [String]? {
        let filter = context.state.searchText
        guard !filter.isEmpty, isShowingThisStash, case .loaded(let files) = repository.stash.files else {
            return nil
        }
        return StashColumnContent.files(files, filter: filter).map(\.id)
    }

    /// Keeps the selected file to those the search lists, as a click
    /// selects (`filteredSelection`).
    private func selectSearchedFile() {
        let stash = repository.stash
        guard let listed = searchedFileIDs, let entry, case .loaded(let files) = stash.files,
              let kept = filteredSelection(stash.selectedFile.map { [$0.id] } ?? [], listed: listed)
        else {
            return
        }
        if let id = kept.first, let file = files.first(where: { $0.id == id }) {
            stash.show(entry, file: file)
        } else {
            stash.deselectFile()
        }
    }

    /// Shows the entry, unless it shows already.
    private func showStash() {
        guard let entry, !isShowingThisStash else {
            return
        }
        repository.stash.show(entry)
    }

    private func selectFile(_ id: String?) {
        guard let entry, let id, let file = repository.stash.files.value?.first(where: { $0.id == id }) else {
            return
        }
        repository.stash.show(entry, file: file)
    }
}
