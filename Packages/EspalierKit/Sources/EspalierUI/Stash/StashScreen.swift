// A stash's place: a header as high as the diff's with the title, Restore,
// and Discard…; the stash's files in the Changes table's rows, without
// checkboxes; under them the branch, the count, and what Restore does; and
// the selected file's read-only diff. Any branch's stash shows; another
// branch's can be discarded but not restored ("Switch to <branch> to
// restore these changes.", `StashModel`'s precondition). The toolbar search
// filters the files; when it hides the selected file, the first file it
// lists is selected, or none when it lists none (`filteredSelection`).
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

    /// The branch the changes were stashed on.
    var branch: String
    var files: Files
    /// Whether the stash is the current branch's, so it can be restored.
    var isCurrentBranch: Bool
    var canRestore: Bool
    var canDiscard: Bool
    /// Restoring or discarding it.
    var isBusy: Bool
    /// The toolbar search's text.
    var filter: String
    /// The selected file.
    var selectedFileID: String?

    /// "On main · 4 files" ("On main" until the files load), the count in
    /// `numberFormat`.
    func subtitle(_ numberFormat: NumberFormat) -> String {
        if case .loaded(_, let total) = files {
            return "On \(branch) · \(StashFilesSummary.files(total, numberFormat))"
        }
        return "On \(branch)"
    }

    /// What Restore does, or why it can't (another branch's stash).
    var explanation: String {
        isCurrentBranch
            ? "Restore will move your stashed files to the Changes list."
            : StashActions.restoreUnavailableReason(branch: branch)
    }

    /// The stash's files matching `filter` (its path, ignoring case).
    static func files(_ files: [CommittedFileChange], filter: String) -> [CommittedFileChange] {
        files.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }
    }
}

/// The stash's header, as high as the diff's: the title, then Restore and
/// Discard….
struct StashHeader: View {
    let content: StashColumnContent
    var restore: @MainActor () -> Void = {}
    var discard: @MainActor () -> Void = {}

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            Text("Stashed Changes")
                .font(Typography.row.weight(.semibold))
                .foregroundStyle(.text)
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if content.isBusy {
                ArcProgress(.small)
                    .accessibilityLabel("Working")
            }
            Button("Restore", action: restore)
                .buttonStyle(.prominent)
                .disabled(!content.canRestore)
                .tooltip(content.explanation)
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

/// Under the stash's files: the branch and the count, and what Restore
/// does or why it can't.
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
            Text(content.explanation)
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
    var discard: @MainActor () -> Void = {}
    var select: @MainActor (String?) -> Void = { _ in }
    var open: @MainActor (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            StashHeader(content: content, restore: restore, discard: discard)
            Hairline()
            files
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            StashFooter(content: content)
        }
        .background(Color(espalier: Palette.background))
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
                scope: FileTableScope(filter: FileListFilter(text: content.filter), source: content.branch),
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

/// A branch's stash.
public struct StashScreen: View {
    private let repository: RepositoryModel
    private let branch: String
    @Environment(WindowContext.self) private var context

    public init(repository: RepositoryModel, branch: String) {
        self.repository = repository
        self.branch = branch
    }

    public var body: some View {
        Group {
            if entry != nil {
                SplitView(.stash) {
                    StashColumn(
                        content: content,
                        restore: { context.actions.perform(.restoreStash(branch: branch)) },
                        discard: { context.actions.perform(.discardStash(branch: branch)) },
                        select: selectFile,
                        open: { path in context.actions.perform(.openInEditor(path: POSIXPath.join(repository.record.path, path))) }
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
                CenteredMessage("No Stashed Changes", systemImage: "tray", description: "There are no stashed changes on \(branch).")
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

    /// The branch's stash entry.
    private var entry: StashEntry? {
        repository.gitState.stashes.entriesByBranch[branch]
    }

    /// Whether the model shows this branch's entry.
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
            branch: branch,
            files: files,
            isCurrentBranch: repository.gitState.tip.branch?.name == branch,
            canRestore: actions.canPerform(.restoreStash(branch: branch)),
            canDiscard: actions.canPerform(.discardStash(branch: branch)),
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

    /// Shows the branch's stash, unless it shows already.
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
