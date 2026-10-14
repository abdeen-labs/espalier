// The selected file's diff and line selection are in
// WorkingDirectoryDiffs.swift, the files' line counts in
// WorkingDirectoryLineCounts.swift, the filter in FileListFilter.swift, and
// discarding in DiscardOperations.swift.

import EspalierSupport
import Foundation
import GitKit
import Observation

/// What the changes list shows: working directory files, or a stashed file.
public enum ChangesSelection: Sendable, Equatable {
    case workingDirectory(fileIDs: [String])
    case stash(fileID: String?)
}

/// The working directory's changes, which of them the next commit includes,
/// and the selected file's diff.
@MainActor @Observable
public final class ChangesModel: RepositoryFeature {
    /// The changed files, sorted by path (case-insensitively), with their
    /// inclusion in the next commit.
    public private(set) var workingDirectory = WorkingDirectoryStatus.fromFiles([]) {
        didSet { updateVisibleFiles() }
    }
    /// The selected files (or stashed file).
    public private(set) var selection: ChangesSelection = .workingDirectory(fileIDs: [])
    /// The diff of the selected file, when one file is selected: without
    /// whitespace changes while `diffHidesWhitespace`. While a newer one
    /// loads, `.loading` keeps the previous diff of the same file.
    public private(set) var diff: Loadable<Diff, OperationError> = .idle
    /// The file `diff` belongs to.
    public private(set) var diffFileID: String?
    /// Whether `diff` leaves whitespace changes out (`git diff -w`). Lines
    /// can't be included or excluded then: their indexes are the full
    /// diff's.
    public private(set) var diffHidesWhitespace = false
    /// The file list filter.
    public var filter = FileListFilter() {
        didSet {
            if filter != oldValue {
                updateVisibleFiles()
            }
        }
    }
    /// The files the list shows: the files matching the filter's text and
    /// options, in the working directory's order (FileListFilter.swift).
    public internal(set) var visibleFiles: [WorkingDirectoryFileChange] = []
    /// The files the next commit includes (in full or in part) that the
    /// filter hides.
    public internal(set) var includedFilesHiddenByFilter: [WorkingDirectoryFileChange] = []

    /// The full diff of `diffFileID`, with whitespace changes: what line
    /// indexes, selectable lines, and discarding refer to. The same as
    /// `diff`'s value unless whitespace is hidden.
    ///
    /// Not observed: it always changes with `diff`, which views observe,
    /// and an observed property compares its old and new values, which
    /// took a third of a second for a 10,000,000-line diff.
    @ObservationIgnored private(set) var fullDiff: Diff?
    /// Whether a `diff` driver's textconv converted `fullDiff`'s text.
    private(set) var diffIsTextConverted = false
    /// `fullDiff`'s added and deleted lines (`selectableLines(in:)`), as
    /// the load collected them off the main actor. Not observed, as
    /// `fullDiff` (comparing two sets of 10,000,000 lines took over a
    /// second).
    @ObservationIgnored private(set) var fullDiffSelectableLines: Set<Int> = []
    /// Bumped whenever `fullDiff`'s lines change: line indexes taken from one
    /// generation's diff name the same lines only while it's current
    /// (`setLines`, `toggleLines`, and `discardLines` take it).
    public private(set) var diffGeneration = 0

    @ObservationIgnored weak var repository: RepositoryModel?

    /// The selected file's diff loads.
    @ObservationIgnored let diffLoads = LatestTask<DiffLoadKey>()
    @ObservationIgnored var diffLoadSequence: UInt64 = 0
    /// Loads a file's diffs (a seam for tests).
    @ObservationIgnored var loadDiffs: @Sendable (Repository, WorkingDirectoryFileChange, Bool) async throws -> LoadedDiffs = {
        try await loadWorkingDirectoryDiffs($0, $1, hidesWhitespace: $2)
    }
    /// The working directory selection to go back to when the stash is
    /// hidden.
    @ObservationIgnored var selectionBeforeStash: [String]?

    /// Each file's lines added and removed against HEAD, its staged and
    /// unstaged changes together, by file ID: loaded after each status pass,
    /// off the main thread, without delaying the files
    /// (WorkingDirectoryLineCounts.swift). A file has none until they
    /// arrive, and none at all when binary, a submodule, conflicted, an
    /// untracked file too large to count, or one of more than
    /// `lineCountFileLimit` files.
    public internal(set) var lineCounts: [ExactString: FileLineCount] = [:]
    /// The line count loads.
    @ObservationIgnored let lineCountLoads = LatestTask<UInt64>()
    @ObservationIgnored var lineCountSequence: UInt64 = 0
    /// Counts the files' lines against a commit, nil for an unborn HEAD (a
    /// seam for tests).
    @ObservationIgnored var countLines: @Sendable (Repository, [WorkingDirectoryFileChange], String?) async throws -> [ExactString: FileLineCount] = {
        try await getWorkingDirectoryLineCounts($0, $1, against: $2)
    }

    init() {}

    func attach(to repository: RepositoryModel) {
        self.repository = repository
        observeWhitespacePreference()
    }

    // MARK: Inclusion

    /// Includes or excludes whole files in the next commit.
    public func setIncluded(_ fileIDs: [String], _ included: Bool) {
        let ids = Set(fileIDs.map(ExactString.init))
        let files = workingDirectory.files.map { file in
            ids.contains(ExactString(file.id)) ? file.withIncludeAll(included) : file
        }
        setFiles(files)
    }

    /// Includes or excludes every file.
    public func setIncludeAll(_ included: Bool) {
        let updated = workingDirectory.withIncludeAllFiles(included)
        if updated != workingDirectory {
            workingDirectory = updated
        }
    }

    /// Sets which lines of a file the next commit includes, as given: it
    /// doesn't check `canSelectLines`. The UI uses `setLines(_:included:)` and
    /// `toggleLines(_:)`, which build the selection from the shown diff and
    /// refuse while lines can't be selected.
    public func setLineSelection(_ lineSelection: DiffSelection, forFile fileID: String) {
        let files = workingDirectory.files.map { file in
            JSCompat.strictEquals(file.id, fileID) ? file.withSelection(lineSelection) : file
        }
        setFiles(files)
    }

    // MARK: Selection

    /// Selects files in the working directory, leaving the stash if it was
    /// shown, and loads the diff when one file is selected.
    public func select(fileIDs: [String]) {
        let wasShowingStash = isShowingStash
        let selection = ChangesSelection.workingDirectory(fileIDs: fileIDs)
        if selection != self.selection {
            self.selection = selection
        }
        if wasShowingStash {
            selectionBeforeStash = nil
            repository?.stash.stashWasHidden()
        }
        loadSelectedDiff()
    }

    /// Shows the working directory rather than a stash, as after a checkout:
    /// the files selected before the stash was shown, or else the first file.
    public func selectWorkingDirectory() {
        if isShowingStash {
            let previous = (selectionBeforeStash ?? []).filter { workingDirectory.findFileWithID($0) != nil }
            selectionBeforeStash = nil
            let selection = previous.isEmpty
                ? selectWorkingDirectoryFiles(workingDirectory, selection: self.selection)
                : .workingDirectory(fileIDs: previous)
            if selection != self.selection {
                self.selection = selection
            }
            repository?.stash.stashWasHidden()
        }
        loadSelectedDiff()
    }

    /// Whether the stash is shown instead of the working directory.
    var isShowingStash: Bool {
        if case .stash = selection { true } else { false }
    }

    /// Shows a stash's file (the stash model's `show`): remembers the
    /// working directory selection and drops its diff.
    func showStash(fileID: String?) {
        if case .workingDirectory(let fileIDs) = selection {
            selectionBeforeStash = fileIDs
        }
        let selection = ChangesSelection.stash(fileID: fileID)
        if selection != self.selection {
            self.selection = selection
        }
        clearDiff()
    }

    // MARK: Refreshing

    /// Merges a new status into the files and the selection
    /// (`updateChangedFiles`), then reloads the selected file's diff.
    func reconcile(_ status: StatusResult, options: RefreshOptions) {
        let result = updateChangedFiles(
            workingDirectory: workingDirectory,
            selection: selection,
            status: status,
            clearPartialState: options.contains(.clearPartialSelections)
        )
        if result.workingDirectory != workingDirectory {
            workingDirectory = result.workingDirectory
        }
        if result.selection != selection {
            selection = result.selection
        }
        if !result.keepsDiff {
            clearDiff()
        }
        loadSelectedDiff()
        loadLineCounts(against: status.currentTip.flatMap { $0.isEmpty ? nil : $0 })
    }

    func repositoryDidBecomeInactive() {
        // The selection's refresh reloads the diff and the line counts when
        // it's selected again.
        diffLoads.cancel()
        lineCountLoads.cancel()
        if case .loading(let previous) = diff {
            diff = previous.map { .loaded($0) } ?? .idle
        }
    }

    func repositoryPathDidChange(keepingSharedState: Bool) {
        diffLoads.cancel()
        lineCountLoads.cancel()
        lineCounts = [:]
        workingDirectory = WorkingDirectoryStatus.fromFiles([])
        selection = .workingDirectory(fileIDs: [])
        selectionBeforeStash = nil
        diff = .idle
        diffFileID = nil
        diffHidesWhitespace = false
        setFullDiff(nil)
        diffIsTextConverted = false
        fullDiffSelectableLines = []
    }

    // MARK: Diff state (WorkingDirectoryDiffs.swift loads it)

    /// Forgets the diff and cancels its load.
    func clearDiff() {
        diffLoads.cancel()
        if case .idle = diff {} else {
            diff = .idle
        }
        if diffFileID != nil {
            diffFileID = nil
        }
        setFullDiff(nil)
        fullDiffSelectableLines = []
        if diffIsTextConverted {
            diffIsTextConverted = false
        }
    }

    /// Records a diff load starting for `fileID`, keeping the diff shown
    /// while the same file's diff reloads.
    func diffLoadDidStart(fileID: String, hidesWhitespace: Bool) {
        let sameFile = diffFileID.map { JSCompat.strictEquals($0, fileID) } ?? false
        if sameFile, diffHidesWhitespace == hidesWhitespace {
            diff = diff.reloading
        } else {
            diff = .loading(previous: nil)
            setFullDiff(nil)
            if diffHidesWhitespace != hidesWhitespace {
                diffHidesWhitespace = hidesWhitespace
            }
        }
        if !sameFile {
            diffFileID = fileID
        }
    }

    /// Applies a loaded diff, carrying the file's partial selection over to
    /// its lines (`carrySelection`).
    func diffDidLoad(_ loaded: LoadedDiffs, for file: WorkingDirectoryFileChange, hidesWhitespace: Bool) {
        // The selectable lines were collected, and the selection carried
        // over and compared, off the main actor: for a 10,000,000-line diff,
        // either blocked it for seconds. The file's selection is still the
        // one the load started with unless the user changed it meanwhile
        // (comparing a selection with itself is quick).
        let selection: DiffSelection
        let changed: Bool
        if let carried = loaded.carried, carried.base == file.selection {
            (selection, changed) = (carried.carried, carried.changed)
        } else {
            selection = carrySelection(file.selection, to: loaded.full, selectableLines: loaded.selectableLines)
            changed = selection != file.selection
        }
        if changed {
            setLineSelection(selection, forFile: file.id)
        }
        diff = .loaded(loaded.shown)
        setFullDiff(loaded.full)
        fullDiffSelectableLines = loaded.selectableLines
        if diffIsTextConverted != loaded.isTextConverted {
            diffIsTextConverted = loaded.isTextConverted
        }
        if diffHidesWhitespace != hidesWhitespace {
            diffHidesWhitespace = hidesWhitespace
        }
    }

    /// Records a failed diff load.
    func diffDidFail(_ error: OperationError) {
        diff = .failed(error)
        setFullDiff(nil)
        fullDiffSelectableLines = []
    }

    /// Sets `fullDiff`, bumping `diffGeneration` unless its lines stay the
    /// same (a refresh reloading an unchanged file keeps the generation, and
    /// the diff already there, whose hunks a partial selection's
    /// `diffHunks` share).
    private func setFullDiff(_ full: Diff?) {
        let sameLines = hasSameLines(fullDiff, full)
        if sameLines, textDiffData(full) != nil {
            return
        }
        if !sameLines {
            diffGeneration &+= 1
        }
        fullDiff = full
    }

    // MARK: Files

    func setFiles(_ files: [WorkingDirectoryFileChange]) {
        let updated = WorkingDirectoryStatus.fromFiles(files)
        if updated != workingDirectory {
            workingDirectory = updated
        }
    }
}
