// A stash's place: the header with Restore and Discard… and what Restore
// does, the stash's files, and the selected file's read-only diff. Any
// branch's stash shows; another branch's can be discarded but not restored
// ("Switch to <branch> to restore these changes.", `StashModel`'s
// precondition). The toolbar search filters the files.
//
// The stash shows through `StashModel` (`stash.show`, which also takes the
// Changes list's selection to the stash), and leaving the place goes back
// to the working directory (`stash.hide`).

import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// A stashed file's row.
nonisolated struct StashedFileRowContent: Sendable, Equatable, Identifiable {
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

    /// The path, or "old → new" for a rename.
    var tooltip: String {
        oldPath.map { "\($0) → \(path)" } ?? path
    }
}

/// How many files, in words.
nonisolated enum StashFilesSummary {
    /// "1 file", "4 files".
    static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }
}

/// What the stash's column shows.
nonisolated struct StashColumnContent: Sendable, Equatable {
    /// The stash's files.
    enum Files: Sendable, Equatable {
        case loading
        /// The files matching the filter, and how many the stash has.
        case loaded([StashedFileRowContent], total: Int)
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

    /// "On main · 4 files" ("On main" until the files load).
    var subtitle: String {
        if case .loaded(_, let total) = files {
            return "On \(branch) · \(StashFilesSummary.files(total))"
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
    static func files(_ files: [CommittedFileChange], filter: String) -> [StashedFileRowContent] {
        files.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }.map(StashedFileRowContent.init)
    }
}

/// One stashed file, as Changes shows a file: the status badge, the name,
/// and the folder in tertiary text.
struct StashedFileRow: View {
    let content: StashedFileRowContent

    var body: some View {
        HStack(spacing: FileRowMetrics.spacing) {
            StatusGlyph(content.status)
            HStack(alignment: .firstTextBaseline, spacing: FileRowMetrics.labelSpacing) {
                Text(content.fileName)
                    .font(Typography.row.weight(.medium))
                    .foregroundStyle(.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if !content.directory.isEmpty {
                    Text(content.directory)
                        .font(Typography.secondary)
                        .foregroundStyle(.text3)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .frame(minHeight: Metrics.FileList.rowHeight - 8, alignment: .leading)
        .help(content.tooltip)
        .accessibilityElement(children: .combine)
    }
}

/// A stashed file's row background: the soft selection Changes' rows have.
/// The row's own selection drawing goes off, so it doesn't draw solid over
/// this.
struct StashedFileRowBackground: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.Radius.row, style: .continuous)
            .fill(isSelected ? Color.accentSoft : .clear)
            .padding(.horizontal, FileRowMetrics.inset)
            .turnsRowHighlightOff()
    }
}

/// The stash's header: the title, the branch and count, Restore and
/// Discard…, and what Restore does.
struct StashHeader: View {
    let content: StashColumnContent
    var restore: @MainActor () -> Void = {}
    var discard: @MainActor () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.insetMedium) {
            HStack(spacing: Metrics.insetMedium) {
                IconCircle("tray.full", size: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.grid / 2) {
                    Text("Stashed Changes")
                        .font(Typography.row.weight(.semibold))
                        .foregroundStyle(.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(content.subtitle)
                        .font(Typography.meta)
                        .foregroundStyle(.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: Metrics.insetSmall) {
                Button("Restore", action: restore)
                    .buttonStyle(.prominent)
                    .disabled(!content.canRestore)
                Button("Discard…", action: discard)
                    .buttonStyle(.quiet)
                    .disabled(!content.canDiscard)
                if content.isBusy {
                    ArcProgress(.small)
                        .accessibilityLabel("Working")
                }
            }
            .controlSize(.small)
            Text(content.explanation)
                .font(Typography.meta)
                .foregroundStyle(.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FileRowMetrics.contentInset)
        .padding(.vertical, Metrics.insetLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The stash's column: the header over its files.
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
            List(selection: Binding(get: { content.selectedFileID }, set: select)) {
                ForEach(rows) { row in
                    StashedFileRow(content: row)
                        .tag(row.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: FileRowMetrics.contentInset, bottom: 0, trailing: FileRowMetrics.contentInset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(StashedFileRowBackground(isSelected: row.id == content.selectedFileID))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Metrics.FileList.rowHeight)
            .contextMenu(forSelectionType: String.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    open(row.path)
                }
            }
        }
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
            }
        }
        .onAppear(perform: showStash)
        .onChange(of: entry?.stashSha) {
            showStash()
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
