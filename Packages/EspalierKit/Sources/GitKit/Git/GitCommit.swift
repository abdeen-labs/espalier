// Ported from desktop/app/src/lib/git/commit.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "commit")

/// Options for `createCommit`.
public struct CreateCommitOptions: Sendable {
    /// Amend the tip of the current branch (`--amend`).
    public var amend: Bool

    /// Skip the pre-commit and commit-msg hooks (`--no-verify`).
    public var noVerify: Bool

    /// Add a Signed-off-by trailer (`--signoff`).
    public var signOff: Bool

    /// Allow a commit with no changes (`--allow-empty`).
    public var allowEmpty: Bool

    public var onHookProgress: (@Sendable (HookProgress) -> Void)?

    public var onHookFailure: (@Sendable (_ hookName: String, _ terminalOutput: TerminalOutput) async -> HookFailureResolution)?

    public var onTerminalOutputAvailable: TerminalOutputCallback?

    public init(
        amend: Bool = false,
        noVerify: Bool = false,
        signOff: Bool = false,
        allowEmpty: Bool = false,
        onHookProgress: (@Sendable (HookProgress) -> Void)? = nil,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? = nil,
        onTerminalOutputAvailable: TerminalOutputCallback? = nil
    ) {
        self.amend = amend
        self.noVerify = noVerify
        self.signOff = signOff
        self.allowEmpty = allowEmpty
        self.onHookProgress = onHookProgress
        self.onHookFailure = onHookFailure
        self.onTerminalOutputAvailable = onTerminalOutputAvailable
    }
}

/// Commits the given files, and only those: the index is reset to HEAD
/// first, then the files' selected changes are staged.
///
/// - Parameters:
///   - repository: repository to commit in
///   - message: commit message, passed to git on standard input with git's
///     default cleanup (trailing whitespace and blank lines are removed,
///     lines starting with `#` are kept)
///   - files: files to commit
///   - options: amend, skip hooks, sign off, allow an empty commit, and the
///     hook callbacks; see `CreateCommitOptions`.
/// - Returns: the commit SHA, abbreviated as git prints it
@discardableResult
public func createCommit(
    _ repository: Repository,
    _ message: String,
    _ files: [WorkingDirectoryFileChange],
    _ options: CreateCommitOptions? = nil
) async throws -> String {
    // Clear the staging area, our diffs reflect the difference between the
    // working directory and the last commit (if any) so our commits should
    // do the same thing.
    try await unstageAll(repository)

    try await stageFiles(repository, files)

    var args = ["-F", "-"]

    if options?.amend == true {
        args.append("--amend")
    }

    if options?.noVerify == true {
        args.append("--no-verify")
    }

    if options?.signOff == true {
        args.append("--signoff")
    }

    if options?.allowEmpty == true {
        args.append("--allow-empty")
    }

    let result = try await git(
        ["commit"] + args,
        repository.path,
        "createCommit",
        options: GitExecutionOptions(
            stdin: Data(message.utf8),
            // https://git-scm.com/docs/githooks/2.46.1
            interceptHooks: [
                "pre-commit",
                "prepare-commit-msg",
                "commit-msg",
                "post-commit",
            ] + (options?.amend == true ? ["post-rewrite"] : []) + [
                "pre-auto-gc",
            ],
            onHookProgress: options?.onHookProgress,
            onHookFailure: options?.onHookFailure,
            onTerminalOutputAvailable: options?.onTerminalOutputAvailable
        )
    )
    return parseCommitSHA(result)
}

/// The message and the hook callbacks for `createMergeCommit`.
public struct CreateMergeCommitOptions: Sendable {
    /// The message to commit the merge with, passed on standard input with
    /// git's default cleanup, as `createCommit` passes one; nil commits
    /// git's merge message.
    public var message: String?

    public var onHookProgress: (@Sendable (HookProgress) -> Void)?

    public var onHookFailure: (@Sendable (_ hookName: String, _ terminalOutput: TerminalOutput) async -> HookFailureResolution)?

    public var onTerminalOutputAvailable: TerminalOutputCallback?

    public init(
        message: String? = nil,
        onHookProgress: (@Sendable (HookProgress) -> Void)? = nil,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? = nil,
        onTerminalOutputAvailable: TerminalOutputCallback? = nil
    ) {
        self.message = message
        self.onHookProgress = onHookProgress
        self.onHookFailure = onHookFailure
        self.onTerminalOutputAvailable = onTerminalOutputAvailable
    }
}

/// Creates a commit to finish an in-progress merge
/// assumes that all conflicts have already been resolved
/// *Warning:* Does _not_ clear staged files before it commits!
///
/// Intercepts the hooks `git commit` runs, as `createCommit` does
/// (pre-commit, prepare-commit-msg, commit-msg, post-commit, pre-auto-gc), so
/// they run in the login shell's environment and report through `options`.
///
/// - Parameters:
///   - repository: repository to execute merge in
///   - files: files to commit
///   - manualResolutions: the side chosen for each conflicted file the user
///     resolved by picking ours or theirs, keyed by path
///   - options: the message, when it isn't git's, and the hook callbacks.
/// - Returns: the commit SHA, abbreviated as git prints it
@discardableResult
public func createMergeCommit(
    _ repository: Repository,
    _ files: [WorkingDirectoryFileChange],
    _ manualResolutions: [String: ManualConflictResolution] = [:],
    _ options: CreateMergeCommitOptions? = nil
) async throws -> String {
    // apply manual conflict resolutions (in a stable order, though the order
    // doesn't matter)
    for (path, resolution) in manualResolutions.sorted(by: { $0.key < $1.key }) {
        if let file = files.first(where: { JSCompat.strictEquals($0.path, path) }) {
            try await stageManualConflictResolution(repository, file, resolution)
        } else {
            logger.error("couldn't find file \(path, privacy: .private) even though there's a manual resolution for it")
        }
    }

    let resolvedPaths = Set(manualResolutions.keys.map(ExactString.init))
    let otherFiles = files.filter { !resolvedPaths.contains(ExactString($0.path)) }

    try await stageFiles(repository, otherFiles)

    // The user's message, as `createCommit` commits one: git concludes the
    // merge in progress with it (MERGE_HEAD the second parent).
    let messageArgs: [String]? = options?.message == nil ? nil : ["commit", "-F", "-"]
    let result = try await git(
        messageArgs ?? [
            "commit",
            // no-edit here ensures the app does not accidentally invoke the user's editor
            "--no-edit",
            // By default Git merge commits do not contain any commentary (which
            // are lines prefixed with `#`). This works because the Git CLI will
            // prompt the user to edit the file in `.git/COMMIT_MSG` before
            // committing, and then it will run `--cleanup=strip`.
            //
            // This clashes with our use of `--no-edit` above as Git will now change
            // it's behavior to invoke `--cleanup=whitespace` as it did not ask
            // the user to edit the COMMIT_MSG as part of creating a commit.
            //
            // From the docs on git-commit (https://git-scm.com/docs/git-commit) I'll
            // quote the relevant section:
            // --cleanup=<mode>
            //     strip
            //        Strip leading and trailing empty lines, trailing whitespace,
            //        commentary and collapse consecutive empty lines.
            //     whitespace
            //        Same as `strip` except #commentary is not removed.
            //     default
            //        Same as `strip` if the message is to be edited. Otherwise `whitespace`.
            //
            // We should emulate the behavior in this situation because we don't
            // let the user view or change the commit message before making the
            // commit.
            "--cleanup=strip",
        ],
        repository.path,
        "createMergeCommit",
        options: GitExecutionOptions(
            stdin: options?.message.map { Data($0.utf8) },
            // https://git-scm.com/docs/githooks: concluding a merge with
            // `git commit` runs the commit hooks (pre-commit, not git merge's
            // pre-merge-commit).
            interceptHooks: ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-auto-gc"],
            onHookProgress: options?.onHookProgress,
            onHookFailure: options?.onHookFailure,
            onTerminalOutputAvailable: options?.onTerminalOutputAvailable
        )
    )
    return parseCommitSHA(result)
}
