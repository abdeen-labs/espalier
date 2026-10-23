// Ported in part from desktop/app/src/ui/diff/index.tsx
//
// The diff's container: the header, a conflicted file's band in Changes
// (ConflictBand.swift), then the text table, an image diff, or the binary,
// submodule, large, unrenderable, empty, or conflicted state. A conflicted
// file whose markers make whole conflicts, while an operation waits on
// them, shows as the working file with each conflict as blocks
// (ConflictBlocks.swift) in place of its diff; their headers' buttons keep
// one side of one conflict, and the band leaves the whole file's sides to
// the file's row.
// The previous diff stays while the next loads, with a spinner after
// 150 ms; the header's counts and the file's actions wait for the file's
// own diff. A text diff has the find bar over its top trailing corner while
// find is open (DiffFindBar.swift). Show Diff crossfades a large diff in
// over its message.

import AppKit
import EspalierCore
import EspalierSupport
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
    /// A conflicted file's text divided by its markers
    /// (`changes.conflictedFileText`), for its blocks.
    private let conflictedText: ConflictedFileText?

    @Environment(WindowContext.self) private var window: WindowContext?
    @Environment(\.syntaxHighlighter) private var environmentHighlighter
    @Environment(\.motion) private var motion
    @State private var session = DiffSession()
    /// Find in the diff, kept from file to file.
    @State private var find = DiffFindModel()

    /// - Parameters:
    ///   - diff: The diff, as the model loads it.
    ///   - file: The file the diff is of.
    ///   - context: Where the diff shows.
    ///   - staging: Line staging, in Changes.
    ///   - conflictedText: A conflicted file's text divided by its markers,
    ///     in Changes: its conflicts show as blocks.
    public init(
        _ diff: Loadable<Diff, OperationError>,
        file: DiffFileInfo?,
        context: DiffContext,
        staging: DiffStaging? = nil,
        conflictedText: ConflictedFileText? = nil
    ) {
        self.diff = diff
        self.file = file
        self.context = context
        self.staging = staging
        self.conflictedText = conflictedText
    }

    public var body: some View {
        let settings = DiffSettings(preferences: window?.app.preferences, context: context)
        VStack(spacing: 0) {
            if let file {
                header(file, settings: settings)
                Hairline()
            }
            conflictBand
            // Stacked, so a view that replaces another (Show Diff) crossfades
            // with it in place.
            ZStack {
                content(settings: settings)
            }
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
        .onChange(of: conflictBlocks != nil, initial: true) { _, showsBlocks in
            session.highlightsWholeNewFile = showsBlocks
        }
    }

    // MARK: Header

    private func header(_ file: DiffFileInfo, settings: DiffSettings) -> some View {
        DiffHeader(
            content: headerContent(file),
            openInEditor: {
                guard let path = fullPath(file) else {
                    return
                }
                window?.actions.perform(.openInEditor(path: path))
            },
            options: {
                DiffOptionsMenu(content: optionsContent(settings: settings), actions: optionsActions)
            }
        )
        // Another file's counts show at once, even when its diff arrives
        // with it.
        .motionScope(file.id)
    }

    private func headerContent(_ file: DiffFileInfo) -> DiffHeaderContent {
        var content = DiffHeaderContent(path: file.path, oldPath: file.oldPath, status: file.status)
        switch showsFilesDiff ? diff.value : nil {
        case .text(let text)?:
            let (added, deleted) = lineCounts(text.hunks)
            content.addedLines = added
            content.deletedLines = deleted
        case .largeText(let text)? where session.forceShowLargeDiff:
            // Counted only once the diff shows.
            let (added, deleted) = lineCounts(text.hunks)
            content.addedLines = added
            content.deletedLines = deleted
        default:
            break
        }
        if window != nil, fileExistsOnDisk(file) {
            let title = window?.actions.title(for: .openInEditor(path: nil)) ?? "Open in Editor"
            content.openInEditorTitle = title
        }
        return content
    }

    private func optionsContent(settings: DiffSettings) -> DiffOptionsContent {
        var content = DiffOptionsContent(
            isSplit: settings.isSplit,
            hidesWhitespace: settings.hidesWhitespace,
            wrapsLines: settings.wrapsLines,
            expansion: nil
        )
        if let (text, isLarge) = textDiff, conflictBlocks == nil {
            content.expansion = Self.expansion(
                session.displayDiff(for: text, isLarge: isLarge),
                canExpand: session.canExpand(text, isLarge: isLarge),
                hasExpandedLines: session.hasExpandedLines
            )
        }
        return content
    }

    /// The options menu's expansion item for the text diff shown: none
    /// without hunks; Collapse Expanded Lines once lines are expanded;
    /// Expand Whole File once the file's contents allow it, disabled when
    /// the diff already shows the whole file.
    static func expansion(_ shown: TextDiff, canExpand: Bool, hasExpandedLines: Bool) -> DiffOptionsContent.Expansion? {
        if shown.hunks.isEmpty {
            return nil
        }
        if hasExpandedLines {
            return .collapse
        }
        guard canExpand else {
            return nil
        }
        return .expand(isEnabled: shown.hunks.count != 1 || shown.hunks[0].expansionType != .none)
    }

    private var optionsActions: DiffOptionsActions {
        DiffOptionsActions(
            setSplit: { isSplit in
                window?.app.preferences.showSideBySideDiff = isSplit
            },
            setHidesWhitespace: { hide in
                DiffWhitespace.set(hide, context: context, repository: window?.repository, preferences: window?.app.preferences)
            },
            setWrapsLines: { wrap in
                window?.app.preferences.wrapDiffLines = wrap
            },
            expandWholeFile: { session.expandWholeFile() },
            collapseExpandedLines: { session.collapseExpandedLines() }
        )
    }

    // MARK: A conflicted file

    /// A conflicted file's band in Changes: its state, and its sides to
    /// pick while its conflicts aren't drawn as blocks.
    @ViewBuilder
    private var conflictBand: some View {
        if context == .conflict, let window, let repository = window.repository, let row = shownFile.flatMap(conflictRow) {
            ConflictBand(content: row, actions: .make(for: row, repository: repository, context: window), includesSides: conflictBlocks == nil)
        }
    }

    /// The shown conflicted file's conflicts as blocks, in Changes: an
    /// operation's conflicts in a file whose markers make whole conflicts.
    /// Nil for the rest (binary, deleted, without markers, a stash
    /// restore's), and while the previous file's diff shows.
    private var conflictBlocks: ConflictBlocks? {
        guard context == .conflict, showsFilesDiff, let conflictedText, let window, let repository = window.repository,
              let row = shownFile.flatMap(conflictRow)
        else {
            return nil
        }
        return ConflictBlocks.make(conflictedText, row: row, repository: repository)
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

    /// Whether the diff shown is the file's: a loaded diff is; the previous
    /// one, shown while the next loads, is when it was loaded for the same
    /// file.
    static func isFilesDiff(_ diff: Loadable<Diff, OperationError>, fileID: String?, loadedFileID: String?) -> Bool {
        switch diff {
        case .loaded:
            true
        case .loading(_?):
            fileID != nil && fileID == loadedFileID
        case .idle, .loading(nil), .failed:
            false
        }
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
                // The diff crossfades in over the message over 0.15 s.
                LargeDiffView {
                    withMotion(motion, Motion.leave) {
                        session.forceShowLargeDiff = true
                    }
                }
            }
        case .binary:
            BinaryDiffView(open: openWithDefaultApp)
        case .image(let image):
            ImageDiffView(
                content: session.images.flatMap { $0.diff == image ? $0.content : nil } ?? ImageDiffContent(image),
                status: shownFile?.status ?? .modified,
                conflict: shownFile.flatMap(conflictRow),
                mode: settings.imageDiffType,
                setMode: { mode in
                    window?.app.preferences.imageDiffType = mode
                }
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
            NoHunksView(
                status: shownFile?.appStatus,
                hidesWhitespace: settings.hidesWhitespace == true,
                conflict: shownFile.flatMap(conflictRow)
            )
        } else {
            let shown = session.displayDiff(for: text, isLarge: isLarge)
            let stagingState = stagingEnabled ? staging?.state : nil
            let blocks = conflictBlocks
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
                        canExpand: blocks == nil && session.canExpand(text, isLarge: isLarge),
                        hasExpandedLines: blocks == nil && session.hasExpandedLines,
                        staging: stagingState,
                        tokens: session.tokens,
                        tokensGeneration: session.tokensGeneration,
                        isInteractive: isInteractive,
                        conflicts: blocks
                    ),
                    actions: tableActions,
                    find: find
                )
                .overlay(alignment: .topTrailing) {
                    if find.isShown {
                        DiffFindBar(find: find)
                            .padding(.top, Metrics.DiffFind.topInset)
                            .padding(.horizontal, Metrics.DiffFind.sideInset)
                            .transition(DiffFindBar.transition(animates: motion.animates))
                    }
                }
                .barMotion(find.isShown)
            }
        }
    }

    private var tableActions: DiffTableActions {
        let session = session
        let window = window
        return DiffTableActions(
            expandHunk: { index, kind in session.expandHunk(index, kind) },
            expandWholeFile: { session.expandWholeFile() },
            collapseExpandedLines: { session.collapseExpandedLines() },
            didPaint: { fileID in session.didPaint(fileID) },
            staging: stagingEnabled ? staging?.actions(discard: { changes, lines, generation in
                guard let window else {
                    return false
                }
                let discarded: Void? = await window.presenter.perform { answers throws(OperationError) in
                    try await changes.discardLines(lines, inDiff: generation, confirmed: answers.confirmed)
                }
                return discarded != nil
            }) : nil,
            chooseConflictSide: chooseConflictSide
        )
    }

    /// A conflict block's button: keeps one side of one conflict of the
    /// shown file, as the table showed it, through the window's presenter.
    private var chooseConflictSide: (@MainActor (ConflictedFileText, Int, ManualConflictResolution) async -> Bool)? {
        guard context == .conflict, let window, let repository = window.repository, let path = shownFile?.path else {
            return nil
        }
        return { [weak window] text, index, side in
            guard let window else {
                return false
            }
            let chosen: Void? = await window.presenter.perform { _ throws(OperationError) in
                try await repository.operations.chooseConflictSide(side, conflict: index, inFile: path, shown: text)
            }
            return chosen != nil
        }
    }

    // MARK: Helpers

    /// The diff shown is the file's, not the previous file's shown while
    /// the file's loads.
    private var showsFilesDiff: Bool {
        Self.isFilesDiff(diff, fileID: file?.id, loadedFileID: session.loadedFileID)
    }

    /// The file of the diff shown: the file, or the previous one while the
    /// file's diff loads.
    private var shownFile: DiffFileInfo? {
        showsFilesDiff ? file : session.loadedFile
    }

    /// Opens a binary file in its default app: in Changes, for a file on
    /// disk, once its own diff shows.
    private var openWithDefaultApp: (() -> Void)? {
        guard context == .changes || context == .conflict, showsFilesDiff, let file, fileExistsOnDisk(file),
              let path = fullPath(file)
        else {
            return nil
        }
        return { window?.actions.perform(.openWithDefaultProgram(path: path)) }
    }

    /// A conflicted file's row in Changes, for what its message says.
    private func conflictRow(_ file: DiffFileInfo) -> ConflictFileRowContent? {
        guard file.status == .conflicted, let window, let repository = window.repository else {
            return nil
        }
        return FileList.conflictRows(repository, numberFormat: window.app.preferences.numberFormat)[ExactString(file.path)]
    }

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
        context == .conflict || shownFile?.status == .conflicted
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
    /// A conflicted file's row in Changes: whether a side can be picked, or
    /// was.
    var conflict: ConflictFileRowContent?

    /// Which state shows.
    enum Message: Equatable {
        /// A new or untracked file with nothing in it.
        case emptyFile
        /// A rename without changes.
        case renamed
        /// A rename with changes git found no hunks for.
        case renamedWithChanges
        /// A conflict without markers (binary, deleted on one side), whose
        /// working copy is HEAD's: resolved by picking a side.
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
                CenteredMessage("The file was renamed and includes changes", systemImage: "rectangle.and.pencil.and.ellipsis")
            case .renamed:
                CenteredMessage("The file was renamed but not changed", systemImage: "rectangle.and.pencil.and.ellipsis")
            case .manualConflict:
                ConflictedFileMessage("This file has a conflict", conflict: conflict)
            case .onlyWhitespace:
                CenteredMessage("Only whitespace changes found", systemImage: "text.alignleft")
            case .noContentChanges:
                CenteredMessage("No content changes found", systemImage: "equal")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A conflicted file without conflict markers to show: that it's in
/// conflict, and how to resolve it.
struct ConflictedFileMessage: View {
    let title: String
    /// The file's row in Changes.
    let conflict: ConflictFileRowContent?

    init(_ title: String, conflict: ConflictFileRowContent?) {
        self.title = title
        self.conflict = conflict
    }

    var body: some View {
        CenteredMessage(
            title,
            systemImage: "exclamationmark.triangle",
            description: description,
            tint: Color(espalier: Palette.warningMark)
        )
        // A side picked from the band: the description fades to the
        // file's new state.
        .motion(description == nil ? Motion.leave : Motion.arrive, value: description)
    }

    /// To choose a side while one can be picked (the band's buttons, the
    /// row's menu), the side once one was; nothing when the row offers
    /// neither (a stash restore).
    private var description: String? {
        guard let conflict else {
            return nil
        }
        switch conflict.state {
        case .manual where conflict.oursLabel != nil:
            return "Choose the version to keep."
        case .resolved(isUndoable: true):
            return "\(conflict.status)."
        default:
            return nil
        }
    }
}
