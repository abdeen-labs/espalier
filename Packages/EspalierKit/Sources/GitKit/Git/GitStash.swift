// Ported from desktop/app/src/lib/git/stash.ts
//
// "Desktop" in the function names below means "created by the app".

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "stash")

/// The marker Espalier writes into the messages of the stash entries it
/// creates: `!!Espalier<branch>`.
public let EspalierStashEntryMarker = "!!Espalier"

/// The other marker that identifies the app's stash entries:
/// `!!GitHub_Desktop<branch>`. Recognized but never written.
public let DesktopStashEntryMarker = "!!GitHub_Desktop"

/// RegEx for determining if a stash entry is created by the app
///
/// This is done by looking for a magic string with the following
/// format: `!!Espalier<branch>` or `!!GitHub_Desktop<branch>`.
private let desktopStashEntryMessageRe = JSCompat.regex("!!(?:Espalier|GitHub_Desktop)<(\(JSCompat.dot)+)>\\z")

/// Every stash entry, and those the app created.
public struct StashResult: Hashable, Sendable {
    /// Every stash entry, newest first, as `git stash list` lists them.
    public let entries: [StashEntry]

    /// The stash entries created by the app: those with a marker.
    public var desktopEntries: [StashEntry] {
        entries.filter { $0.branchName != nil }
    }

    /// The total amount of stash entries,
    /// i.e. stash entries created both by the app and outside of it
    public var stashEntryCount: Int {
        entries.count
    }

    public init(entries: [StashEntry]) {
        self.entries = entries
    }
}

private enum StashField: Hashable, Sendable {
    case name, stashSha, message, tree, parents
}

/// Get the list of stash entries in the current repository using the
/// default ordering of refs (which is LIFO ordering), each with the branch
/// in its marker when the app created it.
public func getStashes(_ repository: Repository) async throws -> StashResult {
    let parser = createLogParser([
        StashField.name: "%gD",
        .stashSha: "%H",
        .message: "%gs",
        .tree: "%T",
        .parents: "%P",
    ])

    let result = try await git(
        ["log", "-g"] + parser.formatArgs + ["refs/stash", "--"],
        repository.path,
        "getStashEntries",
        options: GitExecutionOptions(successExitCodes: [0, 128])
    )

    // There's no refs/stashes reflog in the repository or it's not
    // even a repository. In either case we don't care
    if result.exitCode == 128 {
        return StashResult(entries: [])
    }

    // The parser already drops the empty piece after the final NUL, so these
    // are the entries `git stash list` shows.
    let entries = parser.parse(result.stdout).map { entry in
        let parents = entry[.parents]
        return StashEntry(
            name: entry[.name],
            branchName: extractBranchFromMessage(entry[.message]),
            message: entry[.message],
            stashSha: entry[.stashSha],
            files: .notLoaded,
            tree: entry[.tree],
            parents: parents.isEmpty ? [] : JSCompat.split(parents, " ")
        )
    }
    return StashResult(entries: entries)
}

/// The stash entry whose commit is `stashSha`, as the stash list is now,
/// or nil when no entry has it.
public func getStashEntry(_ repository: Repository, _ stashSha: String) async throws -> StashEntry? {
    try await getStashes(repository).entries.first { JSCompat.strictEquals($0.stashSha, stashSha) }
}

/// No stash entry has the SHA any more: it was restored or dropped since
/// it was listed. Nothing was done.
public struct StashEntryNotFoundError: Error, Hashable, Sendable, LocalizedError {
    /// The SHA of the entry's commit.
    public let stashSha: String

    public init(stashSha: String) {
        self.stashSha = stashSha
    }

    public var errorDescription: String? {
        "These stashed changes are no longer in the stash list."
    }
}

/// The stash entry whose commit is `stashSha`, as the stash list is now.
///
/// - Throws: `StashEntryNotFoundError` when no entry has it.
private func requireStashEntry(_ repository: Repository, _ stashSha: String) async throws -> StashEntry {
    guard let entry = try await getStashEntry(repository, stashSha) else {
        throw StashEntryNotFoundError(stashSha: stashSha)
    }
    return entry
}

/// Moves a stash entry to a different branch by means of creating
/// a new stash entry associated with the new branch and dropping the old
/// stash entry. The new entry is the newest.
///
/// - Throws: `StashEntryNotFoundError` when the entry is gone; nothing is
///   created.
public func moveStashEntry(_ repository: Repository, _ entry: StashEntry, _ branchName: String) async throws {
    _ = try await requireStashEntry(repository, entry.stashSha)

    let message = "On \(branchName): \(createDesktopStashMessage(branchName))"
    let parentArgs = entry.parents.flatMap { ["-p", $0] }

    let commitId = try await git(
        ["commit-tree"] + parentArgs + ["-m", message, "--no-gpg-sign", entry.tree],
        repository.path,
        "moveStashEntryToBranch"
    ).stdout

    try await git(
        ["stash", "store", "-m", message, JSCompat.trim(commitId)],
        repository.path,
        "moveStashEntryToBranch"
    )

    try await dropStashEntry(repository, entry.stashSha)
}

/// Returns the last stash entry the app created for the given
/// branch
public func getLastDesktopStashEntryForBranch(_ repository: Repository, _ branchName: String) async throws -> StashEntry? {
    let stash = try await getStashes(repository)

    // Since stash objects are returned in a LIFO manner, the first
    // entry found is guaranteed to be the last entry created
    return stash.desktopEntries.first { $0.branchName.map { JSCompat.strictEquals($0, branchName) } == true }
}

/// Returns the last stash entry the app created for the given
/// branch
public func getLastDesktopStashEntryForBranch(_ repository: Repository, _ branch: Branch) async throws -> StashEntry? {
    try await getLastDesktopStashEntryForBranch(repository, branch.name)
}

/// Creates a stash entry message that indicates the entry was created by
/// Espalier: `!!Espalier<branch>`.
public func createDesktopStashMessage(_ branchName: String) -> String {
    "\(EspalierStashEntryMarker)<\(branchName)>"
}

/// `/^error: /m`
private let errorPrefixRe = try! NSRegularExpression(pattern: "^error: ", options: [.anchorsMatchLines])

/// Stash the working directory changes for the current branch
///
/// - Parameters:
///   - branchName: The branch the entry is for, recorded in its message.
///   - untrackedFilesToStage: The untracked files to include. They are
///     staged first, so the stash takes them along.
/// - Returns: true when an entry was created, false when there were no local
///   changes to save.
/// - Throws: `GitError` when git fails, including when it exits with code 1
///   without creating an entry (for example on an unborn branch).
@discardableResult
public func createDesktopStashEntry(
    _ repository: Repository,
    _ branchName: String,
    _ untrackedFilesToStage: [WorkingDirectoryFileChange]
) async throws -> Bool {
    // We must ensure that no untracked files are present before stashing
    // First ensure that all changes in file are selected
    // (in case the user has not explicitly checked the checkboxes for the untracked files)
    let fullySelectedUntrackedFiles = untrackedFilesToStage.map { $0.withIncludeAll(true) }
    try await stageFiles(repository, fullySelectedUntrackedFiles)

    let message = createDesktopStashMessage(branchName)
    let args = ["stash", "push", "-m", message]

    let stashBefore = try await resolveStashRef(repository)

    let result: GitResult
    do {
        result = try await git(args, repository.path, "createStashEntry")
    } catch let error as GitError where error.result.exitCode == 1 {
        // An exit code of 1 for `git stash push` without lines beginning
        // with "error: " doesn't mean a stash was created: on an unborn
        // branch git exits with 1 and "You do not have the initial commit
        // yet" without creating one. Whether refs/stash moved tells for
        // certain.

        // search for any line starting with `error:` -  /m here to ensure this is
        // applied to each line, without needing to split the text
        let stderr = error.result.stderr
        if errorPrefixRe.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)) != nil {
            // rethrow, because these messages should prevent the stash from being created
            throw error
        }

        let stashAfter = try await resolveStashRef(repository)
        guard let stashAfter, stashAfter != stashBefore else {
            // Nothing was stashed.
            throw error
        }

        // if no error messages were emitted by Git, we should log but continue because
        // a valid stash was created and this should not interfere with the checkout
        logger.info("[createDesktopStashEntry] a stash was created successfully but exit code \(error.result.exitCode) reported. stderr: \(stderr, privacy: .private)")
        result = error.result
    }

    // Stash doesn't consider it an error that there aren't any local changes to save.
    if JSCompat.strictEquals(result.stdout, "No local changes to save\n") {
        return false
    }

    return true
}

/// Stash the working directory changes for the given branch; see
/// `createDesktopStashEntry(_:_:_:)`.
@discardableResult
public func createDesktopStashEntry(
    _ repository: Repository,
    _ branch: Branch,
    _ untrackedFilesToStage: [WorkingDirectoryFileChange]
) async throws -> Bool {
    try await createDesktopStashEntry(repository, branch.name, untrackedFilesToStage)
}

/// The object ID refs/stash points at, or nil when there is none.
private func resolveStashRef(_ repository: Repository) async throws -> String? {
    let result = try await git(
        ["rev-parse", "--verify", "--quiet", "refs/stash"],
        repository.path,
        "createStashEntry",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )
    let sha = JSCompat.trim(result.stdout)
    return result.exitCode == 0 && !sha.isEmpty ? sha : nil
}

/// Removes the stash entry whose commit is `stashSha`, wherever it is in
/// the list now.
///
/// - Throws: `StashEntryNotFoundError` when no entry has it.
public func dropStashEntry(_ repository: Repository, _ stashSha: String) async throws {
    let entryToDelete = try await requireStashEntry(repository, stashSha)
    let args = ["stash", "drop", entryToDelete.name]
    try await git(args, repository.path, "dropStashEntry")
}

/// What `applyStashEntry` did.
public enum ApplyStashEntryResult: Hashable, Sendable {
    /// The changes are in the working directory, and the entry is kept.
    case applied

    /// The changes are in the working directory with conflicts, and the
    /// entry is kept.
    case conflicted
}

/// What `popStashEntry` did.
public enum PopStashEntryResult: Hashable, Sendable {
    /// The changes are back in the working directory and the entry is gone.
    case popped

    /// The changes are back in the working directory with conflicts, and
    /// the entry is kept, as git does, so nothing is lost if the user
    /// starts over. Drop it with `dropStashEntry` once the conflicts are
    /// resolved.
    case conflicted
}

/// Files in the working directory are where a stash entry would put files
/// of its own, so nothing was restored and the entry was kept.
public struct StashFilesInTheWayError: Error, Hashable, Sendable, LocalizedError {
    /// The files in the way, relative to the repository.
    public let files: [String]

    public init(files: [String]) {
        self.files = files
    }

    public var errorDescription: String? {
        "The stashed changes can't be restored because these files are in the way: \(files.joined(separator: ", "))"
    }
}

/// Applies the stash entry whose commit is `stashSha` to the working
/// directory and keeps it (`git stash apply`, given the commit, so no
/// other entry is applied if indices shift meanwhile).
///
/// To see the commit hash of stash entry, run
/// `git log -g refs/stash --pretty="%nentry: %gd%nsubject: %gs%nhash: %H%n"`
/// in a repo with some stash entries.
///
/// When the changes conflict with the working directory, git applies them
/// with conflict markers, and this returns `.conflicted`.
///
/// - Throws: `StashEntryNotFoundError` when no entry has the SHA.
///   `StashFilesInTheWayError` when untracked files are where the entry's
///   files go; nothing is applied. `GitError` when git can't apply the
///   entry at all otherwise, for example because local changes would be
///   overwritten.
@discardableResult
public func applyStashEntry(_ repository: Repository, _ stashSha: String) async throws -> ApplyStashEntryResult {
    let entry = try await requireStashEntry(repository, stashSha)
    return try await applyStashCommit(repository, entry, "applyStashEntry") ? .applied : .conflicted
}

/// Pops the stash entry whose commit is `stashSha`: applies it as
/// `applyStashEntry` does, then drops it unless its changes conflicted.
///
/// - Throws: As `applyStashEntry`. The entry is kept.
@discardableResult
public func popStashEntry(_ repository: Repository, _ stashSha: String) async throws -> PopStashEntryResult {
    let entry = try await requireStashEntry(repository, stashSha)
    guard try await applyStashCommit(repository, entry, "popStashEntry") else {
        // As `git stash pop` does, an entry whose changes conflict is kept,
        // so discarding the conflicted changes doesn't lose them for good.
        return .conflicted
    }
    // The entry is found again, as its index may have changed since. Gone
    // already, it was dropped as popping would have.
    if let applied = try await getStashEntry(repository, stashSha) {
        try await git(["stash", "drop", "--quiet", applied.name], repository.path, "popStashEntry")
    }
    return .popped
}

/// Applies `entry`'s commit (`git stash apply`).
///
/// - Returns: true when it applied cleanly, false when its changes conflict.
private func applyStashCommit(_ repository: Repository, _ entry: StashEntry, _ name: String) async throws -> Bool {
    // An apply with conflicts returns false.
    let expectedErrors: Set<DugiteError> = [.mergeConflicts]

    // An entry made with `--include-untracked` restores its untracked files
    // after its other changes, and stops at one that's in the way ("already
    // exists, no checkout"), with the other changes restored, so restoring
    // it again later would apply them twice. Checking first restores
    // nothing instead.
    let inTheWay = try await untrackedStashFilesInTheWay(repository, entry)
    if !inTheWay.isEmpty {
        throw StashFilesInTheWayError(files: inTheWay)
    }

    let args = ["stash", "apply", "--quiet", entry.stashSha]
    do {
        let result = try await git(
            args,
            repository.path,
            name,
            options: GitExecutionOptions(expectedErrors: expectedErrors)
        )
        return result.gitError != .mergeConflicts
    } catch let error as GitError where error.result.exitCode == 1 && error.result.stderrData.isEmpty {
        // Applying a stash whose changes conflict in the working directory
        // reports an exit code of `1` (anything in stderr would mean git
        // couldn't apply it at all).
        logger.info("[\(name, privacy: .public)] a stash was applied with conflicts (exit code \(error.result.exitCode))")
        return false
    } catch let error as GitError where error.result.exitCode == 1
        && JSCompat.includes(error.result.stderr, "untracked working tree files would be overwritten by merge")
    {
        // A file the entry adds (an untracked file it stashed, staged first)
        // is untracked in the working directory again. Git refused before
        // changing anything; `DugiteError` has no case for it.
        throw StashFilesInTheWayError(files: parseFilesToBeOverwritten(error.result.stderr))
    }
}

/// The files of a stash entry's untracked-files commit (`stash^3`, made by
/// `git stash --include-untracked`) that something in the working directory
/// is in the way of: git won't restore over them.
private func untrackedStashFilesInTheWay(_ repository: Repository, _ entry: StashEntry) async throws -> [String] {
    guard entry.parents.count > 2 else {
        return []
    }
    let result = try await git(
        ["ls-tree", "-r", "-z", "--name-only", "--full-tree", entry.parents[2]],
        repository.path,
        "applyStashEntry"
    )
    return JSCompat.split(result.stdout, "\0").filter { path in
        var info = stat()
        return !path.isEmpty && lstat(POSIXPath.join(repository.path, path), &info) == 0
    }
}

private func extractBranchFromMessage(_ message: String) -> String? {
    guard let match = JSCompat.match(message, desktopStashEntryMessageRe), let branch = match[1], !branch.isEmpty else {
        return nil
    }
    return branch
}

/// Get the files that were changed in the given stash commit
public func getStashedFiles(_ repository: Repository, _ stashSha: String) async throws -> [CommittedFileChange] {
    let args = [
        "stash",
        "show",
        stashSha,
        "--raw",
        "--numstat",
        "-z",
        "--format=format:",
        "--no-show-signature",
        "--",
    ]

    let result = try await git(args, repository.path, "getStashedFiles")

    return try parseRawLogWithNumstat(result.stdout, stashSha, "\(stashSha)^").files
}
