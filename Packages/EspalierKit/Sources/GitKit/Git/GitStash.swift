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

/// The stash entries created by the app, and how many there are in all.
public struct StashResult: Hashable, Sendable {
    /// The stash entries created by the app
    public let desktopEntries: [StashEntry]

    /// The total amount of stash entries,
    /// i.e. stash entries created both by the app and outside of it
    public let stashEntryCount: Int

    public init(desktopEntries: [StashEntry], stashEntryCount: Int) {
        self.desktopEntries = desktopEntries
        self.stashEntryCount = stashEntryCount
    }
}

private enum StashField: Hashable, Sendable {
    case name, stashSha, message, tree, parents
}

/// Get the list of stash entries created by the app in the
/// current repository using the default ordering of refs (which is LIFO
/// ordering), as well as the total amount of stash entries.
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
        return StashResult(desktopEntries: [], stashEntryCount: 0)
    }

    var desktopEntries: [StashEntry] = []
    let entries = parser.parse(result.stdout)

    for entry in entries {
        if let branchName = extractBranchFromMessage(entry[.message]) {
            let parents = entry[.parents]
            desktopEntries.append(StashEntry(
                name: entry[.name],
                branchName: branchName,
                stashSha: entry[.stashSha],
                files: .notLoaded,
                tree: entry[.tree],
                parents: parents.isEmpty ? [] : JSCompat.split(parents, " ")
            ))
        }
    }

    // The parser already drops the empty piece after the final NUL, so this
    // is the count `git stash list` shows.
    return StashResult(desktopEntries: desktopEntries, stashEntryCount: entries.count)
}

/// Moves a stash entry to a different branch by means of creating
/// a new stash entry associated with the new branch and dropping the old
/// stash entry.
public func moveStashEntry(_ repository: Repository, _ entry: StashEntry, _ branchName: String) async throws {
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

    try await dropDesktopStashEntry(repository, entry.stashSha)
}

/// Returns the last stash entry the app created for the given
/// branch
public func getLastDesktopStashEntryForBranch(_ repository: Repository, _ branchName: String) async throws -> StashEntry? {
    let stash = try await getStashes(repository)

    // Since stash objects are returned in a LIFO manner, the first
    // entry found is guaranteed to be the last entry created
    return stash.desktopEntries.first { JSCompat.strictEquals($0.branchName, branchName) }
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

private func getStashEntryMatchingSha(_ repository: Repository, _ sha: String) async throws -> StashEntry? {
    let stash = try await getStashes(repository)
    return stash.desktopEntries.first { JSCompat.strictEquals($0.stashSha, sha) }
}

/// Removes the given stash entry if it exists
///
/// - Parameter stashSha: the SHA that identifies the stash entry
public func dropDesktopStashEntry(_ repository: Repository, _ stashSha: String) async throws {
    if let entryToDelete = try await getStashEntryMatchingSha(repository, stashSha) {
        let args = ["stash", "drop", entryToDelete.name]
        try await git(args, repository.path, "dropStashEntry")
    }
}

/// What `popStashEntry` did.
public enum PopStashEntryResult: Hashable, Sendable {
    /// The changes are back in the working directory and the entry is gone.
    case popped

    /// The changes are back in the working directory with conflicts, and
    /// git kept the entry so nothing is lost if the user starts over. Drop
    /// it with `dropDesktopStashEntry` once the conflicts are resolved.
    case conflicted

    /// No stash entry created by the app has the SHA.
    case notFound
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

/// Pops the stash entry identified by matching `stashSha` to its commit hash.
///
/// To see the commit hash of stash entry, run
/// `git log -g refs/stash --pretty="%nentry: %gd%nsubject: %gs%nhash: %H%n"`
/// in a repo with some stash entries.
///
/// When the changes conflict with the working directory, git applies them
/// with conflict markers and keeps the entry, and this returns
/// `.conflicted`.
///
/// - Throws: `StashFilesInTheWayError` when untracked files are where the
///   entry's files go; nothing is restored. `GitError` when git
///   can't apply the entry at all otherwise, for example because local
///   changes would be overwritten. The entry is kept.
@discardableResult
public func popStashEntry(_ repository: Repository, _ stashSha: String) async throws -> PopStashEntryResult {
    // A pop with conflicts returns `.conflicted`.
    let expectedErrors: Set<DugiteError> = [.mergeConflicts]
    guard let stashToPop = try await getStashEntryMatchingSha(repository, stashSha) else {
        return .notFound
    }

    // An entry made with `--include-untracked` restores its untracked files
    // after its other changes, and stops at one that's in the way ("already
    // exists, no checkout"), with the other changes restored and the entry
    // kept, so restoring it again later would apply them twice. Checking
    // first restores nothing instead.
    let inTheWay = try await untrackedStashFilesInTheWay(repository, stashToPop)
    if !inTheWay.isEmpty {
        throw StashFilesInTheWayError(files: inTheWay)
    }

    let args = ["stash", "pop", "--quiet", stashToPop.name]
    do {
        let result = try await git(
            args,
            repository.path,
            "popStashEntry",
            options: GitExecutionOptions(expectedErrors: expectedErrors)
        )
        return result.gitError == .mergeConflicts ? .conflicted : .popped
    } catch let error as GitError where error.result.exitCode == 1 && error.result.stderrData.isEmpty {
        // popping a stashes that create conflicts in the working directory
        // report an exit code of `1` and are not dropped after being applied
        // (anything in stderr would mean git couldn't apply it at all).
        // The entry is kept, so discarding the conflicted changes doesn't
        // lose them for good.
        logger.info("[popStashEntry] a stash was popped with conflicts (exit code \(error.result.exitCode)); keeping the entry.")
        return .conflicted
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
        "popStashEntry"
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
