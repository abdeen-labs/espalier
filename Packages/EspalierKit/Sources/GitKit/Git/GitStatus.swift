// Ported from desktop/app/src/lib/git/status.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "status")

/// The encapsulation of the result from 'git status'
public struct StatusResult: Hashable, Sendable {
    /// The name of the current branch
    public let currentBranch: String?

    /// The name of the current upstream branch
    public let currentUpstreamBranch: String?

    /// The SHA of the tip commit of the current branch
    public let currentTip: String?

    /// How many commits ahead and behind
    /// the `currentBranch` is compared to the `currentUpstreamBranch`
    public let branchAheadBehind: AheadBehind?

    /// true if the repository exists at the given location
    public let exists: Bool

    /// true if repository is in a conflicted state
    public let mergeHeadFound: Bool

    /// true merge --squash operation started
    public let squashMsgFound: Bool

    /// details about the rebase operation, if found
    public let rebaseInternalState: RebaseInternalState?

    /// true if repository is in cherry pick state
    public let isCherryPickingHeadFound: Bool

    /// true if a revert stopped on conflicts (`REVERT_HEAD`).
    public let isRevertHeadFound: Bool

    /// the absolute path to the repository's working directory
    public let workingDirectory: WorkingDirectoryStatus

    /// whether conflicting files present on repository
    public let doConflictedFilesExist: Bool

    public init(
        currentBranch: String? = nil,
        currentUpstreamBranch: String? = nil,
        currentTip: String? = nil,
        branchAheadBehind: AheadBehind? = nil,
        exists: Bool,
        mergeHeadFound: Bool,
        squashMsgFound: Bool,
        rebaseInternalState: RebaseInternalState?,
        isCherryPickingHeadFound: Bool,
        workingDirectory: WorkingDirectoryStatus,
        doConflictedFilesExist: Bool
    ) {
        self.init(
            currentBranch: currentBranch,
            currentUpstreamBranch: currentUpstreamBranch,
            currentTip: currentTip,
            branchAheadBehind: branchAheadBehind,
            exists: exists,
            mergeHeadFound: mergeHeadFound,
            squashMsgFound: squashMsgFound,
            rebaseInternalState: rebaseInternalState,
            isCherryPickingHeadFound: isCherryPickingHeadFound,
            isRevertHeadFound: false,
            workingDirectory: workingDirectory,
            doConflictedFilesExist: doConflictedFilesExist
        )
    }

    public init(
        currentBranch: String? = nil,
        currentUpstreamBranch: String? = nil,
        currentTip: String? = nil,
        branchAheadBehind: AheadBehind? = nil,
        exists: Bool,
        mergeHeadFound: Bool,
        squashMsgFound: Bool,
        rebaseInternalState: RebaseInternalState?,
        isCherryPickingHeadFound: Bool,
        isRevertHeadFound: Bool,
        workingDirectory: WorkingDirectoryStatus,
        doConflictedFilesExist: Bool
    ) {
        self.currentBranch = currentBranch
        self.currentUpstreamBranch = currentUpstreamBranch
        self.currentTip = currentTip
        self.branchAheadBehind = branchAheadBehind
        self.exists = exists
        self.mergeHeadFound = mergeHeadFound
        self.squashMsgFound = squashMsgFound
        self.rebaseInternalState = rebaseInternalState
        self.isCherryPickingHeadFound = isCherryPickingHeadFound
        self.isRevertHeadFound = isRevertHeadFound
        self.workingDirectory = workingDirectory
        self.doConflictedFilesExist = doConflictedFilesExist
    }
}

private struct StatusHeadersData {
    var currentBranch: String?
    var currentUpstreamBranch: String?
    var currentTip: String?
    var branchAheadBehind: AheadBehind?
}

/// Paths compare exactly.
private struct ConflictFilesDetails {
    var conflictCountsByPath: [ExactString: Int]
    var binaryFilePaths: Set<ExactString>
    /// The line numbers of each file's markers (`getConflictMarkerLines`).
    var conflictMarkerLinesByPath: [ExactString: [Int]] = [:]
    /// The conflicts in each conflicted file with markers: the markers that
    /// open one (`conflictCountsByPath` counts every marker).
    var conflictsByPath: [ExactString: Int] = [:]

    init(conflictCountsByPath: [ExactString: Int], binaryFilePaths: Set<ExactString>) {
        self.conflictCountsByPath = conflictCountsByPath
        self.binaryFilePaths = binaryFilePaths
    }

    /// The details for the markers at `conflictMarkerLinesByPath`, counted
    /// as `getFilesWithConflictMarkers` counts them.
    init(conflictMarkerLinesByPath: [ExactString: [Int]], binaryFilePaths: [String]) {
        self.conflictCountsByPath = conflictMarkerLinesByPath.mapValues(\.count)
        self.binaryFilePaths = Set(binaryFilePaths.map(ExactString.init))
        self.conflictMarkerLinesByPath = conflictMarkerLinesByPath
    }
}

private func parseConflictedState(
    _ entry: UnmergedEntry,
    _ path: String,
    _ conflictDetails: ConflictFilesDetails
) -> AppFileStatus {
    switch entry.action {
    case .bothAdded, .bothModified:
        let isBinary = conflictDetails.binaryFilePaths.contains(ExactString(path))
        if !isBinary {
            return .conflicted(.conflictsWithMarkers(
                entry: entry,
                conflictMarkerCount: conflictDetails.conflictCountsByPath[ExactString(path)] ?? 0,
                conflictCount: conflictDetails.conflictsByPath[ExactString(path)] ?? 0
            ))
        } else {
            return .conflicted(.manualConflict(entry: entry))
        }
    default:
        return .conflicted(.manualConflict(entry: entry))
    }
}

private func convertToAppStatus(
    _ path: String,
    _ entry: FileEntry,
    _ conflictDetails: ConflictFilesDetails,
    _ oldPath: String?
) throws -> AppFileStatus {
    switch entry {
    case .ordinary(let entry):
        switch entry.type {
        case .added:
            return .new(submoduleStatus: entry.submoduleStatus)
        case .modified:
            return .modified(submoduleStatus: entry.submoduleStatus)
        case .deleted:
            return .deleted(submoduleStatus: entry.submoduleStatus)
        }
    case .copied(let entry):
        if let oldPath {
            return .copied(
                oldPath: oldPath,
                renameIncludesModifications: false,
                submoduleStatus: entry.submoduleStatus
            )
        }
    case .renamed(let entry):
        if let oldPath {
            return .renamed(
                oldPath: oldPath,
                renameIncludesModifications: entry.workingTree == .modified
                    || (entry.renameOrCopyScore.map { $0 < 100 } ?? false),
                submoduleStatus: entry.submoduleStatus
            )
        }
    case .untracked(let entry):
        return .untracked(submoduleStatus: entry.submoduleStatus)
    case .conflicted(let entry):
        return parseConflictedState(entry, path, conflictDetails)
    }

    // A rename or copy without an old path, which git never reports.
    throw GitLibError("Unknown file status \(entry)")
}

// List of known conflicted index entries for a file, extracted from mapStatus
// inside `Lib/StatusParser.swift` for convenience
private let conflictStatusCodes: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

/// Retrieve the status for a given repository,
/// and fail gracefully if the location is not a Git repository
///
/// Returns nil when git exits with 128 (most likely no repository at the
/// path), unless `rejectOnError` is true, in which case that throws.
public func getStatus(
    _ repository: Repository,
    includeUntracked: Bool = true,
    rejectOnError: Bool = false
) async throws -> StatusResult? {
    let args = [
        "--no-optional-locks",
        "status",
    ] + (includeUntracked ? ["--untracked-files=all"] : []) + [
        "--branch",
        "--porcelain=2",
        "-z",
    ]

    let result = try await git(
        args,
        repository.path,
        "getStatus",
        options: GitExecutionOptions(successExitCodes: rejectOnError ? [0] : [0, 128])
    )

    if result.exitCode == 128 {
        logger.debug("'git status' returned 128 for '\(repository.path, privacy: .private)' and is likely missing its .git directory")
        return nil
    }

    let parsed = try parsePorcelainStatus(result.stdoutData)
    let headers = parsed.compactMap(\.header)
    let entries = parsed.compactMap(\.entry)

    let mergeHeadFound = await isMergeHeadSet(repository)
    let conflictedFilesInIndex = entries.filter { conflictStatusCodes.contains($0.statusCode) }
    let rebaseInternalState = await getRebaseInternalState(repository)

    let conflictDetails = try await getConflictDetails(
        repository,
        mergeHeadFound,
        conflictedFilesInIndex,
        rebaseInternalState
    )

    // Map of files keyed on their paths.
    var files = FileChangeMap()
    for entry in entries {
        try buildStatusMap(&files, entry, conflictDetails)
    }

    var headerData = StatusHeadersData()
    for header in headers {
        parseStatusHeader(&headerData, header)
    }

    let workingDirectory = WorkingDirectoryStatus.fromFiles(files.values)

    let isCherryPickingHeadFound = await isCherryPickHeadFound(repository)

    let squashMsgFound = await isSquashMsgSet(repository)

    let revertHeadFound = await isRevertHeadFound(repository)

    return StatusResult(
        currentBranch: headerData.currentBranch,
        currentUpstreamBranch: headerData.currentUpstreamBranch,
        currentTip: headerData.currentTip,
        branchAheadBehind: headerData.branchAheadBehind,
        exists: true,
        mergeHeadFound: mergeHeadFound,
        squashMsgFound: squashMsgFound,
        rebaseInternalState: rebaseInternalState,
        isCherryPickingHeadFound: isCherryPickingHeadFound,
        isRevertHeadFound: revertHeadFound,
        workingDirectory: workingDirectory,
        doConflictedFilesExist: !conflictedFilesInIndex.isEmpty
    )
}

/// Working directory changes keyed on exact paths, in insertion order.
/// Setting an existing path keeps its position; deleting one and setting it
/// again moves it to the end.
private struct FileChangeMap {
    private var slots: [WorkingDirectoryFileChange?] = []
    private var slotByPath: [ExactString: Int] = [:]

    mutating func delete(_ path: String) {
        if let slot = slotByPath.removeValue(forKey: ExactString(path)) {
            slots[slot] = nil
        }
    }

    mutating func set(_ path: String, _ file: WorkingDirectoryFileChange) {
        let key = ExactString(path)
        if let slot = slotByPath[key] {
            slots[slot] = file
        } else {
            slotByPath[key] = slots.count
            slots.append(file)
        }
    }

    var values: [WorkingDirectoryFileChange] {
        slots.compactMap { $0 }
    }
}

/// Update map of working directory changes with a file status entry.
/// Reducer(ish).
///
/// (Map is used here to maintain insertion order.)
private func buildStatusMap(
    _ files: inout FileChangeMap,
    _ entry: StatusEntry,
    _ conflictDetails: ConflictFilesDetails
) throws {
    let status = mapStatus(entry.statusCode, entry.submoduleStatusCode, entry.renameOrCopyScore)

    if case .ordinary(let ordinary) = status {
        // when a file is added in the index but then removed in the working
        // directory, the file won't be part of the commit, so we can skip
        // displaying this entry in the changes list
        if ordinary.index == .added, ordinary.workingTree == .deleted {
            return
        }
    }

    if case .untracked = status {
        // when a delete has been staged, but an untracked file exists with the
        // same path, we should ensure that we only draw one entry in the
        // changes list - see if an entry already exists for this path and
        // remove it if found
        files.delete(entry.path)
    }

    // for now we just poke at the existing summary
    let appStatus = try convertToAppStatus(entry.path, status, conflictDetails, entry.oldPath)

    let initialSelectionType: DiffSelectionType =
        if appStatus.kind == .modified, let submoduleStatus = appStatus.submoduleStatus, !submoduleStatus.commitChanged {
            .none
        } else {
            .all
        }

    let selection = DiffSelection.fromInitialSelection(initialSelectionType)

    files.set(entry.path, WorkingDirectoryFileChange(path: entry.path, status: appStatus, selection: selection))
}

// This intentionally does not match branch.oid initial
private let branchOidRe = JSCompat.regex(#"^branch\.oid ([a-f0-9]+)\z"#)
// The dots in the other three are unescaped, so they match any character.
private let branchHeadRe = JSCompat.regex("^branch\(JSCompat.dot)head (\(JSCompat.dot)*)")
private let branchUpstreamRe = JSCompat.regex("^branch\(JSCompat.dot)upstream (\(JSCompat.dot)*)")
private let branchAheadBehindRe = JSCompat.regex(#"^branch"# + JSCompat.dot + #"ab \+([0-9]+) -([0-9]+)\z"#)

/// Update status header based on the current header entry.
/// Reducer.
private func parseStatusHeader(_ results: inout StatusHeadersData, _ header: StatusHeader) {
    let value = header.value

    if let match = JSCompat.match(value, branchOidRe) {
        results.currentTip = match[1]
    } else if let match = JSCompat.match(value, branchHeadRe) {
        if let branch = match[1], !JSCompat.strictEquals(branch, "(detached)") {
            results.currentBranch = branch
        }
    } else if let match = JSCompat.match(value, branchUpstreamRe) {
        results.currentUpstreamBranch = match[1]
    } else if let match = JSCompat.match(value, branchAheadBehindRe) {
        if let ahead = match[1].flatMap(JSCompat.parseInt), let behind = match[2].flatMap(JSCompat.parseInt) {
            results.branchAheadBehind = AheadBehind(ahead: ahead, behind: behind)
        }
    }
}

private func getMergeConflictDetails(
    _ repository: Repository,
    _ conflictedFilesInIndex: [StatusEntry]
) async throws -> ConflictFilesDetails {
    // Neither depends on the other, so they run concurrently.
    async let conflictMarkerLinesByPath = getConflictMarkerLines(repository.path)
    async let binaryFilePaths = getBinaryPaths(repository, "MERGE_HEAD", conflictedFilesInIndex)
    return try await ConflictFilesDetails(
        conflictMarkerLinesByPath: conflictMarkerLinesByPath,
        binaryFilePaths: binaryFilePaths
    )
}

private func getRebaseConflictDetails(
    _ repository: Repository,
    _ conflictedFilesInIndex: [StatusEntry]
) async throws -> ConflictFilesDetails {
    async let conflictMarkerLinesByPath = getConflictMarkerLines(repository.path)
    async let binaryFilePaths = getBinaryPaths(repository, "REBASE_HEAD", conflictedFilesInIndex)
    return try await ConflictFilesDetails(
        conflictMarkerLinesByPath: conflictMarkerLinesByPath,
        binaryFilePaths: binaryFilePaths
    )
}

/// We need to do these operations to detect conflicts that were the result
/// of popping a stash into the index
private func getWorkingDirectoryConflictDetails(
    _ repository: Repository,
    _ conflictedFilesInIndex: [StatusEntry]
) async throws -> ConflictFilesDetails {
    let conflictMarkerLinesByPath = try await getConflictMarkerLines(repository.path)
    var binaryFilePaths: [String] = []
    do {
        // its totally fine if HEAD doesn't exist, which throws an error
        binaryFilePaths = try await getBinaryPaths(repository, "HEAD", conflictedFilesInIndex)
    } catch is CancellationError {
        throw CancellationError()
    } catch {}

    return ConflictFilesDetails(
        conflictMarkerLinesByPath: conflictMarkerLinesByPath,
        binaryFilePaths: binaryFilePaths
    )
}

/// gets the conflicted files count and binary file paths in a given repository.
/// for computing a `StatusResult`.
///
/// Errors are logged and give empty details, except that cancellation is
/// passed on.
///
/// - Parameters:
///   - repository: to get details from
///   - mergeHeadFound: whether a merge conflict has been detected
///   - conflictedFilesInIndex: all files marked as being conflicted in the
///     index. Used to check for files using the binary
///     merge driver and whether it looks like a stash
///     has introduced conflicts
///   - rebaseInternalState: details about the current rebase operation (if
///     found)
private func getConflictDetails(
    _ repository: Repository,
    _ mergeHeadFound: Bool,
    _ conflictedFilesInIndex: [StatusEntry],
    _ rebaseInternalState: RebaseInternalState?
) async throws -> ConflictFilesDetails {
    do {
        if mergeHeadFound {
            return withConflictCounts(try await getMergeConflictDetails(repository, conflictedFilesInIndex), repository, conflictedFilesInIndex)
        }

        if rebaseInternalState != nil {
            return withConflictCounts(try await getRebaseConflictDetails(repository, conflictedFilesInIndex), repository, conflictedFilesInIndex)
        }

        // If there's conflicted files in the index but we don't have a merge head
        // or a rebase internal state, then we're likely in a situation where a
        // stash has introduced conflicts
        if !conflictedFilesInIndex.isEmpty {
            return withConflictCounts(try await getWorkingDirectoryConflictDetails(repository, conflictedFilesInIndex), repository, conflictedFilesInIndex)
        }
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        logger.error("Unexpected error from git operations in getConflictDetails: \(String(describing: error), privacy: .private)")
    }

    return ConflictFilesDetails(conflictCountsByPath: [:], binaryFilePaths: [])
}

/// `details` with the conflicts of each conflicted file that has markers:
/// the markers `git diff --check` reported whose line in the file opens a
/// conflict. A file that can't be read counts none.
private func withConflictCounts(
    _ details: ConflictFilesDetails,
    _ repository: Repository,
    _ conflictedFilesInIndex: [StatusEntry]
) -> ConflictFilesDetails {
    var details = details
    for file in conflictedFilesInIndex {
        let path = ExactString(file.path)
        guard let markerLines = details.conflictMarkerLinesByPath[path], !markerLines.isEmpty,
              let contents = try? Data(contentsOf: URL(exactFilePath: POSIXPath.join(repository.path, file.path)), options: .mappedIfSafe)
        else {
            continue
        }
        details.conflictsByPath[path] = countConflictStarts(contents, markerLines: markerLines)
    }
    return details
}

/// How many of the markers at `markerLines` (line numbers from 1, lines
/// ending at line feeds, as git counts them) open a conflict in `contents`:
/// start with `<`. A marker's first character says which it is (`<`, `|`,
/// `=`, or `>`), whatever its size.
private func countConflictStarts(_ contents: Data, markerLines: [Int]) -> Int {
    let lines = Set(markerLines)
    guard let lastLine = lines.max() else {
        return 0
    }
    return contents.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        guard let base = bytes.baseAddress else {
            return 0
        }
        var count = 0
        var lineNumber = 1
        var lineStart = 0
        while lineStart < bytes.count, lineNumber <= lastLine {
            if bytes[lineStart] == UInt8(ascii: "<"), lines.contains(lineNumber) {
                count += 1
            }
            let lineEnd = memchr(base + lineStart, Int32(UInt8(ascii: "\n")), bytes.count - lineStart)
                .map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? bytes.count
            lineStart = lineEnd + 1
            lineNumber += 1
        }
        return count
    }
}
