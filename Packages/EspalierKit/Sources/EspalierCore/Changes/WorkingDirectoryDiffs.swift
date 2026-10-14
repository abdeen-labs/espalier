// Hiding whitespace keeps partial line selections: the selection's line
// indexes always refer to the full diff, which is loaded alongside the `-w`
// one and is what staging uses; selections can't be edited while
// whitespace is hidden. Line ranges come from GitKit's DiffExplorer.swift.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "changes")

/// Identifies one load of the selected file's diff.
struct DiffLoadKey: Hashable, Sendable {
    let fileID: String
    let hidesWhitespace: Bool
    let sequence: UInt64
}

/// A file's diff as shown, and in full (the same diff unless whitespace is
/// hidden).
struct LoadedDiffs: Sendable, Equatable {
    let shown: Diff
    let full: Diff
    /// Whether a `diff` driver's textconv converted the text (GitKit's
    /// `isTextConverted`): its lines aren't the file's, so none can be
    /// selected or discarded alone.
    let isTextConverted: Bool
    /// `full`'s added and deleted lines (`selectableLines(in:)`), collected
    /// with the load, off the main actor.
    let selectableLines: Set<Int>
    /// The file's selection when the load started, and that selection
    /// pruned to `selectableLines`, with whether pruning changed it: worked
    /// out off the main actor, since comparing two selections of a
    /// 10,000,000-line diff takes seconds. Nil without a file.
    let pruning: (base: DiffSelection, pruned: DiffSelection, changed: Bool)?

    init(shown: Diff, full: Diff, isTextConverted: Bool = false, for file: WorkingDirectoryFileChange? = nil) {
        self.shown = shown
        self.full = full
        self.isTextConverted = isTextConverted
        let lines = EspalierCore.selectableLines(in: full)
        selectableLines = lines
        pruning = file.map { file in
            let pruned = file.selection.withSelectableLines(lines)
            return (file.selection, pruned, pruned != file.selection)
        }
    }

    static func == (lhs: LoadedDiffs, rhs: LoadedDiffs) -> Bool {
        lhs.shown == rhs.shown && lhs.full == rhs.full && lhs.isTextConverted == rhs.isTextConverted
    }
}

/// Loads a working directory file's diff: the one to show and the full one.
@concurrent
func loadWorkingDirectoryDiffs(
    _ repository: Repository,
    _ file: WorkingDirectoryFileChange,
    hidesWhitespace: Bool
) async throws -> LoadedDiffs {
    async let isTextConverted = file.status.submoduleStatus == nil ? GitKit.isTextConverted(repository, file.path) : false
    guard hidesWhitespace else {
        let diff = try await getWorkingDirectoryDiff(repository, file)
        return LoadedDiffs(shown: diff, full: diff, isTextConverted: await isTextConverted, for: file)
    }
    async let shown = getWorkingDirectoryDiff(repository, file, hideWhitespaceInDiff: true)
    async let full = getWorkingDirectoryDiff(repository, file)
    return try await LoadedDiffs(shown: shown, full: full, isTextConverted: isTextConverted, for: file)
}

/// The text of a text diff, large or not.
func textDiffData(_ diff: Diff?) -> (any TextDiffData)? {
    switch diff {
    case .text(let text)?: text
    case .largeText(let text)?: text
    default: nil
    }
}

/// Whether two diffs have the same lines at the same indexes: text diffs of
/// the same text with the same last hunk (the text leaves out "No newline at
/// end of file", which only the last hunk has), or neither a text diff.
func hasSameLines(_ x: Diff?, _ y: Diff?) -> Bool {
    switch (textDiffData(x), textDiffData(y)) {
    case (nil, nil):
        true
    case (let x?, let y?):
        ExactString(x.text) == ExactString(y.text) && x.hunks.count == y.hunks.count && x.hunks.last == y.hunks.last
    default:
        false
    }
}

/// The lines of a diff that can be included in a commit, by index in the
/// diff (`hunk.unifiedDiffStart` plus the line's index in its hunk): added
/// and deleted lines of a text diff; other diffs have none.
func selectableLines(in diff: Diff?) -> Set<Int> {
    guard let text = textDiffData(diff) else {
        return []
    }
    var lines = Set<Int>()
    for hunk in text.hunks {
        for (index, line) in hunk.lines.enumerated() where line.isIncludeableLine() {
            lines.insert(hunk.unifiedDiffStart + index)
        }
    }
    return lines
}

/// Lines of the selected file's diff, by their index in the full diff
/// (`hunk.unifiedDiffStart` plus the line's index in its hunk).
public enum DiffLines: Sendable, Hashable {
    /// One line.
    case line(Int)
    /// The lines from one index through another, as a drag down the gutter
    /// covers them.
    case range(ClosedRange<Int>)
    /// The run of added and deleted lines around a line, up to the context
    /// lines on either side.
    case block(containing: Int)
    /// Every added and deleted line of the hunk containing a line (the hunk
    /// header's checkbox).
    case hunk(containing: Int)
}

extension ChangesModel {
    // MARK: Whitespace

    /// Whether the changes diff hides whitespace changes
    /// (`hide-whitespace-in-changes-diff`).
    public var hidesWhitespace: Bool {
        repository?.app?.preferences.hideWhitespaceInChangesDiff ?? false
    }

    /// Hides or shows whitespace changes in the changes diff, and reloads
    /// it. Partial line selections are kept; they can't be edited while
    /// whitespace is hidden.
    public func setHidesWhitespace(_ hide: Bool) {
        guard let preferences = repository?.app?.preferences else {
            return
        }
        if preferences.hideWhitespaceInChangesDiff != hide {
            preferences.hideWhitespaceInChangesDiff = hide
        }
        reloadDiffIfWhitespaceChanged()
    }

    /// Reloads the diff when the preference changes elsewhere (Settings).
    func observeWhitespacePreference() {
        guard let preferences = repository?.app?.preferences else {
            return
        }
        withObservationTracking {
            _ = preferences.hideWhitespaceInChangesDiff
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadDiffIfWhitespaceChanged()
                self?.observeWhitespacePreference()
            }
        }
    }

    private func reloadDiffIfWhitespaceChanged() {
        guard let key = diffLoads.currentKey, key.hidesWhitespace != hidesWhitespace else {
            return
        }
        loadSelectedDiff()
    }

    // MARK: Loading

    /// Loads (or reloads) the diff of the selected file, when exactly one
    /// working directory file is selected; otherwise forgets the diff.
    ///
    /// A load that's no longer the latest never applies (a newer selection,
    /// status, or whitespace setting started another), and a result applies
    /// only while its file is still the one selected. The file's partial
    /// selection is then pruned to the lines that can still be selected,
    /// computed from the full diff.
    func loadSelectedDiff() {
        guard case .workingDirectory(let fileIDs) = selection, fileIDs.count == 1,
              let file = workingDirectory.findFileWithID(fileIDs[0]), let repository
        else {
            clearDiff()
            return
        }
        // Diffs load while the repository is selected (status passes also
        // run for the others' indicators); its selection's refresh loads it.
        guard repository.isActive else {
            if let diffFileID, !JSCompat.strictEquals(diffFileID, file.id) {
                clearDiff()
            }
            return
        }

        let hidesWhitespace = hidesWhitespace
        diffLoadSequence &+= 1
        let key = DiffLoadKey(fileID: file.id, hidesWhitespace: hidesWhitespace, sequence: diffLoadSequence)
        diffLoadDidStart(fileID: file.id, hidesWhitespace: hidesWhitespace)

        let gitRepository = repository.gitRepository
        let environment = repository.environment
        let record = repository.record
        let loadDiffs = loadDiffs
        diffLoads.run(key, operation: {
            await environment.withRuntimes {
                do {
                    return .success(try await loadDiffs(gitRepository, file, hidesWhitespace))
                } catch {
                    return .failure(await classifyLoadFailure(error, kind: .loadChangesDiff, record: record))
                }
            }
        }, apply: { [weak self] (result: Result<Result<LoadedDiffs, OperationError>, any Error>) in
            guard let self,
                  case .workingDirectory(let fileIDs) = self.selection, fileIDs.count == 1,
                  JSCompat.strictEquals(fileIDs[0], key.fileID),
                  let current = self.workingDirectory.findFileWithID(key.fileID),
                  case .success(let loaded) = result
            else {
                return
            }
            switch loaded {
            case .success(let diffs):
                self.diffDidLoad(diffs, for: current, hidesWhitespace: key.hidesWhitespace)
            case .failure(let error):
                logger.error("Could not load the diff: \(error.message, privacy: .private)")
                self.diffDidFail(error)
            }
        })
    }

    /// Waits for the diff load in flight (for tests).
    func diffIdle() async {
        await diffLoads.idle()
    }

    // MARK: Line selection

    /// The file whose diff is shown, if it's the selected one.
    var shownFile: WorkingDirectoryFileChange? {
        guard let fileID = diffFileID, case .workingDirectory(let fileIDs) = selection, fileIDs.count == 1,
              JSCompat.strictEquals(fileIDs[0], fileID)
        else {
            return nil
        }
        return workingDirectory.findFileWithID(fileID)
    }

    /// Whether lines of the selected file can be included or excluded now:
    /// its text diff is loaded, whitespace changes show, no commit is
    /// running, and the file isn't conflicted (or in a rebase's conflicts,
    /// whose files Espalier stages itself), and its lines are the file's
    /// bytes (UTF-8 text, not a diff driver's converted text; GitKit's
    /// `isByteExact` and `isTextConverted`).
    public var canSelectLines: Bool {
        guard case .loaded = diff, !diffHidesWhitespace, !hidesWhitespace, !diffIsTextConverted,
              let file = shownFile, let text = textDiffData(fullDiff), isByteExact(text),
              file.status.kind != .conflicted
        else {
            return false
        }
        if repository?.localOperation?.kind == .commit {
            return false
        }
        if case .rebase? = repository?.operations.conflictState {
            return false
        }
        return true
    }

    /// The indexes `lines` covers in the shown file's full diff, from its
    /// first to its last added or deleted line; nil when it covers none (a
    /// context line, a line outside the diff).
    public func range(of lines: DiffLines) -> ClosedRange<Int>? {
        guard let text = textDiffData(fullDiff) else {
            return nil
        }
        return lineRange(of: lines, in: text.hunks)
    }

    /// How much of `lines` the next commit includes: `.all`, `.none`, or
    /// `.partial`. Nil when `lines` covers no added or deleted line.
    public func inclusion(of lines: DiffLines) -> DiffSelectionType? {
        guard let file = shownFile, let text = textDiffData(fullDiff),
              let range = lineRange(of: lines, in: text.hunks)
        else {
            return nil
        }
        return inclusionType(of: range, in: text.hunks, file.selection)
    }

    /// Whether line indexes taken from the diff of `generation` name the
    /// same lines in the current one (nil: they were taken from it).
    func isCurrentDiff(_ generation: Int?) -> Bool {
        generation.map { $0 == diffGeneration } ?? true
    }

    /// Includes or excludes `lines` of the selected file in the next commit.
    ///
    /// - Parameter generation: The `diffGeneration` of the diff the indexes
    ///   were taken from; nil for the current one.
    /// - Returns: Whether the selection changed; false while lines can't be
    ///   selected (`canSelectLines`), or when the diff changed since
    ///   `generation`.
    @discardableResult
    public func setLines(_ lines: DiffLines, included: Bool, inDiff generation: Int? = nil) -> Bool {
        guard canSelectLines, isCurrentDiff(generation), let file = shownFile, let text = textDiffData(fullDiff),
              let range = lineRange(of: lines, in: text.hunks)
        else {
            return false
        }
        let selection = file.selection
            .withSelectableLines(fullDiffSelectableLines)
            .withRangeSelection(from: range.lowerBound, length: range.count, selected: included)
        guard selection != file.selection else {
            return false
        }
        setLineSelection(selection, forFile: file.id)
        return true
    }

    /// Toggles `lines`: a line flips; a range, block, or hunk is excluded
    /// when the commit includes all of it, and included otherwise.
    ///
    /// - Parameter generation: As `setLines(_:included:inDiff:)`'s.
    /// - Returns: Whether the selection changed.
    @discardableResult
    public func toggleLines(_ lines: DiffLines, inDiff generation: Int? = nil) -> Bool {
        guard isCurrentDiff(generation), let file = shownFile, let current = inclusion(of: lines) else {
            return false
        }
        let included: Bool
        if case .line(let index) = lines {
            included = !file.selection.isSelected(index)
        } else {
            included = current != .all
        }
        return setLines(lines, included: included, inDiff: generation)
    }

    /// The selection to draw on the shown diff's lines: the file's own, or,
    /// while whitespace is hidden, the same choices mapped onto the `-w`
    /// diff's lines (an added or deleted line keeps its line number in both
    /// diffs).
    public var diffSelection: DiffSelection? {
        guard let fileID = diffFileID, let file = workingDirectory.findFileWithID(fileID), let shown = diff.value else {
            return nil
        }
        guard diffHidesWhitespace else {
            return file.selection
        }
        guard let full = textDiffData(fullDiff), let shownText = textDiffData(shown) else {
            return nil
        }
        return mapSelection(file.selection, from: full, to: shownText)
    }

    /// The title of the action that discards `lines`: "Discard Added Line",
    /// "Discard Removed Lines", "Discard Modified Lines", with an ellipsis
    /// while discarding asks first (`confirmDiscardChanges`). Nil when there's
    /// nothing to discard, or the diff changed since `generation` (as
    /// `setLines(_:included:inDiff:)`'s).
    public func discardTitle(for lines: DiffLines, inDiff generation: Int? = nil) -> String? {
        guard isCurrentDiff(generation), let text = textDiffData(fullDiff), let range = lineRange(of: lines, in: text.hunks),
              let type = rangeType(of: range, in: text.hunks)
        else {
            return nil
        }
        let suffix = (repository?.app?.preferences.confirmDiscardChanges ?? true) ? "…" : ""
        let name = switch type {
        case .additions: "Added"
        case .deletions: "Removed"
        case .mixed: "Modified"
        }
        let lineCount = changedLineCount(in: range, hunks: text.hunks)
        let plural = lineCount > 1 ? "s" : ""
        return "Discard \(name) Line\(plural)\(suffix)"
    }
}

// MARK: - Line ranges

/// The added or deleted line at `index`, if any.
private func includeableLine(at index: Int, in hunks: [DiffHunk]) -> DiffLine? {
    guard let hunk = diffHunkForIndex(hunks, index) else {
        return nil
    }
    let relative = index - hunk.unifiedDiffStart
    guard hunk.lines.indices.contains(relative), hunk.lines[relative].isIncludeableLine() else {
        return nil
    }
    return hunk.lines[relative]
}

/// The indexes of the added and deleted lines in `range`.
private func changedLineIndexes(in range: ClosedRange<Int>, hunks: [DiffHunk]) -> [Int] {
    var indexes: [Int] = []
    for hunk in hunks where hunk.unifiedDiffEnd >= range.lowerBound && hunk.unifiedDiffStart <= range.upperBound {
        for (offset, line) in hunk.lines.enumerated() where line.isIncludeableLine() {
            let index = hunk.unifiedDiffStart + offset
            if range.contains(index) {
                indexes.append(index)
            }
        }
    }
    return indexes
}

private func changedLineCount(in range: ClosedRange<Int>, hunks: [DiffHunk]) -> Int {
    changedLineIndexes(in: range, hunks: hunks).count
}

/// The indexes `lines` covers, trimmed to its first and last added or
/// deleted line.
func lineRange(of lines: DiffLines, in hunks: [DiffHunk]) -> ClosedRange<Int>? {
    let candidate: ClosedRange<Int>
    switch lines {
    case .line(let index):
        guard includeableLine(at: index, in: hunks) != nil else {
            return nil
        }
        return index...index
    case .range(let range):
        candidate = range
    case .block(let index):
        // A block starts only from a changed line: from a context line,
        // `findInteractiveDiffRange`'s range would run into the next block.
        guard includeableLine(at: index, in: hunks) != nil,
              let range = findInteractiveDiffRange(hunks, index), range.type != nil, range.from <= range.to
        else {
            return nil
        }
        candidate = range.from...range.to
    case .hunk(let index):
        guard let hunk = diffHunkForIndex(hunks, index), hunk.unifiedDiffStart <= hunk.unifiedDiffEnd else {
            return nil
        }
        candidate = hunk.unifiedDiffStart...hunk.unifiedDiffEnd
    }
    let changed = changedLineIndexes(in: candidate, hunks: hunks)
    guard let first = changed.first, let last = changed.last else {
        return nil
    }
    return first...last
}

/// Whether the added and deleted lines of `range` are all, none, or some
/// selected.
func inclusionType(of range: ClosedRange<Int>, in hunks: [DiffHunk], _ selection: DiffSelection) -> DiffSelectionType? {
    let indexes = changedLineIndexes(in: range, hunks: hunks)
    guard !indexes.isEmpty else {
        return nil
    }
    let selectedCount = indexes.filter { selection.isSelected($0) }.count
    if selectedCount == indexes.count {
        return .all
    }
    return selectedCount == 0 ? DiffSelectionType.none : .partial
}

/// Whether `range` holds only added lines, only deleted lines, or both.
private func rangeType(of range: ClosedRange<Int>, in hunks: [DiffHunk]) -> DiffRangeType? {
    var hasAdditions = false
    var hasDeletions = false
    for index in changedLineIndexes(in: range, hunks: hunks) {
        guard let line = includeableLine(at: index, in: hunks) else {
            continue
        }
        if line.type == .add {
            hasAdditions = true
        } else {
            hasDeletions = true
        }
    }
    switch (hasAdditions, hasDeletions) {
    case (true, true): return .mixed
    case (true, false): return .additions
    case (false, true): return .deletions
    case (false, false): return nil
    }
}

// MARK: - Mapping a selection onto the whitespace-hidden diff

/// An added line by its new line number, or a deleted one by its old line
/// number: the same in the full and `-w` diffs of one file.
private struct ChangedLineKey: Hashable {
    let type: DiffLineType
    let number: Int?

    init(_ line: DiffLine) {
        type = line.type
        number = line.type == .add ? line.newLineNumber : line.oldLineNumber
    }
}

/// The selection `selection` (of the full diff's lines) as a selection of
/// the shown diff's lines. A line the full diff doesn't have reads as
/// excluded.
func mapSelection(_ selection: DiffSelection, from full: some TextDiffData, to shown: some TextDiffData) -> DiffSelection {
    var selectedByLine: [ChangedLineKey: Bool] = [:]
    for hunk in full.hunks {
        for (offset, line) in hunk.lines.enumerated() where line.isIncludeableLine() {
            selectedByLine[ChangedLineKey(line)] = selection.isSelected(hunk.unifiedDiffStart + offset)
        }
    }

    var selectable = Set<Int>()
    var selected: [Int] = []
    for hunk in shown.hunks {
        for (offset, line) in hunk.lines.enumerated() where line.isIncludeableLine() {
            let index = hunk.unifiedDiffStart + offset
            selectable.insert(index)
            if selectedByLine[ChangedLineKey(line)] == true {
                selected.append(index)
            }
        }
    }

    // Consecutive lines go in one range, so a large diff takes few updates.
    var runs: [ClosedRange<Int>] = []
    for index in selected.sorted() {
        if let last = runs.last, last.upperBound + 1 == index {
            runs[runs.count - 1] = last.lowerBound...index
        } else {
            runs.append(index...index)
        }
    }
    var mapped = DiffSelection.fromInitialSelection(.none).withSelectableLines(selectable)
    for run in runs {
        mapped = mapped.withRangeSelection(from: run.lowerBound, length: run.count, selected: true)
    }
    return mapped
}

// MARK: - Load failures

/// An `OperationError` for a failed read-only load, classified as an
/// operation's failure would be (without its side effects).
func classifyLoadFailure(_ error: any Error, kind: OperationKind, record: RepositoryRecord) async -> OperationError {
    await ErrorClassifier.classify(
        error,
        descriptor: OperationDescriptor(kind: kind, lanes: []),
        record: record,
        context: ClassificationContext()
    )
}
