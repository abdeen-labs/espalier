// Ported from desktop/app/src/ui/changes/filter-changes-logic.ts
//
// The filter is applied in the model, so the commit gate that asks before
// committing hidden files and the list the user sees can't disagree.

import EspalierSupport
import GitKit

/// The changes list's filter. Every active criterion must match (AND).
public struct FileListFilter: Sendable, Equatable {
    /// Matched against each file's path, fuzzily, ignoring case.
    public var text = ""
    /// Files the next commit includes, in full or in part.
    public var includedInCommit = false
    /// Files the next commit excludes.
    public var excludedFromCommit = false
    /// New and untracked files.
    public var newFiles = false
    /// Modified files (not renamed, copied, or conflicted ones).
    public var modifiedFiles = false
    /// Deleted files.
    public var deletedFiles = false

    public init(
        text: String = "",
        includedInCommit: Bool = false,
        excludedFromCommit: Bool = false,
        newFiles: Bool = false,
        modifiedFiles: Bool = false,
        deletedFiles: Bool = false
    ) {
        self.text = text
        self.includedInCommit = includedInCommit
        self.excludedFromCommit = excludedFromCommit
        self.newFiles = newFiles
        self.modifiedFiles = modifiedFiles
        self.deletedFiles = deletedFiles
    }

    /// Count the number of active filter options
    /// Note: This does not include the filterText filter
    public var activeOptionCount: Int {
        [includedInCommit, newFiles, modifiedFiles, deletedFiles, excludedFromCommit].filter { $0 }.count
    }

    /// Check if there are any active filters
    public var hasActiveFilters: Bool {
        !text.isEmpty || activeOptionCount > 0
    }

    /// Apply filter options to determine if a file should be shown
    /// Uses AND logic - file must satisfy ALL active filters
    /// Note: This is applied after the filterText has been applied
    public func matchesOptions(_ change: WorkingDirectoryFileChange) -> Bool {
        // If no filters are active, show all files
        if activeOptionCount == 0 {
            return true
        }

        if includedInCommit, change.isExcludedFromCommit() {
            return false
        }

        if excludedFromCommit, !change.isExcludedFromCommit() {
            return false
        }

        if newFiles, !change.isNew(), !change.isUntracked() {
            return false
        }

        if modifiedFiles, !change.isModified() {
            return false
        }

        if deletedFiles, !change.isDeleted() {
            return false
        }

        // File matches all active filters
        return true
    }

    /// Whether the file's path matches the text: always with no text,
    /// otherwise the text lowercased, then fuzzaldrin-plus's `match` on the
    /// path.
    public func matchesText(_ change: WorkingDirectoryFileChange) -> Bool {
        textQuery?.matches(change.path) ?? true
    }

    /// The text prepared for matching, nil without text.
    var textQuery: FuzzyQuery? {
        FuzzyQuery(JSCompat.toLowerCase(text))
    }

    /// Whether the list shows the file: its path matches the text and it
    /// satisfies every active option.
    public func matches(_ change: WorkingDirectoryFileChange) -> Bool {
        matchesOptions(change) && matchesText(change)
    }

    /// Generate message when no files match filters
    public var noResultsMessage: String? {
        if !hasActiveFilters {
            return nil
        }

        var activeFilters: [String] = []

        if !text.isEmpty {
            activeFilters.append("\"\(text)\"")
        }

        if includedInCommit {
            activeFilters.append("Included in commit")
        }

        if excludedFromCommit {
            activeFilters.append("Excluded from commit")
        }

        if newFiles {
            activeFilters.append("New files")
        }

        if modifiedFiles {
            activeFilters.append("Modified files")
        }

        if deletedFiles {
            activeFilters.append("Deleted files")
        }

        if activeFilters.isEmpty {
            return nil
        }

        // Format the list with proper grammar (e.g., "A, B, and C")
        let filterList: String
        switch activeFilters.count {
        case 1:
            filterList = activeFilters[0]
        case 2:
            filterList = "\(activeFilters[0]) and \(activeFilters[1])"
        default:
            let lastFilter = activeFilters[activeFilters.count - 1]
            let otherFilters = activeFilters.dropLast()
            filterList = "\(otherFilters.joined(separator: ", ")), and \(lastFilter)"
        }
        return "No changed files match these filters: \(filterList)"
    }
}

// MARK: - The selection a filter keeps

/// The selection a list keeps while a filter is active, as the filter or
/// the items change: the selected items it lists, in the selection's
/// order; when it lists none of them (or nothing is selected), the first
/// item it lists, or none when it lists nothing. Nil when that's the
/// selection already. The Changes list, a stash's files, and a pull
/// request's files follow it.
public func filteredSelection(_ selected: [String], listed: [String]) -> [String]? {
    let wanted = selected.exactSet
    let listedSelected: Set<ExactString> = wanted.isEmpty ? [] : Set(listed.lazy.map(ExactString.init).filter(wanted.contains))
    let kept = selected.filter { listedSelected.contains(ExactString($0)) }
    if !kept.isEmpty {
        return kept.count == selected.count ? nil : kept
    }
    if let first = listed.first {
        return [first]
    }
    return selected.isEmpty ? nil : []
}

// MARK: - The list as the model shows it

/// How a file's checkbox shows its inclusion in the next commit.
public struct FileInclusionState: Sendable, Equatable {
    /// Included (true), excluded (false), or partly (nil).
    public let value: Bool?
    /// Whether the user can change it.
    public let isEnabled: Bool
    /// The tooltip explaining a submodule's inclusion, if any.
    public let help: String?

    public init(value: Bool?, isEnabled: Bool, help: String?) {
        self.value = value
        self.isEnabled = isEnabled
        self.help = help
    }
}

extension ChangesModel {
    /// Recomputes `visibleFiles` and `includedFilesHiddenByFilter` (when
    /// the files or the filter change, so a view reading them repeatedly
    /// doesn't match every path each time).
    func updateVisibleFiles() {
        let files = workingDirectory.files
        let visible: [WorkingDirectoryFileChange]
        if filter.hasActiveFilters {
            let filter = filter
            let query = filter.textQuery
            visible = files.filter { file in
                filter.matchesOptions(file) && (query?.matches(file.path) ?? true)
            }
        } else {
            visible = files
        }
        if visible != visibleFiles {
            visibleFiles = visible
        }

        var hidden: [WorkingDirectoryFileChange] = []
        if filter.hasActiveFilters, visible.count != files.count {
            let included = files.filter(\.isIncludedInCommit)
            let visibleIDs = visible.map(\.id).exactSet
            if isCommittingFileHiddenByFilter(included.map(\.id), visibleFileIDs: visibleIDs, fileCount: files.count, filter) {
                hidden = included.filter { !visibleIDs.contains(ExactString($0.id)) }
            }
        }
        if hidden != includedFilesHiddenByFilter {
            includedFilesHiddenByFilter = hidden
        }
    }

    /// The message to show when the filter matches no file, or nil.
    public var noResultsMessage: String? {
        guard !workingDirectory.files.isEmpty, visibleFiles.isEmpty else {
            return nil
        }
        return filter.noResultsMessage
    }

    /// Includes or excludes the files the list shows, leaving hidden ones
    /// alone (the header checkbox).
    public func setVisibleFilesIncluded(_ included: Bool) {
        setIncluded(visibleFiles.map(\.id), included)
    }

    /// The header checkbox's value for the files the list shows: during a
    /// rebase's conflicts, tracked files count as included and untracked ones
    /// (which the rebase skips) as excluded. Submodules that can't be
    /// committed don't count.
    public var visibleIncludeAll: Bool? {
        let files = visibleFiles
        let rebaseConflicts = isInRebaseConflicts
        if files.count == workingDirectory.files.count, !rebaseConflicts, !files.contains(where: \.isUncommittableSubmodule) {
            return workingDirectory.includeAll
        }

        if files.isEmpty {
            // the current commit will be skipped in the rebase
            return false
        }

        if rebaseConflicts {
            // untracked files will be skipped by the rebase, so we need to
            // ensure that the "Include All" checkbox matches this state
            if files.allSatisfy({ $0.status.kind == .untracked }) {
                return false
            }
            // show "Mixed" if we have a mixture of tracked and untracked
            // changes
            return files.allSatisfy { $0.status.kind != .untracked } ? true : nil
        }

        // `WorkingDirectoryStatus.fromFiles(files).includeAll`, without the
        // submodules that can't be committed.
        let types = files.filter { !$0.isUncommittableSubmodule }.map { $0.selection.getSelectionType() }
        if types.isEmpty {
            return false
        }
        if types.allSatisfy({ $0 == .all }) {
            return true
        }
        return types.allSatisfy { $0 == .none } ? false : nil
    }

    /// How `file`'s checkbox shows: a submodule whose only changes are
    /// uncommitted ones inside it can't be included; one with a new commit
    /// and uncommitted changes shows as partly included; during a rebase's
    /// conflicts tracked files show as included; nothing can change while a
    /// commit runs.
    public func inclusionState(of file: WorkingDirectoryFileChange) -> FileInclusionState {
        let submoduleStatus = file.status.submoduleStatus
        let isUncommittableSubmodule = file.isUncommittableSubmodule
        let isPartiallyCommittableSubmodule = submoduleStatus.map {
            ($0.commitChanged || file.status.kind == .new) && ($0.modifiedChanges || $0.untrackedChanges)
        } ?? false

        let includeAll: Bool? = switch file.selection.getSelectionType() {
        case .all: true
        case .none: false
        case .partial: nil
        }

        let rebaseConflicts = isInRebaseConflicts
        let include: Bool? = if isUncommittableSubmodule {
            false
        } else if rebaseConflicts {
            file.status.kind != .untracked
        } else {
            includeAll
        }

        let isCommitting = repository?.commit.isCommitting ?? false
        let help: String? = if isUncommittableSubmodule {
            "This submodule has uncommitted changes, so its change can't be committed here."
        } else if isPartiallyCommittableSubmodule {
            "Only changes committed inside the submodule are added to this repository. Commit its other modified or untracked changes in the submodule first."
        } else {
            nil
        }

        return FileInclusionState(
            value: isPartiallyCommittableSubmodule && include == true ? nil : include,
            isEnabled: !(isCommitting || rebaseConflicts || isUncommittableSubmodule),
            help: help
        )
    }

    /// Whether a rebase stopped on conflicts.
    private var isInRebaseConflicts: Bool {
        if case .rebase? = repository?.operations.conflictState { true } else { false }
    }
}

/// Check if any files being committed are hidden by the current filter.
///
/// - Parameters:
///   - fileIDsIncludedInCommit: The files whose selection isn't none.
///   - visibleFileIDs: The files the list shows.
///   - fileCount: How many changed files there are.
func isCommittingFileHiddenByFilter(
    _ fileIDsIncludedInCommit: [String],
    visibleFileIDs: Set<ExactString>,
    fileCount: Int,
    _ filter: FileListFilter
) -> Bool {
    // All possible files are present in the list (no active filters or all files match active filters)
    if !filter.hasActiveFilters || visibleFileIDs.count == fileCount {
        return false
    }

    // If filtered rows count is 1 and included for commit rows count is 2,
    // there is no way the included for commit rows are visible regardless of
    // what they are.
    if fileIDsIncludedInCommit.count > visibleFileIDs.count {
        return true
    }

    // If we can find a file id included in the commit that does not exist in
    // the filtered items, then we are committing a hidden file.
    return fileIDsIncludedInCommit.contains { !visibleFileIDs.contains(ExactString($0)) }
}

// MARK: - Fuzzy matching

/// The characters fuzzaldrin-plus treats as optional in a query
/// (`opt_char_re`, `/[ _\-:\/\\]/g`): a match needn't contain them.
private let optionalQueryCharacters: Set<UInt16> = [0x20, 0x5F, 0x2D, 0x3A, 0x2F, 0x5C]

/// A query prepared for matching many texts: fuzzaldrin-plus's `Query`.
///
/// `matches(_:)` is whether fuzzaldrin-plus's `match(text, query)` returns
/// any match, which is what puts an item in a filtered list. Code units
/// are compared, as JavaScript does.
///
/// fuzzaldrin-plus first requires the query's non-optional characters
/// (`isMatch`) to appear in the text in order, each matching its lowercase
/// or (truncated) uppercase form. Its alignment then finds at least one
/// matched character exactly when some lowercased query character equals
/// some lowercased text character: its scores only grow along the matrix,
/// so the traceback from a positive score always reaches a diagonal step.
/// No score is computed; the list keeps the files' order.
public struct FuzzyQuery: Sendable {
    private let units: [UInt16]
    /// The non-optional characters, lowercased and (truncated) uppercased.
    private let coreLower: [UInt16]
    private let coreUpper: [UInt16]
    /// The whole query's lowercased code units.
    private let lowerUnits: Set<UInt16>

    /// Nil for an empty query, which matches nothing in fuzzaldrin-plus
    /// (`return [] unless query`); filters skip an empty text instead.
    public init?(_ query: String) {
        guard !query.isEmpty else {
            return nil
        }
        units = Array(query.utf16)
        let core = String(decoding: query.utf16.filter { !optionalQueryCharacters.contains($0) }, as: UTF16.self)
        coreLower = Array(JSCompat.toLowerCase(core).utf16)
        coreUpper = truncatedUpperCase(core)
        lowerUnits = Set(JSCompat.toLowerCase(query).utf16)
    }

    public func matches(_ text: String) -> Bool {
        let subject = text.utf16
        // `return [] unless string`
        if subject.isEmpty {
            return false
        }
        // `return [0...string.length] if string is query`
        if subject.elementsEqual(units) {
            return true
        }
        guard isMatch(subject) else {
            return false
        }

        // `computeMatch` over the lowercased query and text, as far as the
        // text's original length (`m = subject.length`).
        let length = subject.count
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            return subject.contains { lowerUnits.contains(asciiLowercased($0)) }
        }
        return JSCompat.toLowerCase(text).utf16.prefix(length).contains { lowerUnits.contains($0) }
    }

    /// fuzzaldrin-plus's `isMatch`: every query character, in order, equal
    /// to its lowercase or uppercase form in the subject.
    private func isMatch(_ subject: String.UTF16View) -> Bool {
        let n = coreLower.count
        if n > subject.count {
            return false
        }
        var units = subject.makeIterator()
        for j in 0..<n {
            let lower = coreLower[j]
            let upper = j < coreUpper.count ? coreUpper[j] : lower
            var found = false
            while let unit = units.next() {
                if unit == lower || unit == upper {
                    found = true
                    break
                }
            }
            if !found {
                return false
            }
        }
        return true
    }

    private func asciiLowercased(_ unit: UInt16) -> UInt16 {
        (0x41...0x5A).contains(unit) ? unit + 0x20 : unit
    }
}

/// fuzzaldrin-plus's `truncatedUpperCase`: each code unit uppercased, keeping
/// only the first code unit of the result. A lone surrogate stays itself, as
/// JavaScript's `toUpperCase` leaves it.
private func truncatedUpperCase(_ string: String) -> [UInt16] {
    string.utf16.map { unit in
        if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) {
            return unit
        }
        let character = String(decoding: [unit], as: UTF16.self)
        return character.uppercased().utf16.first ?? unit
    }
}

extension WorkingDirectoryFileChange {
    /// Whether this is a submodule whose only changes are uncommitted ones
    /// inside it: the repository can't commit them, so it's never included,
    /// whatever its selection.
    public var isUncommittableSubmodule: Bool {
        status.submoduleStatus.map { status.kind == .modified && !$0.commitChanged } ?? false
    }

    /// Whether the next commit includes this file: its selection isn't none
    /// and it isn't a submodule the repository can't commit.
    public var isIncludedInCommit: Bool {
        selection.getSelectionType() != .none && !isUncommittableSubmodule
    }
}
