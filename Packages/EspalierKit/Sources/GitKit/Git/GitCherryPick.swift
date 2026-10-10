// Ported from desktop/app/src/lib/git/cherry-pick.ts

import EspalierSupport
import Foundation
import os
import Synchronization

private let logger = Log.logger(category: "cherry-pick")

/// The app-specific results from attempting to cherry pick commits
public enum CherryPickResult: String, Hashable, Sendable {
    /// Git completed the cherry pick without reporting any errors, and the caller can
    /// signal success to the user.
    case completedWithoutError = "CompletedWithoutError"
    /// The cherry pick encountered conflicts while attempting to cherry pick and
    /// need to be resolved before the user can continue.
    case conflictsEncountered = "ConflictsEncountered"
    /// The cherry pick was not able to continue as tracked files were not staged in
    /// the index.
    case outstandingFilesNotStaged = "OutstandingFilesNotStaged"
    /// The cherry pick was not attempted:
    /// - it could not check the status of the repository.
    /// - there was an invalid revision range provided.
    /// - there were uncommitted changes present.
    /// - there were errors in checkout the target branch
    case unableToStart = "UnableToStart"
    /// An unexpected error as part of the cherry pick flow was caught and handled.
    ///
    /// Check the logs to find the relevant Git details.
    case error = "Error"
}

/// The hooks git runs while cherry-picking (measured with git 2.53): each
/// commit it picks runs `prepare-commit-msg` and `post-commit`; continuing
/// commits the commit that stopped with `git commit`, which runs
/// `pre-commit`, `prepare-commit-msg`, `commit-msg`, `post-commit`, and
/// `pre-auto-gc`; aborting runs none.
///
/// They are intercepted, as for commits and rebases: they run in the login
/// shell's environment, and a failing one asks whether to abort or ignore.
public let cherryPickInterceptedHooks = [
    "pre-commit",
    "prepare-commit-msg",
    "commit-msg",
    "post-commit",
    "pre-auto-gc",
]

/// `/^\[(.*\s.*)\]/`
private let cherryPickRe = JSCompat.regex("^\\[(\(JSCompat.dot)*\(JSCompat.whitespace)\(JSCompat.dot)*)\\]")

/// A parser to read and emit cherry pick progress from Git `stdout`.
///
/// Each successful cherry picked commit outputs a set of lines similar to the
/// following example:
///
///     [branchName commitSha] commitSummary
///       Date: timestamp
///       1 file changed, 1 insertion(+)
///       create mode 100644 filename
struct GitCherryPickParser: Sendable {
    private let commits: [CommitOneLine]
    private var count: Int

    init(_ commits: [CommitOneLine], _ count: Int = 0) {
        self.commits = commits
        self.count = count
    }

    mutating func parse(_ line: String) -> MultiCommitOperationProgress? {
        if JSCompat.match(line, cherryPickRe) == nil {
            // Skip lines that don't represent the first line of a successfully picked
            // commit. -- i.e. timestamp, files changed, conflicts, etc..
            return nil
        }
        count += 1

        return MultiCommitOperationProgress(
            value: round(Double(count) / Double(commits.count), 2),
            currentCommitSummary: count <= commits.count ? commits[count - 1].summary : "",
            position: count,
            totalCommitCount: commits.count
        )
    }
}

/// Reports the progress of the git processes started with one set of
/// options. One parser keeps the count going when `continueCherryPick` runs
/// git twice.
private final class CherryPickProgressReporter: Sendable {
    private let parser: Mutex<GitCherryPickParser>
    private let progressCallback: @Sendable (MultiCommitOperationProgress) -> Void

    init(_ parser: GitCherryPickParser, _ progressCallback: @escaping @Sendable (MultiCommitOperationProgress) -> Void) {
        self.parser = Mutex(parser)
        self.progressCallback = progressCallback
    }

    func report(_ lines: [String]) {
        parser.withLock { parser in
            for line in lines {
                if let progress = parser.parse(line) {
                    progressCallback(progress)
                }
            }
        }
    }
}

/// Splits one git process's standard output into lines, and reports them in
/// order, one at a time.
private final class CherryPickOutputReader: Sendable {
    private let lines = Mutex(LineSplitter())
    private let reporter: CherryPickProgressReporter

    init(_ reporter: CherryPickProgressReporter) {
        self.reporter = reporter
    }

    func receive(_ chunk: Data) {
        lines.withLock { reporter.report($0.push(chunk)) }
    }

    func finish() {
        lines.withLock { reporter.report($0.finish()) }
    }
}

/// This method merges `baseOptions` with a call back method that obtains a
/// `MultiCommitOperationProgress` instance from `stdout` parsing.
///
/// `progressCallback` is called on a background thread, one call at a time,
/// and every call has returned before the git call using these options does.
///
/// - Parameters:
///   - baseOptions: contains git execution options other than the
///     progressCallBack such as expectedErrors
///   - commits: used by the parser to form `MultiCommitOperationProgress` instance
///   - progressCallback: the callback method that accepts an
///     `MultiCommitOperationProgress` instance created by the parser
///   - cherryPickedCount: the number of commits already cherry picked
private func configureOptionsWithCallBack(
    _ baseOptions: GitExecutionOptions,
    _ commits: [CommitOneLine],
    _ progressCallback: @escaping @Sendable (MultiCommitOperationProgress) -> Void,
    _ cherryPickedCount: Int = 0
) -> GitExecutionOptions {
    let reporter = CherryPickProgressReporter(GitCherryPickParser(commits, cherryPickedCount), progressCallback)

    var options = baseOptions
    options.processCallback = { process in
        let reader = CherryPickOutputReader(reporter)
        process.observeStandardOutput { reader.receive($0) }
        process.onClose { reader.finish() }
    }
    return options
}

/// A function to initiate cherry picking in the app.
///
/// git's errors other than conflicts throw a `GitError`. When git stops
/// before picking a commit of several (for example because local changes
/// would be overwritten), it leaves `.git/sequencer` behind without
/// `CHERRY_PICK_HEAD`: `abortCherryPick` restores the branch.
///
/// - Parameter commits: array of commits to cherry-pick
///   For a cherry-pick operation, it does not matter what order the commits
///   appear. But, it is best practice to send them in ascending order to prevent
///   conflicts. First one on the array is first to be cherry-picked.
public func cherryPick(
    _ repository: Repository,
    _ commits: [CommitOneLine],
    progressCallback: (@Sendable (MultiCommitOperationProgress) -> Void)? = nil
) async throws -> CherryPickResult {
    if commits.isEmpty {
        return .unableToStart
    }

    var baseOptions = GitExecutionOptions(
        expectedErrors: [.mergeConflicts, .conflictModifyDeletedInBranch],
        interceptHooks: cherryPickInterceptedHooks
    )

    if let progressCallback {
        baseOptions = configureOptionsWithCallBack(baseOptions, commits, progressCallback)
    }

    // --empty=keep follows pattern of making sure someone cherry
    //  picked commit summaries appear in target branch history even tho they may
    //  be empty. This flag also results in the ability to cherry pick empty
    //  commits (thus, --allow-empty is not required.)
    //
    // -m 1 makes it so a merge commit always takes the first parent's history
    //  (the branch you are cherry-picking from) for the commit. It also means
    //  there could be multiple empty commits. I.E. If user does a range that
    //  includes commits from that merge.
    let result = try await git(
        ["cherry-pick"] + commits.map(\.sha) + ["--empty=keep", "-m", "1"],
        repository.path,
        "cherry-pick",
        options: baseOptions
    )

    return try parseCherryPickResult(result)
}

private func parseCherryPickResult(_ result: GitResult) throws -> CherryPickResult {
    if result.exitCode == 0 {
        return .completedWithoutError
    }

    switch result.gitError {
    case .conflictModifyDeletedInBranch, .mergeConflicts:
        return .conflictsEncountered
    case .unresolvedConflicts:
        return .outstandingFilesNotStaged
    default:
        throw GitLibError(
            "Unhandled result found: exit code \(result.exitCode), "
                + "error \(result.gitError?.rawValue ?? "none"), stderr: \(result.stderr)"
        )
    }
}

/// Inspect the `.git/sequencer` folder and convert the current cherry pick
/// state into a `MultiCommitOperationProgress` instance as well as return an
/// array of remaining commits queued for cherry picking.
///  - Progress instance required to display progress to user.
///  - Commits required to track progress after a conflict has been resolved.
///
/// This is required when Espalier is not responsible for initiating the cherry
/// pick and when continuing a cherry pick after conflicts are resolved:
///
/// It returns nil if it cannot parse an ongoing cherry pick. This happens when,
///  - There isn't a cherry pick in progress (expected nil outcome).
///  - Runs into errors parsing cherry pick files. This is expected if cherry
///    pick is aborted or finished during parsing. It could also occur if cherry
///    pick sequencer files are corrupted.
public func getCherryPickSnapshot(_ repository: Repository) async throws -> CherryPickSnapshot? {
    if !(await isCherryPickHeadFound(repository)) {
        // If there no cherry pick head, there is no cherry pick in progress.
        return nil
    }

    /// The trimmed contents of a sequencer file, or nil when it can't be
    /// read. Reading may fail if the cherry pick is continued or aborted at
    /// the same time.
    func readSequencerFile(_ name: String) -> String? {
        readTrimmedFile(POSIXPath.join(repository.resolvedGitDir, "sequencer", name))
    }

    // Abort safety sha is stored in.git/sequencer/abort-safety. It is the sha of
    // the last cherry-picked commit in the operation or the head of target branch
    // if no commits have been cherry-picked yet.
    guard let abortSafetySha = readSequencerFile("abort-safety") else {
        return try await getSingleCommitCherryPickSnapshot(repository, "")
    }

    if abortSafetySha.isEmpty {
        // Technically possible if someone continued or aborted the cherry pick at
        // the same time
        return nil
    }

    // The head sha is stored in .git/sequencer/head. It is the sha of target
    // branch before the cherry-pick operation occurred.
    guard let headSha = readSequencerFile("head") else {
        return try await getSingleCommitCherryPickSnapshot(repository, "")
    }

    if headSha.isEmpty {
        // Technically possible if someone continued or aborted the cherry pick at
        // the same time
        return nil
    }

    // Each line of .git/sequencer/todo holds a sha of a commit lined up to be
    // cherry-picked. These shas are in historical order starting oldest commit as
    // the first line and newest as the last line.
    guard let remainingPicks = readSequencerFile("todo") else {
        return try await getSingleCommitCherryPickSnapshot(repository, headSha)
    }

    if remainingPicks.isEmpty {
        // Technically possible if someone continued or aborted the cherry pick at
        // the same time
        return nil
    }

    var remainingCommits: [CommitOneLine] = []

    // Each line is of the format: `pick shortSha commitSummary`
    for todoLine in JSCompat.split(remainingPicks, "\n") {
        let isPick = JSCompat.startsWith(todoLine, "pick ")
        let line = isPick ? JSCompat.dropFirst(todoLine, 5) : todoLine
        let trimmed = JSCompat.trim(line)

        if JSCompat.includes(trimmed, " ") {
            let sha = String(line.unicodeScalars.prefix { $0 != " " })
            let summary = String(line.unicodeScalars.dropFirst(sha.unicodeScalars.count + 1))
            remainingCommits.append(CommitOneLine(sha: sha, summary: summary))
        } else if isPick, !trimmed.isEmpty {
            // A commit with an empty summary is listed as just its SHA.
            remainingCommits.append(CommitOneLine(sha: trimmed, summary: ""))
        }
    }

    if remainingCommits.isEmpty {
        // This should only be possible with corrupt sequencer files.
        return nil
    }

    // To get all the commits for the cherry-pick operation, we need to get the
    // ones already cherry-picked. If abortSafetySha is headSha; none have been
    // cherry-picked yet.
    var commitsCherryPicked: [CommitOneLine]? = []
    if abortSafetySha != headSha {
        commitsCherryPicked = try await getCommitsInRange(repository, revRange(headSha, abortSafetySha))
    }

    guard let commitsCherryPicked else {
        // This should only be possible with corrupt sequencer files resulting in a
        // bad revision range.
        return nil
    }

    let commits = commitsCherryPicked + remainingCommits
    let position = commitsCherryPicked.count + 1

    return CherryPickSnapshot(
        remainingCommits: remainingCommits,
        commits: commits,
        progress: MultiCommitOperationProgress(
            value: round(Double(position) / Double(commits.count), 2),
            currentCommitSummary: remainingCommits[0].summary,
            position: position,
            totalCommitCount: commits.count
        ),
        targetBranchUndoSha: headSha,
        cherryPickedCount: commitsCherryPicked.count
    )
}

/// Which commit a cherry-pick of several commits stopped at, from git's
/// sequencer, as `getCherryPickSnapshot` reads it: the commits picked since
/// `sequencer/head`, plus one, of those and the commits left in
/// `sequencer/todo` (the one it stopped at first). Nil while no cherry-pick
/// waits (`CHERRY_PICK_HEAD`), and for a single commit, which git picks
/// without its sequencer.
///
/// It only reads (the files, and `git log` of the commits picked).
public func getCherryPickStep(_ repository: Repository) async -> OperationStep? {
    guard FileManager.default.fileExists(atPath: POSIXPath.join(repository.resolvedGitDir, "sequencer", "todo")),
          let snapshot = try? await getCherryPickSnapshot(repository)
    else {
        return nil
    }
    let progress = snapshot.progress
    guard progress.position >= 1, progress.position <= progress.totalCommitCount else {
        return nil
    }
    return OperationStep(position: progress.position, total: progress.totalCommitCount)
}

/// The snapshot when git didn't use the sequencer files, which means only
/// one commit is being cherry picked.
private func getSingleCommitCherryPickSnapshot(
    _ repository: Repository,
    _ headSha: String
) async throws -> CherryPickSnapshot? {
    if !(await isCherryPickHeadFound(repository)) {
        // We redo this check just because a user technically could end the
        // cherry-pick by the time we got here.
        return nil
    }

    // If cherry-pick is in progress, then there was only one commit cherry-picked
    // thus sequencer files were not used.
    guard let cherryPickHeadSha = readTrimmedFile(POSIXPath.join(repository.resolvedGitDir, "CHERRY_PICK_HEAD")),
          let commit = try await getCommit(repository, cherryPickHeadSha)
    else {
        return nil
    }

    // `headSha` is empty when the sequencer files are missing. Nothing has
    // been committed yet, so the target branch's tip before the cherry pick
    // is HEAD.
    var targetBranchUndoSha = headSha
    if targetBranchUndoSha.isEmpty {
        targetBranchUndoSha = try await getHeadSha(repository)
    }

    return CherryPickSnapshot(
        remainingCommits: [],
        commits: [CommitOneLine(sha: commit.sha, summary: commit.summary)],
        progress: MultiCommitOperationProgress(
            value: 1,
            currentCommitSummary: commit.summary,
            position: 1,
            totalCommitCount: 1
        ),
        targetBranchUndoSha: targetBranchUndoSha,
        cherryPickedCount: 0
    )
}

/// The SHA HEAD points at, or an empty string when HEAD is unborn.
private func getHeadSha(_ repository: Repository) async throws -> String {
    let result = try await git(
        ["rev-parse", "--verify", "HEAD"],
        repository.path,
        "getCherryPickSnapshot",
        options: GitExecutionOptions(successExitCodes: [0, 128])
    )
    return result.exitCode == 0 ? JSCompat.trim(result.stdout) : ""
}

/// The file's contents, decoded as UTF-8 and trimmed, or nil when it can't
/// be read.
private func readTrimmedFile(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).map { JSCompat.trim(String(decoding: $0, as: UTF8.self)) }
}

/// Proceed with the current cherry pick operation and report back on whether it completed
///
/// It is expected that the index has staged files which are cleanly cherry
/// picked onto the base branch, and the remaining unstaged files are those which
/// need manual resolution or were changed by the user to address inline
/// conflicts.
///
/// - Parameter files: The working directory of files. These are the files that are
///   detected to have changes that we want to stage for the cherry pick.
public func continueCherryPick(
    _ repository: Repository,
    _ files: [WorkingDirectoryFileChange],
    _ manualResolutions: [String: ManualConflictResolution] = [:],
    progressCallback: (@Sendable (MultiCommitOperationProgress) -> Void)? = nil
) async throws -> CherryPickResult {
    // Checked before staging: staging the user's files when there's nothing
    // to continue would change their index for nothing.
    if !(await isCherryPickHeadFound(repository)) {
        return .unableToStart
    }

    // only stage files related to cherry pick
    let trackedFiles = files.filter { $0.status.kind != .untracked }

    // apply conflict resolutions (in a fixed order; each file is staged on
    // its own, so the order doesn't change the result)
    for (path, resolution) in manualResolutions.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
        guard let file = files.first(where: { JSCompat.strictEquals($0.path, path) }) else {
            logger.error("[continueCherryPick] couldn't find file \(path, privacy: .private) even though there's a manual resolution for it")
            continue
        }
        try await stageManualConflictResolution(repository, file, resolution)
    }

    let resolvedPaths = Set(manualResolutions.keys.map(ExactString.init))
    let otherFiles = trackedFiles.filter { !resolvedPaths.contains(ExactString($0.path)) }
    try await stageFiles(repository, otherFiles)

    guard let status = try await getStatus(repository, includeUntracked: false) else {
        logger.warning("[continueCherryPick] unable to get status after staging changes, skipping any other steps")
        return .unableToStart
    }

    // make sure cherry pick is still in progress to continue
    if !(await isCherryPickHeadFound(repository)) {
        return .unableToStart
    }

    var options = GitExecutionOptions(
        env: [
            // if we don't provide editor, we can't detect git errors
            "GIT_EDITOR": ":",
        ],
        expectedErrors: [.mergeConflicts, .conflictModifyDeletedInBranch, .unresolvedConflicts],
        interceptHooks: cherryPickInterceptedHooks
    )

    if let progressCallback {
        guard let snapshot = try await getCherryPickSnapshot(repository) else {
            logger.warning("[continueCherryPick] unable to get cherry-pick status, skipping other steps")
            return .unableToStart
        }

        options = configureOptionsWithCallBack(options, snapshot.commits, progressCallback, snapshot.cherryPickedCount)
    }

    let trackedFilesAfter = status.workingDirectory.files.filter { $0.status.kind != .untracked }

    if trackedFilesAfter.isEmpty {
        logger.warning("[cherryPick] no tracked changes to commit, continuing cherry-pick but skipping this commit")

        // This commits the empty commit so that the cherry picked commit still
        // shows up in the target branches history.
        let result = try await git(
            ["commit", "--allow-empty"],
            repository.path,
            "continueCherryPickSkipCurrentCommit",
            options: options
        )

        // Committing concludes only the current commit. When more commits
        // are queued, git keeps the sequencer for `--continue`, which moves
        // on to the next one.
        if result.exitCode == 0, await pathExists(POSIXPath.join(repository.resolvedGitDir, "sequencer", "todo")) {
            let continued = try await git(["cherry-pick", "--continue"], repository.path, "continueCherryPick", options: options)
            return try parseCherryPickResult(continued)
        }

        return try parseCherryPickResult(result)
    }

    let result = try await git(["cherry-pick", "--continue"], repository.path, "continueCherryPick", options: options)

    return try parseCherryPickResult(result)
}

/// Abandon the current cherry pick operation
public func abortCherryPick(_ repository: Repository) async throws {
    try await git(["cherry-pick", "--abort"], repository.path, "abortCherryPick")
}

/// Check if the `.git/CHERRY_PICK_HEAD` file exists
public func isCherryPickHeadFound(_ repository: Repository) async -> Bool {
    await pathExists(POSIXPath.join(repository.resolvedGitDir, "CHERRY_PICK_HEAD"))
}
