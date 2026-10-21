// Ported from desktop/app/src/lib/git/rebase.ts

import EspalierSupport
import Foundation
import os
import Synchronization

private let logger = Log.logger(category: "rebase")

/// The app-specific results from attempting to rebase a repository
public enum RebaseResult: String, Hashable, Sendable {
    /// Git completed the rebase without reporting any errors, and the caller can
    /// signal success to the user.
    case completedWithoutError = "CompletedWithoutError"
    /// Git completed the rebase without reporting any errors, but the branch was
    /// already up to date and there was nothing to do.
    case alreadyUpToDate = "AlreadyUpToDate"
    /// The rebase encountered conflicts while attempting to rebase, and these
    /// need to be resolved by the user before the rebase can continue.
    case conflictsEncountered = "ConflictsEncountered"
    /// The rebase was not able to continue as tracked files were not staged in
    /// the index.
    case outstandingFilesNotStaged = "OutstandingFilesNotStaged"
    /// The rebase was not attempted because it could not check the status of the
    /// repository. The caller needs to confirm the repository is in a usable
    /// state.
    case aborted = "Aborted"
    /// An unexpected error as part of the rebase flow was caught and handled.
    ///
    /// Check the logs to find the relevant Git details.
    case error = "Error"
}

/// The hooks git runs while rebasing (measured with git 2.53: `pre-rebase`
/// before it starts, `post-checkout` when it detaches HEAD onto the base,
/// `prepare-commit-msg` and `post-commit` for every commit it creates, and
/// `post-rewrite` at the end).
///
/// They are intercepted, as for `git pull --rebase` and for commits. The
/// app's own environment, launched from the Finder, has no login shell
/// `PATH`, so hooks that need node, npx, or Homebrew tools would fail there:
/// a failing `prepare-commit-msg` would stop the rebase in the middle with a
/// raw git error, and a failing `pre-rebase` would refuse it.
public let rebaseInterceptedHooks = [
    "pre-rebase",
    "post-checkout",
    "prepare-commit-msg",
    "post-commit",
    "post-rewrite",
]

/// Configuration for every rebase command (see `gitRebaseArguments()`).
///
/// `DugiteError` recognizes rebase conflicts by git's "Resolve all
/// conflicts manually" hint, which git prints only while
/// `advice.mergeConflict` is on (and git's own hint suggests turning it off).
/// Without it, a conflicted rebase would read as a merge conflict, and the
/// rebase would stop with a raw error instead of reporting its conflicts.
/// `GIT_ADVICE=0` would turn the hint off as well; see `rebaseEnvironment`.
public let rebaseConflictAdviceArguments = ["-c", "advice.mergeConflict=true"]

/// The environment every rebase command adds: `GIT_ADVICE` is removed, since
/// `GIT_ADVICE=0` overrides `advice.mergeConflict` (see
/// `rebaseConflictAdviceArguments`).
public let rebaseEnvironment: [String: String?] = ["GIT_ADVICE": nil]

/// Check the `.git/REBASE_HEAD` file exists in a repository to confirm
/// a rebase operation is underway.
func isRebaseHeadSet(_ repository: Repository) async -> Bool {
    let path = POSIXPath.join(repository.resolvedGitDir, "REBASE_HEAD")
    return await pathExists(path)
}

/// Whether the repository's git directory holds the state of a rebase,
/// stopped or not.
///
/// `REBASE_HEAD` exists only while git waits for the user (conflicts,
/// `edit`, a failed command). A rebase interrupted between two commits (its
/// process killed, or its task cancelled) leaves `rebase-merge` without it.
public func isRebaseStateDirectoryPresent(_ repository: Repository) -> Bool {
    for name in ["rebase-merge", "rebase-apply"] {
        var isDirectory: ObjCBool = false
        let path = POSIXPath.join(repository.resolvedGitDir, name)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return true
        }
    }
    return false
}

/// The file decoded as UTF-8, or nil when it is missing or can't be read.
private func readRebaseFile(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else {
        return nil
    }
    return String(decoding: data, as: UTF8.self)
}

/// Get the internal state about the rebase being performed on a repository. This
/// information is required to help Espalier display information to the user
/// about the current action as well as the options available.
///
/// Returns `nil` if no rebase is detected, or if the expected information
/// cannot be found in the repository.
public func getRebaseInternalState(_ repository: Repository) async -> RebaseInternalState? {
    let isRebase = await isRebaseHeadSet(repository)

    if !isRebase {
        return nil
    }

    // A rebase with git's apply backend (`git rebase --apply`,
    // `rebase.backend = apply`) keeps the same three files in
    // `rebase-apply`, which `git am` uses too without a `rebasing` marker.
    // Without it, such a rebase stopped on conflicts would show no rebase at
    // all, though its state directory makes checkouts refuse.
    var stateDirectory = POSIXPath.join(repository.resolvedGitDir, "rebase-merge")
    let rebaseApply = POSIXPath.join(repository.resolvedGitDir, "rebase-apply")
    if !FileManager.default.fileExists(atPath: stateDirectory),
       FileManager.default.fileExists(atPath: POSIXPath.join(rebaseApply, "rebasing")) {
        stateDirectory = rebaseApply
    }

    /// The file decoded as UTF-8, or nil when it can't be read.
    func readFile(_ name: String) -> String? {
        guard let data = FileManager.default.contents(atPath: POSIXPath.join(stateDirectory, name)) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // A missing file leaves the later ones unread; the result is nil either
    // way.
    guard let originalBranchTip = readFile("orig-head").map(JSCompat.trim),
          var targetBranch = readFile("head-name"),
          let baseBranchTip = readFile("onto").map(JSCompat.trim)
    else {
        // unable to resolve the rebase state of this repository
        return nil
    }

    if JSCompat.startsWith(targetBranch, "refs/heads/") {
        targetBranch = JSCompat.dropFirst(targetBranch, 11)
    }
    // Every `head-name` loses the file's trailing newline, not only a
    // `refs/heads/` name (git writes "detached HEAD" when rebasing a
    // detached HEAD).
    targetBranch = JSCompat.trim(targetBranch)

    return RebaseInternalState(
        targetBranch: targetBranch,
        baseBranchTip: baseBranchTip,
        originalBranchTip: originalBranchTip
    )
}

/// Inspect the `.git/rebase-merge` folder and convert the current rebase state
/// into data that can be provided to the rebase flow to update the application
/// state.
///
/// This is required when Espalier is not responsible for initiating the rebase:
///
///   - when a rebase outside Espalier encounters conflicts
///   - when a `git pull --rebase` was run and encounters conflicts
public func getRebaseSnapshot(_ repository: Repository) async throws -> GitRebaseSnapshot? {
    let rebaseHead = await isRebaseHeadSet(repository)
    if !rebaseHead {
        return nil
    }

    var next = -1
    var last = -1
    var originalBranchTip: String?
    var baseBranchTip: String?

    // if the repository is in the middle of a rebase `.git/rebase-merge` will
    // contain all the patches of commits that are being rebased into
    // auto-incrementing files, e.g. `0001`, `0002`, `0003`, etc ...

    var rebaseMerge = POSIXPath.join(repository.resolvedGitDir, "rebase-merge")
    // As in `getRebaseInternalState`, git's apply backend keeps its state in
    // `rebase-apply`, numbering patches in `next` and `last`.
    var msgnumName = "msgnum"
    var endName = "end"
    let rebaseApply = POSIXPath.join(repository.resolvedGitDir, "rebase-apply")
    if !FileManager.default.fileExists(atPath: rebaseMerge),
       FileManager.default.fileExists(atPath: POSIXPath.join(rebaseApply, "rebasing")) {
        rebaseMerge = rebaseApply
        msgnumName = "next"
        endName = "last"
    }

    // A missing file leaves the later ones unread.
    readFiles: do {
        // this contains the patch number that was recently applied to the repository
        guard let nextText = readRebaseFile(POSIXPath.join(rebaseMerge, msgnumName)) else {
            break readFiles
        }

        if let parsed = JSCompat.parseInt(nextText) {
            next = parsed
        } else {
            logger.warning("[getCurrentProgress] found '\(nextText, privacy: .private)' in .git/rebase-merge/msgnum which could not be parsed to a valid number")
            next = -1
        }

        // this contains the total number of patches to be applied to the repository
        guard let lastText = readRebaseFile(POSIXPath.join(rebaseMerge, endName)) else {
            break readFiles
        }

        if let parsed = JSCompat.parseInt(lastText) {
            last = parsed
        } else {
            logger.warning("[getCurrentProgress] found '\(lastText, privacy: .private)' in .git/rebase-merge/last which could not be parsed to a valid number")
            last = -1
        }

        guard let orig = readRebaseFile(POSIXPath.join(rebaseMerge, "orig-head")) else {
            break readFiles
        }
        originalBranchTip = JSCompat.trim(orig)

        guard let onto = readRebaseFile(POSIXPath.join(rebaseMerge, "onto")) else {
            break readFiles
        }
        baseBranchTip = JSCompat.trim(onto)
    }

    guard next > 0, last > 0, let originalBranchTip, let baseBranchTip else {
        return nil
    }

    let percentage = Double(next) / Double(last)
    let value = formatRebaseValue(percentage)

    let commits = try await getCommitsBetweenCommits(repository, baseBranchTip, originalBranchTip)

    guard let commits, !commits.isEmpty else {
        return nil
    }

    // this number starts from 1, but our array of commits starts from 0
    let nextCommitIndex = next - 1

    let hasValidCommit = commits.count > 0 && nextCommitIndex >= 0 && nextCommitIndex < commits.count

    let currentCommitSummary = hasValidCommit ? commits[nextCommitIndex].summary : ""

    return GitRebaseSnapshot(
        commits: commits,
        progress: MultiCommitOperationProgress(
            value: value,
            currentCommitSummary: currentCommitSummary,
            position: next,
            totalCommitCount: last
        )
    )
}

/// Which step a rebase (a squash, a reorder) is at, from git's own state
/// files: `msgnum`, the command it's on counting from 1, and `end`, the
/// commands in all, in `rebase-merge`; `next` and `last` in `rebase-apply`
/// for git's apply backend. Nil without a rebase's state directory, or when
/// either file is missing or doesn't hold a step from 1 to the total.
///
/// `getRebaseSnapshot` reads the same files, then the commits with git; this
/// only reads the files.
public func getRebaseStep(_ repository: Repository) async -> OperationStep? {
    let gitDir = repository.resolvedGitDir
    let fileManager = FileManager.default
    var directory = POSIXPath.join(gitDir, "rebase-merge")
    var positionName = "msgnum"
    var totalName = "end"
    if !fileManager.fileExists(atPath: directory) {
        // `rebase-apply` is `git am`'s too; a rebase marks its own.
        let rebaseApply = POSIXPath.join(gitDir, "rebase-apply")
        guard fileManager.fileExists(atPath: POSIXPath.join(rebaseApply, "rebasing")) else {
            return nil
        }
        directory = rebaseApply
        positionName = "next"
        totalName = "last"
    }
    guard let position = readRebaseFile(POSIXPath.join(directory, positionName)).flatMap(JSCompat.parseInt),
          let total = readRebaseFile(POSIXPath.join(directory, totalName)).flatMap(JSCompat.parseInt),
          position >= 1, position <= total
    else {
        return nil
    }
    return OperationStep(position: position, total: total)
}

/// Attempt to read the `.git/REBASE_HEAD` file inside a repository to confirm
/// the rebase is still active.
private func readRebaseHead(_ repository: Repository) -> String? {
    let rebaseHead = POSIXPath.join(repository.resolvedGitDir, "REBASE_HEAD")
    guard let rebaseCurrentCommitOutput = readRebaseFile(rebaseHead) else {
        logger.warning("[rebase] a problem was encountered reading .git/REBASE_HEAD, so it is unsafe to continue rebasing")
        return nil
    }
    return JSCompat.trim(rebaseCurrentCommitOutput)
}

/// Regex for identifying when rebase applied each commit onto the base branch
///
/// `/^Rebasing \((\d+)\/(\d+)\)$/`
private let rebasingRe = JSCompat.regex("^Rebasing \\((\(JSCompat.digit)+)/(\(JSCompat.digit)+)\\)\\z")

/// A parser to read and emit rebase progress from Git `stderr`
struct GitRebaseParser: Sendable {
    let commits: [CommitOneLine]

    init(_ commits: [CommitOneLine]) {
        self.commits = commits
    }

    func parse(_ line: String) -> MultiCommitOperationProgress? {
        guard let match = JSCompat.match(line, rebasingRe), match.count == 3,
              let rebasedText = match[1], let totalText = match[2]
        else {
            // Git will sometimes emit other output (for example, when it tries to
            // resolve conflicts) and this does not match the expected output
            return nil
        }

        guard let rebasedCommitCount = JSCompat.parseInt(rebasedText),
              let totalCommitCount = JSCompat.parseInt(totalText)
        else {
            return nil
        }

        let index = rebasedCommitCount - 1
        let currentCommitSummary = commits.indices.contains(index) ? commits[index].summary : ""

        let progress = Double(rebasedCommitCount) / Double(totalCommitCount)
        let value = formatRebaseValue(progress)

        return MultiCommitOperationProgress(
            value: value,
            currentCommitSummary: currentCommitSummary,
            position: rebasedCommitCount,
            totalCommitCount: totalCommitCount
        )
    }
}

/// Reads one git process's standard error line by line, and reports the
/// rebase progress in it.
///
/// Output arrives on the process's queue, one chunk at a time, and the last
/// lines when it closes, so callbacks run off the main thread, one at a time,
/// and all of them before `git()` returns.
private final class RebaseProgressReader: Sendable {
    private let lines = Mutex(LineSplitter())
    private let parser: GitRebaseParser
    private let progressCallback: @Sendable (MultiCommitOperationProgress) -> Void

    init(_ parser: GitRebaseParser, _ progressCallback: @escaping @Sendable (MultiCommitOperationProgress) -> Void) {
        self.parser = parser
        self.progressCallback = progressCallback
    }

    func receive(_ chunk: Data) {
        lines.withLock { lines in
            for line in lines.push(chunk) {
                handle(line)
            }
        }
    }

    func finish() {
        lines.withLock { lines in
            for line in lines.finish() {
                handle(line)
            }
        }
    }

    private func handle(_ line: String) {
        if let progress = parser.parse(line) {
            progressCallback(progress)
        }
    }
}

private func configureOptionsForRebase(
    _ options: GitExecutionOptions,
    _ progress: RebaseProgressOptions?
) -> GitExecutionOptions {
    guard let progress else {
        return options
    }

    let commits = progress.commits
    let progressCallback = progress.progressCallback

    var merged = options
    merged.processCallback = { process in
        let reader = RebaseProgressReader(GitRebaseParser(commits), progressCallback)
        process.observeStandardError { chunk in
            reader.receive(chunk)
        }
        process.onClose {
            reader.finish()
        }
    }
    return merged
}

/// A function to use for initiating rebase in the app.
///
/// If the rebase fails, the repository will be in an indeterminate state where
/// the rebase is stuck.
///
/// If the rebase completes without error, `featureBranch` will be checked out
/// and it will probably have a different commit history.
///
/// - Parameters:
///   - baseBranch: the branch to rebase onto, by its full ref
///   - targetBranch: the local branch to rebase onto `baseBranch`, by its
///     name
///   - progressCallback: Called with the progress of the rebase, off the main
///     thread, one call at a time, all before this returns.
public func rebase(
    _ repository: Repository,
    _ baseBranch: Branch,
    _ targetBranch: Branch,
    progressCallback: (@Sendable (MultiCommitOperationProgress) -> Void)? = nil
) async throws -> RebaseResult {
    let baseOptions = GitExecutionOptions(
        env: rebaseEnvironment,
        expectedErrors: [.rebaseConflicts],
        interceptHooks: rebaseInterceptedHooks
    )

    var options = baseOptions

    if let progressCallback {
        let commits = try await getCommitsBetweenCommits(repository, baseBranch.tip.sha, targetBranch.tip.sha)

        guard let commits else {
            // BadRevision can be raised here if git rev-list is unable to resolve a
            // ref to a commit ID, so we need to signal to the caller that this rebase
            // is not possible to perform
            logger.warning("Unable to rebase these branches because one or both of the refs do not exist in the repository")
            return .error
        }

        options = configureOptionsForRebase(baseOptions, RebaseProgressOptions(
            commits: commits,
            progressCallback: progressCallback
        ))
    }

    // The upstream is the base branch's full ref: by its short name, git
    // would rebase onto a tag of that name. The branch to rebase stays its
    // name (from its ref, as git keeps it), which git looks up as a branch
    // (`refs/heads/<name>`) and checks out; git takes anything else, its
    // full ref included, as a commit, and would rebase a detached HEAD,
    // leaving the branch behind.
    let result = try await git(
        gitRebaseArguments() + [
            "rebase",
            "--",
            baseBranch.ref,
            branchNameFromRef(targetBranch),
        ],
        repository.path,
        "rebase",
        options: options
    )

    return try parseRebaseResult(result)
}

/// Abandon the current rebase operation
public func abortRebase(_ repository: Repository) async throws {
    try await git(["rebase", "--abort"], repository.path, "abortRebase")
}

/// Ends the rebase whose state the git directory holds without going back
/// anywhere (`git rebase --quit`): HEAD, the index, and the working tree
/// stay as they are, and an autostash goes to the stash list as
/// "autostash". It needs none of the state's files, so it ends a rebase
/// whose files are missing.
///
/// Each `--quit` removes one state directory, `rebase-apply` before
/// `rebase-merge`, so it runs until neither is left. Git leaves
/// `REBASE_HEAD`, which means nothing without a state directory, so it's
/// deleted then.
///
/// Throws git's error: git refuses `git am`'s `rebase-apply`
/// (`.applyingPatchesInProgress`).
public func quitRebase(_ repository: Repository) async throws {
    for _ in 0..<2 where isRebaseStateDirectoryPresent(repository) {
        try await git(["rebase", "--quit"], repository.path, "quitRebase")
    }
    guard !isRebaseStateDirectoryPresent(repository),
          FileManager.default.fileExists(atPath: POSIXPath.join(repository.resolvedGitDir, "REBASE_HEAD"))
    else {
        return
    }
    try await git(["update-ref", "-d", "REBASE_HEAD"], repository.path, "quitRebase")
}

/// `/^Current branch [^ ]+ is up to date.$/i`
private let upToDateRe = try! NSRegularExpression(
    pattern: "^Current branch [^ ]+ is up to date.\\z",
    options: [.caseInsensitive]
)

private func parseRebaseResult(_ result: GitResult) throws -> RebaseResult {
    if result.exitCode == 0 {
        // Any line counts: standard output also holds "Created autostash:
        // ..." when `rebase.autoStash` stashed local changes.
        let lines = JSCompat.split(JSCompat.trim(result.stdout), "\n")
        if lines.contains(where: { JSCompat.match($0, upToDateRe) != nil }) {
            return .alreadyUpToDate
        }

        return .completedWithoutError
    }

    if result.gitError == .rebaseConflicts {
        return .conflictsEncountered
    }

    if result.gitError == .unresolvedConflicts {
        return .outstandingFilesNotStaged
    }

    let stderr = result.stderr
    throw GitLibError(
        "Unhandled result found: exit code \(result.exitCode), git error \(result.gitError?.rawValue ?? "none")"
            + (stderr.isEmpty ? "" : "\n\(stderr)")
    )
}

/// The `commit.cleanup` modes that keep git's own comment lines (the list of
/// conflicted files and the commit template) in a message nobody edits.
private let cleanupModesKeepingComments: Set<String> = ["whitespace", "verbatim", "scissors"]

/// Whether `--continue` and `--skip` should strip comments from the messages
/// git proposes.
///
/// After conflicts, git proposes each commit's message with its comment
/// lines added for an editor to show, and the rebase accepts it unedited
/// (`GIT_EDITOR=:`). With `commit.cleanup` set to `whitespace`, `verbatim`,
/// or `scissors` those lines would stay, writing the conflict list and git's
/// commit template into the rebased commit's message. Those settings are
/// overridden with `strip` here; every other setting already strips them.
///
/// Not while a `fixup -C` is still to come: `squash` gives the squashed
/// commit its message that way, and `strip` would drop the message's lines
/// that start with `#`.
private func shouldStripProposedMessages(_ repository: Repository) async -> Bool {
    guard let mode = (try? await getConfigValue(repository, "commit.cleanup")) ?? nil,
          cleanupModesKeepingComments.contains(mode)
    else {
        return false
    }
    return !isMessageFixupPending(repository)
}

/// Whether the stopped rebase still has to run a `fixup -C` or `fixup -c`
/// (the stopped command, the last one done, or one left to do).
private func isMessageFixupPending(_ repository: Repository) -> Bool {
    let rebaseMerge = POSIXPath.join(repository.resolvedGitDir, "rebase-merge")
    let done = readRebaseFile(POSIXPath.join(rebaseMerge, "done")).map { JSCompat.split($0, "\n") } ?? []
    let todo = readRebaseFile(POSIXPath.join(rebaseMerge, "git-rebase-todo")).map { JSCompat.split($0, "\n") } ?? []

    func isMessageFixup(_ line: String) -> Bool {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 2, words[0] == "fixup" || words[0] == "f" else {
            return false
        }
        return words[1] == "-C" || words[1] == "-c"
    }

    let lastDone = done.last { !JSCompat.trim($0).isEmpty }
    return lastDone.map(isMessageFixup) == true || todo.contains(where: isMessageFixup)
}

/// Proceed with the current rebase operation and report back on whether it completed
///
/// It is expected that the index has staged files which are cleanly rebased onto
/// the base branch, and the remaining unstaged files are those which need manual
/// resolution or were changed by the user to address inline conflicts.
///
/// - Parameters:
///   - files: The working directory's files. Tracked files are staged,
///     except those in `manualResolutions`.
///   - manualResolutions: The conflicted files to resolve by taking our or
///     their version, by path.
///   - opts: The editor, progress, and hook callbacks. `noVerify` is
///     ignored: git accepts `--no-verify` only when a rebase starts (it skips
///     the `pre-rebase` hook); `rebase --continue --no-verify` fails with
///     git's usage message.
public func continueRebase(
    _ repository: Repository,
    _ files: [WorkingDirectoryFileChange],
    _ manualResolutions: [String: ManualConflictResolution] = [:],
    _ opts: RebaseInteractiveOptions? = nil
) async throws -> RebaseResult {
    let trackedFiles = files.filter { f in
        f.status.kind != .untracked
    }

    // apply conflict resolutions
    //
    // A dictionary has no order, so the paths are taken in byte order.
    let resolvedPaths = manualResolutions.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    for (path, resolution) in resolvedPaths {
        if let file = files.first(where: { JSCompat.strictEquals($0.path, path) }) {
            try await stageManualConflictResolution(repository, file, resolution)
        } else {
            logger.error("[continueRebase] couldn't find file \(path, privacy: .private) even though there's a manual resolution for it")
        }
    }

    // Paths compare exactly.
    let manuallyResolved = Set(manualResolutions.keys.map(ExactString.init))
    let otherFiles = trackedFiles.filter { f in
        !manuallyResolved.contains(ExactString(f.path))
    }

    try await stageFiles(repository, otherFiles)

    guard let status = try await getStatus(repository, includeUntracked: false) else {
        logger.warning("[continueRebase] unable to get status after staging changes, skipping any other steps")
        return .aborted
    }

    guard let rebaseCurrentCommit = readRebaseHead(repository) else {
        return .aborted
    }

    let trackedFilesAfter = status.workingDirectory.files.filter { f in
        f.status.kind != .untracked
    }

    var env = rebaseEnvironment
    env["GIT_EDITOR"] = opts?.gitEditor ?? ":"

    let baseOptions = GitExecutionOptions(
        env: env,
        expectedErrors: [.rebaseConflicts, .unresolvedConflicts],
        interceptHooks: rebaseInterceptedHooks
    )

    var options = baseOptions

    if let progressCallback = opts?.progressCallback {
        guard let snapshot = try await getRebaseSnapshot(repository) else {
            logger.warning("[continueRebase] unable to get rebase status, skipping any other steps")
            return .aborted
        }

        options = configureOptionsForRebase(baseOptions, RebaseProgressOptions(
            commits: snapshot.commits,
            progressCallback: progressCallback
        ))
    }

    options.onTerminalOutputAvailable = opts?.onTerminalOutputAvailable
    options.onHookFailure = opts?.onHookFailure
    options.onHookProgress = opts?.onHookProgress

    var config = rebaseConflictAdviceArguments
    if opts?.gitEditor == nil, await shouldStripProposedMessages(repository) {
        config += ["-c", "commit.cleanup=strip"]
    }

    if trackedFilesAfter.isEmpty {
        logger.warning("[rebase] no tracked changes to commit for \(rebaseCurrentCommit, privacy: .public), continuing rebase but skipping this commit")

        let result = try await git(
            config + ["rebase", "--skip"],
            repository.path,
            "continueRebaseSkipCurrentCommit",
            options: options
        )

        return try parseRebaseResult(result)
    }

    let result = try await git(
        config + ["rebase", "--continue"],
        repository.path,
        "continueRebase",
        options: options
    )

    return try parseRebaseResult(result)
}

/// Options for `rebaseInteractive` and `continueRebase`, with the hook
/// callbacks.
public struct RebaseInteractiveOptions: Sendable {
    /// a description of the action to be displayed with the progress - i.e. Squash, Amend, etc..
    public var action: String?

    /// the GIT_EDITOR environment variable to use during the interactive rebase,
    /// defaults to ':' which is a no-op command
    public var gitEditor: String?

    public var progressCallback: (@Sendable (MultiCommitOperationProgress) -> Void)?

    /// The commits in the order the rebase applies them, which the progress
    /// reports name.
    public var commits: [CommitOneLine]?

    public var noVerify: Bool

    public var onHookProgress: (@Sendable (HookProgress) -> Void)?

    public var onHookFailure: (@Sendable (_ hookName: String, _ terminalOutput: TerminalOutput) async -> HookFailureResolution)?

    public var onTerminalOutputAvailable: TerminalOutputCallback?

    public init(
        action: String? = nil,
        gitEditor: String? = nil,
        progressCallback: (@Sendable (MultiCommitOperationProgress) -> Void)? = nil,
        commits: [CommitOneLine]? = nil,
        noVerify: Bool = false,
        onHookProgress: (@Sendable (HookProgress) -> Void)? = nil,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? = nil,
        onTerminalOutputAvailable: TerminalOutputCallback? = nil
    ) {
        self.action = action
        self.gitEditor = gitEditor
        self.progressCallback = progressCallback
        self.commits = commits
        self.noVerify = noVerify
        self.onHookProgress = onHookProgress
        self.onHookFailure = onHookFailure
        self.onTerminalOutputAvailable = onTerminalOutputAvailable
    }
}

/// Method for initiating interactive rebase in the app.
///
/// In order to modify the interactive todo list during interactive rebase, we
/// create a temporary todo list of our own. Pass that file's path into our
/// interactive rebase and using the sequence.editor to cat replace the
/// interactive todo list with the contents of our generated one.
///
/// Commits that become empty are kept (`--empty=keep`). Otherwise
/// `--interactive` stops at such a commit as if for an edit, and git exits
/// with an error, leaving the rebase stopped.
///
/// - Parameters:
///   - pathOfGeneratedTodo: path to generated todo list for interactive rebase
///   - lastRetainedCommitRef: the commit before the earliest commit to be
///     changed during the interactive rebase or nil if commit is root (first
///     commit in history) of branch
public func rebaseInteractive(
    _ repository: Repository,
    _ pathOfGeneratedTodo: String,
    _ lastRetainedCommitRef: String?,
    _ opts: RebaseInteractiveOptions? = nil
) async throws -> RebaseResult {
    var env = rebaseEnvironment
    // A sequence editor in the environment would win over the one below.
    env["GIT_SEQUENCE_EDITOR"] = .some(nil)
    env["GIT_EDITOR"] = opts?.gitEditor ?? ":"

    let baseOptions = GitExecutionOptions(
        env: env,
        expectedErrors: [.rebaseConflicts],
        interceptHooks: rebaseInterceptedHooks
    )

    var options = baseOptions

    if let progressCallback = opts?.progressCallback {
        guard let commits = opts?.commits else {
            logger.warning("Unable to interactively rebase if no commits")
            return .error
        }

        options = configureOptionsForRebase(baseOptions, RebaseProgressOptions(
            commits: commits,
            progressCallback: progressCallback
        ))
    }

    options.onHookProgress = opts?.onHookProgress
    options.onHookFailure = opts?.onHookFailure
    options.onTerminalOutputAvailable = opts?.onTerminalOutputAvailable

    // If the commit is the first commit in the branch, we cannot reference it
    // using the sha thus if lastRetainedCommitRef is nil (we couldn't define it),
    // we must use the --root flag. A ref follows `--`, so that it can't be
    // read as an option.
    let ref = lastRetainedCommitRef.map { ["--", $0] } ?? ["--root"]

    let result = try await git(
        [
            "-c",
            // This replaces interactive todo with contents of file at pathOfGeneratedTodo
            "sequence.editor=cat \(posixShellQuote(pathOfGeneratedTodo)) >",
        ]
            + rebaseConflictAdviceArguments
            + ["rebase"]
            + (opts?.noVerify == true ? ["--no-verify"] : [])
            + ["-i", "--empty=keep"]
            + ref,
        repository.path,
        opts?.action ?? "Interactive rebase",
        options: options
    )

    return try parseRebaseResult(result)
}

// MARK: - The todo lists squash and reorder write

/// One line of the todo list that `squash` or `reorder` hands to
/// `rebaseInteractive`.
struct RebaseTodoStep: Sendable {
    enum Command: String, Sendable {
        case pick
        case fixup
    }

    /// The todo command, with its options.
    let command: String
    let sha: String
    let summary: String
    /// Whether the step replays one of the branch's commits. The step that
    /// gives a squashed commit its message doesn't.
    let replaysCommit: Bool

    init(_ command: Command, _ commit: Commit) {
        self.command = command.rawValue
        sha = commit.sha
        summary = commit.summary
        replaysCommit = true
    }

    private init(command: String, sha: String) {
        self.command = command
        self.sha = sha
        summary = ""
        replaysCommit = false
    }

    /// Takes the message of `sha` for the commit the previous fixups made.
    static func message(_ sha: String) -> RebaseTodoStep {
        RebaseTodoStep(command: "fixup -C", sha: sha)
    }

    var todoLine: String {
        "\(command) \(sha) \(summary)\n"
    }
}

/// Checks that an interactive rebase from `lastRetainedCommitRef` replays
/// exactly `commits`, the log of `lastRetainedCommitRef..HEAD`. Throws
/// `GitLibError` when it wouldn't.
///
/// Picking a merge commit fails in the middle of the rebase (it has no
/// mainline), and a last retained commit that isn't an ancestor of HEAD
/// (HEAD moved after the commits were chosen) would move the branch onto it.
func checkInteractiveRebaseRange(
    _ repository: Repository,
    _ commits: [Commit],
    _ lastRetainedCommitRef: String?,
    operation: String
) async throws {
    if commits.contains(where: \.isMergeCommit) {
        throw GitLibError("[\(operation)] A merge commit cannot exist among the commits to replay.")
    }

    if let lastRetainedCommitRef {
        let result = try await git(
            ["merge-base", "--is-ancestor", "--end-of-options", lastRetainedCommitRef, "HEAD"],
            repository.path,
            "isAncestor",
            options: GitExecutionOptions(successExitCodes: [0, 1, 128])
        )
        if result.exitCode != 0 {
            throw GitLibError("[\(operation)] The last retained commit is not an ancestor of HEAD.")
        }
    }
}

/// Runs `rebaseInteractive` with the todo list at `todoPath`, holding
/// `steps`, and reports progress by the commits replayed.
///
/// If git fails other than with conflicts after the rebase started (a hook
/// fails, a commit can't be signed, a squash leaves nothing to commit), the
/// rebase is aborted, so the branch is as it was, and the error is thrown.
/// A rebase that was already in progress is left alone, and so is one this
/// call started if its task is cancelled: `abortRebase` recovers it.
func runRebaseTodo(
    _ repository: Repository,
    _ todoPath: String,
    _ lastRetainedCommitRef: String?,
    action: MultiCommitOperationKind,
    steps: [RebaseTodoStep],
    progressCallback: (@Sendable (MultiCommitOperationProgress) -> Void)?
) async throws -> RebaseResult {
    let rebaseWasInProgress = isRebaseStateDirectoryPresent(repository)

    do {
        return try await rebaseInteractive(
            repository,
            todoPath,
            lastRetainedCommitRef,
            RebaseInteractiveOptions(
                action: action.rawValue,
                progressCallback: progressCallback.map { reportingCommitSteps(steps, $0) },
                // The todo list's commits, in its order, so progress names
                // the commits being replayed.
                commits: steps.map { CommitOneLine(sha: $0.sha, summary: $0.summary) }
            )
        )
    } catch {
        if !(error is CancellationError), !Task.isCancelled, !rebaseWasInProgress, isRebaseStateDirectoryPresent(repository) {
            do {
                try await abortRebase(repository)
            } catch let abortError {
                logger.error("[\(action.rawValue, privacy: .public)] could not abort the stopped rebase: \(abortError.localizedDescription, privacy: .public)")
            }
        }
        throw error
    }
}

/// Reports progress by the commits replayed: git counts every step of the
/// todo list, including the one that gives a squashed commit its message,
/// which is reported as nothing new.
private func reportingCommitSteps(
    _ steps: [RebaseTodoStep],
    _ callback: @escaping @Sendable (MultiCommitOperationProgress) -> Void
) -> @Sendable (MultiCommitOperationProgress) -> Void {
    var replayed = 0
    // For each step, the number of commits replayed once it's done, or nil
    // for a step that replays none.
    let positions: [Int?] = steps.map { step in
        guard step.replaysCommit else {
            return nil
        }
        replayed += 1
        return replayed
    }
    let total = replayed

    return { progress in
        let index = progress.position - 1
        guard progress.totalCommitCount == steps.count, positions.indices.contains(index) else {
            // Not numbered by this todo list; pass it on as git reported it.
            callback(progress)
            return
        }
        guard let position = positions[index] else {
            return
        }
        callback(MultiCommitOperationProgress(
            value: formatRebaseValue(Double(position) / Double(total)),
            currentCommitSummary: progress.currentCommitSummary,
            position: position,
            totalCommitCount: total
        ))
    }
}

/// Writes `contents` to a new file at `path`, readable only by the user.
/// Fails if the file already exists.
func writeRebaseTemporaryFile(_ path: String, _ contents: String) throws {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(descriptor) }

    let bytes = Array(contents.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        }
        if written < 0 {
            if errno == EINTR {
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        offset += written
    }
}
