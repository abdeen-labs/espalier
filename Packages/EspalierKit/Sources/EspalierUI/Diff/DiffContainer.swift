// Ported in part from desktop/app/src/ui/diff/index.tsx
//
// The diff's container: the header, then the text table, an image diff, or
// the binary, submodule, large, unrenderable, empty, or conflicted state.
// The previous diff stays while the next loads, with a spinner after
// 150 ms.

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// Where a diff shows: it picks the whitespace setting and whether lines
/// can be staged.
nonisolated public enum DiffContext: String, Sendable, Equatable {
    /// The working directory's changes: staging, Hide Whitespace Changes'
    /// Changes key.
    case changes
    /// A commit's file (History, Compare, tags).
    case history
    /// A pull request's changes.
    case pullRequest
    /// A stash's file (read-only).
    case stash
    /// A conflicted file in Changes (staging disabled).
    case conflict
    /// The AI conflict sheet's resolution diffs (read-only).
    case aiResolution
}

/// The change a diff is of, for loading the file's contents.
nonisolated public enum DiffFileChange: Sendable, Hashable {
    case workingDirectory(WorkingDirectoryFileChange)
    case committed(CommittedFileChange)

    /// The change's ID (`FileChange.id`).
    public var id: String {
        switch self {
        case .workingDirectory(let file): file.id
        case .committed(let file): file.id
        }
    }
}

/// The file a diff is of, for the header.
nonisolated public struct DiffFileInfo: Sendable, Equatable {
    public var path: String
    /// The old path of a rename or copy.
    public var oldPath: String?
    public var status: FileStatusKind
    /// The file change, when built from one: its contents expand the diff
    /// and feed syntax color, and its status picks the empty states.
    public var change: DiffFileChange?

    public init(path: String, oldPath: String? = nil, status: FileStatusKind) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        change = nil
    }

    public init(_ change: some FileChange) {
        self.init(path: change.path, oldPath: change.status.oldPath, status: FileStatusKind(change.status))
        if let working = change as? WorkingDirectoryFileChange {
            self.change = .workingDirectory(working)
        } else if let committed = change as? CommittedFileChange {
            self.change = .committed(committed)
        }
    }

    /// The file's ID: its change's (`FileChange.id`), or its path.
    public var id: String {
        switch change {
        case .workingDirectory(let file)?: file.id
        case .committed(let file)?: "\(file.commitish):\(file.id)"
        case nil: path
        }
    }

    /// The change's status, when known.
    var appStatus: AppFileStatus? {
        switch change {
        case .workingDirectory(let file)?: file.status
        case .committed(let file)?: file.status
        case nil: nil
        }
    }
}

/// A diff: the header, then the text, image, binary, submodule, large, or
/// empty state.
public struct DiffContainer: View {
    private let diff: Loadable<Diff, OperationError>
    private let file: DiffFileInfo?
    private let context: DiffContext
    private let staging: DiffStaging?

    @Environment(WindowContext.self) private var window: WindowContext?
    @Environment(\.syntaxHighlighter) private var environmentHighlighter
    @State private var session = DiffSession()

    /// - Parameters:
    ///   - diff: The diff, as the model loads it.
    ///   - file: The file the diff is of.
    ///   - context: Where the diff shows.
    ///   - staging: Line staging, in Changes.
    public init(_ diff: Loadable<Diff, OperationError>, file: DiffFileInfo?, context: DiffContext, staging: DiffStaging? = nil) {
        self.diff = diff
        self.file = file
        self.context = context
        self.staging = staging
    }

    public var body: some View {
        let settings = DiffSettings(preferences: window?.app.preferences, context: context)
        VStack(spacing: 0) {
            if let file {
                header(file, settings: settings)
                Hairline()
            }
            content(settings: settings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if diff.isLoading {
                        DelayedProgressView(delay: Timing.diffOverlayDelay)
                            .allowsHitTesting(false)
                    }
                }
        }
        .background(Color(nsColor: Palette.background))
        .onChange(of: DiffViewIdentity(fileID: file?.id, diff: DiffIdentity(diff.value), isLoading: diff.isLoading), initial: true) {
            session.highlighter = environmentHighlighter ?? SyntaxHighlighting.defaultHighlighter
            session.tabSize = settings.tabSize
            session.fileDidChange(file)
            if diff.isLoading {
                // The previous file's diff stays while this one loads.
                return
            }
            session.diffDidChange(diff.value, file: file, repository: window?.repository)
        }
    }

    // MARK: Header

    private func header(_ file: DiffFileInfo, settings: DiffSettings) -> some View {
        DiffHeader(
            content: headerContent(file, settings: settings),
            setSplit: { isSplit in
                window?.app.preferences.showSideBySideDiff = isSplit
            },
            setImageMode: { mode in
                window?.app.preferences.imageDiffType = mode
            },
            openInEditor: {
                guard let path = fullPath(file) else {
                    return
                }
                window?.actions.perform(.openInEditor(path: path))
            },
            options: {
                DiffOptionsMenu(content: optionsContent(file, settings: settings), actions: optionsActions(file))
            }
        )
    }

    private func headerContent(_ file: DiffFileInfo, settings: DiffSettings) -> DiffHeaderContent {
        var content = DiffHeaderContent(path: file.path, oldPath: file.oldPath, status: file.status, mode: .none)
        switch diff.value {
        case .text(let text)?:
            let (added, deleted) = lineCounts(text.hunks)
            content.addedLines = added
            content.deletedLines = deleted
            content.mode = .text(isSplit: settings.isSplit)
        case .largeText(let text)?:
            let (added, deleted) = lineCounts(text.hunks)
            content.addedLines = added
            content.deletedLines = deleted
            content.mode = .text(isSplit: settings.isSplit)
        case .image(let image)? where image.previous != nil && image.current != nil:
            content.mode = .image(settings.imageDiffType)
        default:
            break
        }
        if window != nil, fileExistsOnDisk(file) {
            let title = window?.actions.title(for: .openInEditor(path: nil)) ?? "Open in Editor"
            content.openInEditorTitle = title
        }
        return content
    }

    private func optionsContent(_ file: DiffFileInfo, settings: DiffSettings) -> DiffOptionsContent {
        var content = DiffOptionsContent(
            hidesWhitespace: settings.hidesWhitespace,
            wrapsLines: settings.wrapsLines,
            expansion: nil,
            fileExists: fileExistsOnDisk(file),
            canDiscard: context == .changes && workingDirectoryFile(file) != nil
        )
        if let (text, isLarge) = textDiff {
            if session.hasExpandedLines {
                content.expansion = .collapse
            } else if session.canExpand(text, isLarge: isLarge) {
                let shown = session.displayDiff(for: text, isLarge: isLarge)
                content.expansion = .expand(isEnabled: shown.hunks.count != 1 || shown.hunks[0].expansionType != .none)
            }
        }
        if let preferences = window?.app.preferences {
            content.discardTitle = preferences.confirmDiscardChanges ? "Discard Changes…" : "Discard Changes"
        }
        return content
    }

    private func optionsActions(_ file: DiffFileInfo) -> DiffOptionsActions {
        DiffOptionsActions(
            setHidesWhitespace: { hide in
                DiffWhitespace.set(hide, context: context, repository: window?.repository, preferences: window?.app.preferences)
            },
            setWrapsLines: { wrap in
                window?.app.preferences.wrapDiffLines = wrap
            },
            expandWholeFile: { session.expandWholeFile() },
            collapseExpandedLines: { session.collapseExpandedLines() },
            openWithDefaultProgram: {
                if let path = fullPath(file) {
                    window?.actions.perform(.openWithDefaultProgram(path: path))
                }
            },
            showInFinder: {
                if let path = fullPath(file) {
                    window?.actions.perform(.showInFinder(path: path))
                }
            },
            copyFilePath: {
                copyToPasteboard(fullPath(file) ?? file.path)
            },
            copyRelativeFilePath: {
                copyToPasteboard(file.path)
            },
            discardChanges: {
                guard let window, let repository = window.repository, let working = workingDirectoryFile(file) else {
                    return
                }
                Task {
                    await window.presenter.perform { answers throws(OperationError) in
                        try await repository.changes.discard([working], confirmed: answers.confirmed)
                    }
                }
            }
        )
    }

    // MARK: Content

    /// What shows below the header.
    enum Shown {
        /// No file: a note to select one.
        case selectFile
        /// Nothing yet: a file without a diff, or its first diff loading
        /// (the spinner shows after a delay).
        case nothing
        /// The diff's own view; not interactive while it's the previous
        /// file's, shown until the next loads.
        case diff(Diff, isInteractive: Bool)
        /// The error's title and message.
        case failed(OperationError)
    }

    /// What shows below the header for `diff`, with or without a file.
    static func shown(_ diff: Loadable<Diff, OperationError>, hasFile: Bool) -> Shown {
        switch diff {
        case .idle:
            hasFile ? .nothing : .selectFile
        case .loading(let previous):
            previous.map { .diff($0, isInteractive: false) } ?? .nothing
        case .loaded(let loaded):
            .diff(loaded, isInteractive: true)
        case .failed(let error):
            .failed(error)
        }
    }

    @ViewBuilder
    private func content(settings: DiffSettings) -> some View {
        switch Self.shown(diff, hasFile: file != nil) {
        case .selectFile:
            PlaceholderNote("Select a file to see its changes")
        case .nothing:
            Color.clear
        case .diff(let loaded, let isInteractive):
            kindView(loaded, settings: settings, isInteractive: isInteractive)
        case .failed(let error):
            CenteredMessage(error.title, systemImage: "exclamationmark.triangle", description: error.message, tint: Color(espalier: Palette.warningMark))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func kindView(_ diff: Diff, settings: DiffSettings, isInteractive: Bool) -> some View {
        switch diff {
        case .text(let text):
            textContent(text, isLarge: false, settings: settings, isInteractive: isInteractive)
        case .largeText(let large):
            if session.forceShowLargeDiff {
                textContent(TextDiff(large), isLarge: true, settings: settings, isInteractive: isInteractive)
            } else {
                LargeDiffView { session.forceShowLargeDiff = true }
            }
        case .binary:
            BinaryDiffView(open: file.flatMap(fullPath).map { path in
                { window?.actions.perform(.openWithDefaultProgram(path: path)) }
            })
        case .image(let image):
            ImageDiffView(
                content: session.images.flatMap { $0.diff == image ? $0.content : nil } ?? ImageDiffContent(image),
                status: file?.status ?? .modified,
                mode: settings.imageDiffType
            )
        case .submodule(let submodule):
            SubmoduleDiffView(
                content: SubmoduleDiffContent(diff: submodule, readOnly: context != .changes),
                openSubmodule: window == nil ? nil : {
                    window?.actions.perform(.addRepositories(paths: [submodule.fullPath]))
                }
            )
        case .unrenderable:
            UnrenderableDiffView()
        }
    }

    @ViewBuilder
    private func textContent(_ text: TextDiff, isLarge: Bool, settings: DiffSettings, isInteractive: Bool) -> some View {
        if text.hunks.isEmpty {
            NoHunksView(status: file?.appStatus, hidesWhitespace: settings.hidesWhitespace == true)
        } else {
            let shown = session.displayDiff(for: text, isLarge: isLarge)
            let stagingState = stagingEnabled ? staging?.state(hunks: shown.hunks) : nil
            VStack(spacing: 0) {
                DiffMessages(warnings: DiffContentsWarning.warnings(for: shown))
                DiffTextView(
                    content: DiffTableContent(
                        fileID: isInteractive ? (file?.id ?? "") : (session.loadedFileID ?? ""),
                        diff: shown,
                        isSplit: settings.isSplit,
                        wrapsLines: settings.wrapsLines ?? true,
                        tabSize: settings.tabSize,
                        fontSize: settings.fontSize,
                        detectsConflictMarkers: isConflict,
                        canExpand: session.canExpand(text, isLarge: isLarge),
                        hasExpandedLines: session.hasExpandedLines,
                        staging: stagingState,
                        tokens: session.tokens,
                        tokensGeneration: session.tokensGeneration,
                        isInteractive: isInteractive
                    ),
                    actions: tableActions(hunks: shown.hunks)
                )
            }
        }
    }

    private func tableActions(hunks: [DiffHunk]) -> DiffTableActions {
        let session = session
        let window = window
        return DiffTableActions(
            expandHunk: { index, kind in session.expandHunk(index, kind) },
            expandWholeFile: { session.expandWholeFile() },
            collapseExpandedLines: { session.collapseExpandedLines() },
            didPaint: { fileID in session.didPaint(fileID) },
            staging: stagingEnabled ? staging?.actions(hunks: hunks, discard: { changes, lines in
                guard let window else {
                    return
                }
                Task {
                    await window.presenter.perform { answers throws(OperationError) in
                        try await changes.discardLines(lines, confirmed: answers.confirmed)
                    }
                }
            }) : nil
        )
    }

    // MARK: Helpers

    /// The text diff shown, if any.
    private var textDiff: (TextDiff, Bool)? {
        switch diff.value {
        case .text(let text)?: (text, false)
        case .largeText(let large)? where session.forceShowLargeDiff: (TextDiff(large), true)
        default: nil
        }
    }

    /// Lines can be staged: Changes, with staging, not a conflicted file.
    private var stagingEnabled: Bool {
        context == .changes && staging != nil && file?.status != .conflicted
    }

    /// A conflicted file's diff tints its markers.
    private var isConflict: Bool {
        context == .conflict || file?.status == .conflicted
    }

    private func fullPath(_ file: DiffFileInfo) -> String? {
        guard let root = window?.repository?.record.path else {
            return nil
        }
        return (root as NSString).appendingPathComponent(file.path)
    }

    private func fileExistsOnDisk(_ file: DiffFileInfo) -> Bool {
        guard let path = fullPath(file) else {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }

    private func workingDirectoryFile(_ file: DiffFileInfo) -> WorkingDirectoryFileChange? {
        if case .workingDirectory(let working)? = file.change {
            return working
        }
        return nil
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

/// The settings a diff shows with.
struct DiffSettings {
    var isSplit = false
    /// Wrap Lines; nil when there's no preference to change.
    var wrapsLines: Bool? = true
    var tabSize = 4
    var fontSize = Metrics.Diff.codeFontSize
    var imageDiffType = ImageDiffType.twoUp
    /// Hide Whitespace Changes for the place, when it has the setting.
    var hidesWhitespace: Bool?

    init(preferences: Preferences?, context: DiffContext) {
        guard let preferences else {
            return
        }
        isSplit = preferences.showSideBySideDiff
        wrapsLines = preferences.wrapDiffLines
        tabSize = max(preferences.tabSize, 1)
        // To the half point: the default code size is 11.5.
        fontSize = (Metrics.Diff.codeFontSize * preferences.codeTextSize.factor * 2).rounded() / 2
        imageDiffType = preferences.imageDiffType
        hidesWhitespace = DiffWhitespace.isHidden(context: context, preferences: preferences)
    }
}

/// Hide Whitespace Changes, per place: one setting each for Changes,
/// History, and pull requests.
enum DiffWhitespace {
    /// Whether whitespace changes are hidden where `context` shows; nil
    /// where there's no setting (stashes, conflicts, AI resolutions).
    static func isHidden(context: DiffContext, preferences: Preferences) -> Bool? {
        switch context {
        case .changes: preferences.hideWhitespaceInChangesDiff
        case .history: preferences.hideWhitespaceInHistoryDiff
        case .pullRequest: preferences.hideWhitespaceInPullRequestDiff
        case .stash, .conflict, .aiResolution: nil
        }
    }

    /// Hides or shows whitespace changes where `context` shows, and reloads
    /// the diff there.
    static func set(_ hide: Bool, context: DiffContext, repository: RepositoryModel?, preferences: Preferences?) {
        switch context {
        case .changes:
            if let repository {
                repository.changes.setHidesWhitespace(hide)
            } else {
                preferences?.hideWhitespaceInChangesDiff = hide
            }
        case .history:
            if let repository {
                repository.history.setHideWhitespaceInDiff(hide)
            } else {
                preferences?.hideWhitespaceInHistoryDiff = hide
            }
        case .pullRequest:
            if let repository {
                repository.history.pullRequestPreview.setHideWhitespaceInDiff(hide)
                repository.history.pullRequestChanges.setHideWhitespaceInDiff(hide)
            } else {
                preferences?.hideWhitespaceInPullRequestDiff = hide
            }
        case .stash, .conflict, .aiResolution:
            break
        }
    }
}

/// What the container reacts to: the file, its diff, and whether it's
/// loading.
struct DiffViewIdentity: Equatable {
    let fileID: String?
    let diff: DiffIdentity
    let isLoading: Bool
}

/// A diff compared cheaply, for `onChange`: text diffs by `textDiffEquals`,
/// the rest by value.
struct DiffIdentity: Equatable {
    let diff: Diff?

    init(_ diff: Diff?) {
        self.diff = diff
    }

    static func == (lhs: DiffIdentity, rhs: DiffIdentity) -> Bool {
        switch (lhs.diff, rhs.diff) {
        case (nil, nil):
            true
        case (.text(let x)?, .text(let y)?):
            textDiffEquals(x, y)
        case (.largeText(let x)?, .largeText(let y)?):
            textDiffEquals(TextDiff(x), TextDiff(y))
        case (.image(let x)?, .image(let y)?):
            x == y
        case (.submodule(let x)?, .submodule(let y)?):
            x == y
        case (.binary?, .binary?), (.unrenderable?, .unrenderable?):
            true
        default:
            false
        }
    }
}

/// The number of added and deleted lines (the header's "+12 −4").
nonisolated func lineCounts(_ hunks: [DiffHunk]) -> (added: Int, deleted: Int) {
    var added = 0
    var deleted = 0
    for hunk in hunks {
        for line in hunk.lines {
            switch line.type {
            case .add: added += 1
            case .delete: deleted += 1
            case .context, .hunk: break
            }
        }
    }
    return (added, deleted)
}

/// The states for a text diff with no hunks.
struct NoHunksView: View {
    let status: AppFileStatus?
    let hidesWhitespace: Bool

    /// Which state shows.
    enum Message: Equatable {
        /// A new or untracked file with nothing in it.
        case emptyFile
        /// A rename without changes.
        case renamed
        /// A rename with changes git found no hunks for.
        case renamedWithChanges
        /// A conflict the command line must resolve.
        case manualConflict
        /// Whitespace changes, hidden.
        case onlyWhitespace
        /// Nothing else changed.
        case noContentChanges
    }

    /// The state for a file with `status` while whitespace changes are, or
    /// aren't, hidden.
    static func message(status: AppFileStatus?, hidesWhitespace: Bool) -> Message {
        switch status {
        case .new?, .untracked?:
            .emptyFile
        case .renamed(_, let renameIncludesModifications, _)?:
            renameIncludesModifications ? .renamedWithChanges : .renamed
        case .conflicted(let conflict)? where isManualConflict(conflict):
            .manualConflict
        default:
            hidesWhitespace ? .onlyWhitespace : .noContentChanges
        }
    }

    var body: some View {
        Group {
            switch Self.message(status: status, hidesWhitespace: hidesWhitespace) {
            case .emptyFile:
                CenteredMessage("The file is empty", systemImage: "doc")
            case .renamedWithChanges:
                CenteredMessage("The file was renamed and includes changes.", systemImage: "exclamationmark.triangle")
            case .renamed:
                CenteredMessage("The file was renamed but not changed", systemImage: "arrow.right.doc.on.clipboard")
            case .manualConflict:
                CenteredMessage("This file has a conflict that must be resolved on the command line.", systemImage: "exclamationmark.triangle", tint: Color(espalier: Palette.warningMark))
            case .onlyWhitespace:
                CenteredMessage("Only whitespace changes found", systemImage: "text.alignleft")
            case .noContentChanges:
                CenteredMessage("No content changes found", systemImage: "equal")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
