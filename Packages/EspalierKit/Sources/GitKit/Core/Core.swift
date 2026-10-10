// Ported from desktop/app/src/lib/git/core.ts

import EspalierSupport
import Foundation
import os

/// A chunk of terminal output (combined stdout and stderr) from a git process.
public typealias TerminalOutput = String

/// Subscribes to a git process's terminal output. The callback first receives
/// everything captured so far, then every new chunk.
public typealias TerminalOutputListener = @Sendable (
    _ callback: @escaping @Sendable (TerminalOutput) -> Void
) -> TerminalOutputSubscription

/// Receives a `subscribe` function for each git process an operation starts.
public typealias TerminalOutputCallback = @Sendable (_ subscribe: @escaping TerminalOutputListener) -> Void

/// Stops a terminal output subscription.
public struct TerminalOutputSubscription: Sendable {
    public let unsubscribe: @Sendable () -> Void

    public init(unsubscribe: @escaping @Sendable () -> Void) {
        self.unsubscribe = unsubscribe
    }
}

/// The progress of a hook that git runs during an operation.
public enum HookProgress: Sendable {
    case started(hookName: String, abort: @Sendable () -> Void)
    case finished(hookName: String)
    case failed(hookName: String)

    public var hookName: String {
        switch self {
        case .started(let name, _), .finished(let name), .failed(let name): name
        }
    }
}

/// What to do after a hook fails.
public enum HookFailureResolution: String, Sendable {
    case abort
    case ignore
}

/// Configuration options for the execution of git.
///
/// Extends `Dugite.ExecutionOptions` with options of its own.
public struct GitExecutionOptions: Sendable {
    // MARK: dugite's options

    /// Environment variables to set before executing git. A `nil` value
    /// removes the variable.
    public var env: [String: String?]?

    /// Written to git's standard input right after it starts.
    public var stdin: Data?

    /// Largest number of bytes allowed on stdout or stderr; see
    /// `Dugite.ExecutionOptions.maxBuffer`.
    public var maxBuffer: Int?

    /// Invoked with the child process right after it starts.
    public var processCallback: (@Sendable (ChildProcess) -> Void)?

    /// The signal sent to git when the calling task is cancelled.
    public var killSignal: Int32

    /// Whether cancelling signals git's whole process group, its helpers
    /// too (`Dugite.ExecutionOptions.killsProcessGroup`).
    public var killsProcessGroup = false

    /// Whether git gets the runtime's `defaultLocale` when its environment
    /// has no locale (`Dugite.ExecutionOptions.addsDefaultLocale`). Off
    /// for commands whose output depends on git matching a regex: in a
    /// UTF-8 locale, `.` doesn't match a byte that isn't UTF-8.
    public var addsDefaultLocale = true

    // MARK: git()'s options

    /// The exit codes which indicate success to the caller. Unexpected exit
    /// codes will be logged and an error thrown. Defaults to 0.
    public var successExitCodes: Set<Int>

    /// The git errors which are expected by the caller. Unexpected errors will
    /// be logged and an error thrown.
    public var expectedErrors: Set<DugiteError>

    /// Should it track and report LFS progress?
    public var trackLFSProgress: Bool

    /// Whether the command about to run is part of a background task or not.
    /// This affects error handling and UI such as credential prompts.
    public var isBackgroundTask: Bool

    /// Hooks to run through the hooks proxy, so they execute in the user's
    /// login shell environment and report progress.
    public var interceptHooks: [String]?

    public var onHookProgress: (@Sendable (HookProgress) -> Void)?

    /// Asked what to do when a hook fails, given its name and terminal output.
    public var onHookFailure: (@Sendable (_ hookName: String, _ terminalOutput: TerminalOutput) async -> HookFailureResolution)?

    public var onTerminalOutputAvailable: TerminalOutputCallback?

    public init(
        env: [String: String?]? = nil,
        stdin: Data? = nil,
        maxBuffer: Int? = nil,
        processCallback: (@Sendable (ChildProcess) -> Void)? = nil,
        killSignal: Int32 = SIGTERM,
        successExitCodes: Set<Int> = [0],
        expectedErrors: Set<DugiteError> = [],
        trackLFSProgress: Bool = false,
        isBackgroundTask: Bool = false,
        interceptHooks: [String]? = nil,
        onHookProgress: (@Sendable (HookProgress) -> Void)? = nil,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? = nil,
        onTerminalOutputAvailable: TerminalOutputCallback? = nil
    ) {
        self.env = env
        self.stdin = stdin
        self.maxBuffer = maxBuffer
        self.processCallback = processCallback
        self.killSignal = killSignal
        self.successExitCodes = successExitCodes
        self.expectedErrors = expectedErrors
        self.trackLFSProgress = trackLFSProgress
        self.isBackgroundTask = isBackgroundTask
        self.interceptHooks = interceptHooks
        self.onHookProgress = onHookProgress
        self.onHookFailure = onHookFailure
        self.onTerminalOutputAvailable = onTerminalOutputAvailable
    }

    /// Convenience for `stdin` from text, encoded as UTF-8.
    public init(stdin text: String, successExitCodes: Set<Int> = [0], expectedErrors: Set<DugiteError> = []) {
        self.init(stdin: Data(text.utf8), successExitCodes: successExitCodes, expectedErrors: expectedErrors)
    }
}

/// The result of using git. This wraps dugite's result to provide the parsed
/// error if one occurs.
public struct GitResult: Sendable {
    /// The standard output from git, as bytes.
    public let stdoutData: Data

    /// The standard error output from git, as bytes.
    public let stderrData: Data

    /// The exit code of the git process.
    public let exitCode: Int

    /// The parsed git error. `nil` when the exit code is one of the
    /// `successExitCodes`, or when the error couldn't be parsed.
    public let gitError: DugiteError?

    /// The human-readable error description, based on `gitError`.
    public let gitErrorDescription: String?

    /// The path that the git command was executed from, i.e. the process
    /// working directory (not to be confused with the git working directory).
    public let path: String

    public init(
        stdoutData: Data,
        stderrData: Data,
        exitCode: Int,
        gitError: DugiteError?,
        gitErrorDescription: String?,
        path: String
    ) {
        self.stdoutData = stdoutData
        self.stderrData = stderrData
        self.exitCode = exitCode
        self.gitError = gitError
        self.gitErrorDescription = gitErrorDescription
        self.path = path
    }

    /// The standard output decoded as UTF-8 (invalid bytes become U+FFFD).
    /// Decodes on every access, so bind it once.
    public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }

    /// The standard error decoded as UTF-8 (invalid bytes become U+FFFD).
    public var stderr: String { String(decoding: stderrData, as: UTF8.self) }
}

/// A git command failed in a way its caller didn't expect.
public struct GitError: Error, CustomStringConvertible, LocalizedError {
    /// The result from the failed command.
    public let result: GitResult

    /// The args for the failed command.
    public let args: [String]

    /// The error message: the parsed error's description, or else git's raw
    /// output.
    public let message: String

    /// Whether or not the error message is just the raw output of the git
    /// command.
    public let isRawMessage: Bool

    public init(result: GitResult, args: [String], terminalOutput: String) {
        if let description = result.gitErrorDescription {
            message = description
            isRawMessage = false
        } else if !terminalOutput.isEmpty {
            message = terminalOutput
            isRawMessage = true
        } else if !result.stderrData.isEmpty {
            message = result.stderr
            isRawMessage = true
        } else if !result.stdoutData.isEmpty {
            message = result.stdout
            isRawMessage = true
        } else {
            message = "Unknown error (exit code \(result.exitCode))"
            isRawMessage = false
        }

        self.result = result
        self.args = args
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Whether `error` is a `GitError`, optionally one whose parsed error is
/// `parsedError`.
public func isGitError(_ error: any Error, _ parsedError: DugiteError? = nil) -> Bool {
    guard let error = error as? GitError else { return false }
    return parsedError == nil || error.result.gitError == parsedError
}

private let logger = Log.logger(category: "git")

/// Shell out to git with the given arguments, at the given path.
///
/// - Parameters:
///   - args: The arguments to pass to `git`.
///   - path: The working directory path for the execution of the command.
///   - name: The name for the command based on its caller's context. This
///     will be used for performance measurements and debugging.
///   - options: Configuration options for the execution of git.
///
/// Returns the result. If the command exits with a code not in
/// `successExitCodes` or an error not in `expectedErrors`, a `GitError` will
/// be thrown.
@discardableResult
public func git(
    _ args: [String],
    _ path: String,
    _ name: String,
    options: GitExecutionOptions = GitExecutionOptions()
) async throws -> GitResult {
    let runtime = GitRuntime.current

    // The combined contents of stdout and stderr with some light processing
    // applied to remove redundant lines caused by git's use of `\r` to
    // "erase" the current line while writing progress output.
    //
    // Note: the output is capped at a maximum of 256kb and its sole intent is
    // to provide "terminal-like" output to the user when a git command fails.
    let terminal = TerminalOutputRecorder(capacity: 256 * 1024)

    var configured = options
    configured.processCallback = { process in
        if let onTerminalOutputAvailable = options.onTerminalOutputAvailable {
            onTerminalOutputAvailable { callback in terminal.subscribe(callback) }
        }

        process.observeStandardOutput { terminal.push($0, from: .stdout) }
        process.observeStandardError { terminal.push($0, from: .stderr) }

        options.processCallback?(process)
    }
    let opts = configured

    return try await withHooksEnv(path: path, options: opts, runtime: runtime) { hooksEnv in
        try await withTrampolineEnv(path: path, isBackgroundTask: opts.isBackgroundTask, customEnv: hooksEnv, runtime: runtime) { trampolineEnv in
            let commandName = "\(name): git \(args.joined(separator: " "))"

            // Explicitly set TERM to 'dumb' so that if Espalier was launched
            // from a terminal or if the system environment variables have
            // TERM set git won't consider us as a smart terminal.
            // See https://github.com/git/git/blob/a7312d1a2/editor.c#L11-L15
            var env: [String: String?] = ["TERM": "dumb"]
            env.merge(opts.env ?? [:]) { $1 }
            env.merge(hooksEnv ?? [:]) { $1 }
            env.merge(trampolineEnv) { $1 }

            let result: Dugite.Result
            do {
                result = try await GitPerf.measure(commandName) {
                    try await Dugite.exec(
                        args,
                        path,
                        options: Dugite.ExecutionOptions(
                            env: env,
                            stdin: opts.stdin,
                            maxBuffer: opts.maxBuffer,
                            processCallback: opts.processCallback,
                            killSignal: opts.killSignal,
                            killsProcessGroup: opts.killsProcessGroup,
                            addsDefaultLocale: opts.addsDefaultLocale
                        ),
                        runtime: runtime
                    )
                }
            } catch let error as ExecError where error.isMaxBufferExceeded {
                // Keep the details but name the operation.
                throw ExecError(
                    message: "\(error.message) for \(name)",
                    stdout: error.stdout,
                    stderr: error.stderr,
                    code: error.code
                )
            }

            // Subscribers have received all of the output before git()
            // returns.
            if opts.onTerminalOutputAvailable != nil {
                await terminal.flush()
            }

            let exitCode = result.exitCode
            let stderr = String(decoding: result.stderr, as: UTF8.self)

            var gitError: DugiteError?
            let acceptableExitCode = opts.successExitCodes.contains(exitCode)
            if !acceptableExitCode {
                gitError = Dugite.parseError(stderr)
                    ?? Dugite.parseError(String(decoding: result.stdout, as: UTF8.self))
            }

            let gitErrorDescription = gitError.flatMap { getDescriptionForError($0, stderr) }
            let gitResult = GitResult(
                stdoutData: result.stdout,
                stderrData: result.stderr,
                exitCode: exitCode,
                gitError: gitError,
                gitErrorDescription: gitErrorDescription,
                path: path
            )

            var acceptableError = true
            if let gitError {
                acceptableError = opts.expectedErrors.contains(gitError)
            }

            if (gitError != nil && acceptableError) || acceptableExitCode {
                return gitResult
            }

            // The caller should either handle this error, or expect that exit
            // code.
            let terminalOutput = terminal.output()
            var errorMessage = ["`git \(args.joined(separator: " "))` exited with an unexpected code: \(exitCode)."]
            if !terminalOutput.isEmpty {
                // Leave even less of the combined output in the log
                errorMessage.append(String(terminalOutput.suffix(1024)))
            }
            if let gitError {
                errorMessage.append("(The error was parsed as \(gitError.rawValue): \(gitErrorDescription ?? "null"))")
            }
            logger.error("\(errorMessage.joined(separator: "\n"), privacy: .public)")

            throw GitError(result: gitResult, args: args, terminalOutput: terminalOutput)
        }
    }
}

/// Determine whether the provided `error` is an authentication failure as per
/// our definition. Note that this is not an exhaustive list of authentication
/// failures, only a collection of errors that we treat equally in terms of
/// error message and presentation to the user.
public func isAuthFailureError(_ error: DugiteError) -> Bool {
    switch error {
    case .sshAuthenticationFailed, .sshPermissionDenied, .httpsAuthenticationFailed:
        true
    default:
        false
    }
}

/// Determine whether the provided `error` is an error from git indicating that
/// a configuration file write failed due to a lock file already existing for
/// that config file.
public func isConfigFileLockError(_ error: any Error) -> Bool {
    (error as? GitError)?.result.gitError == .configLockFileAlreadyExists
}

private let lockFilePathRe = try! NSRegularExpression(
    pattern: "^error: could not lock config file (.+?): File exists$",
    options: [.anchorsMatchLines]
)

/// If the `result` is associated with a config lock file error (as determined
/// by `isConfigFileLockError`) this method will attempt to extract an absolute
/// path (i.e. rooted) to the configuration lock file in question from the git
/// output.
public func parseConfigLockFilePathFromError(_ result: GitResult) -> String? {
    let stderr = result.stderr
    guard let match = lockFilePathRe.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
          let range = Range(match.range(at: 1), in: stderr)
    else {
        return nil
    }

    // https://github.com/git/git/blob/232378479/lockfile.h#L117-L119
    return POSIXPath.resolve(result.path, "\(stderr[range]).lock")
}

/// A user-facing description of `error`, or `nil` to show git's own output.
public func getDescriptionForError(_ error: DugiteError, _ stderr: String) -> String? {
    if isAuthFailureError(error) {
        return """
            Authentication failed. Some common reasons:

            - You're not signed in to your account. Sign in from Espalier ▸ Settings ▸ Accounts.
            - Your sign-in needs refreshing. Sign out, then sign in again.
            - You don't have permission to access this repository.
            - The repository is archived on GitHub. Check its settings to confirm you can still push to it.
            - With SSH, your key isn't added to the SSH agent or isn't linked to your account.
            - With SSH, the host key for your hosting service couldn't be verified.
            - With a username and password, you may need a personal access token instead of your account password. Check your hosting service's documentation.
            """
    }

    switch error {
    case .badConfigValue:
        guard let errorInfo = Dugite.parseBadConfigValueErrorInfo(stderr) else {
            return "Git doesn't support a value in your configuration."
        }
        return "Git doesn't support the value \u{201C}\(errorInfo.value)\u{201D} for \(errorInfo.key) in your configuration."
    case .sshKeyAuditUnverified:
        return "The SSH key is unverified."
    case .remoteDisconnection:
        return "The remote disconnected. Check your internet connection and try again."
    case .hostDown:
        return "The host is down. Check your internet connection and try again."
    case .rebaseConflicts:
        return "The rebase stopped at conflicts. Resolve them to continue."
    case .mergeConflicts:
        return "The merge has conflicts. Resolve them, then commit the changes."
    case .httpsRepositoryNotFound, .sshRepositoryNotFound:
        return "The repository can't be found. You may not have access to it, or it may have been deleted or renamed."
    case .pushNotFastForward:
        return "The remote has commits you don't have yet. Pull, then push again."
    case .branchDeletionFailed:
        return "Could not delete the branch. It was probably already deleted."
    case .defaultBranchDeletionFailed:
        return "The branch is the repository's default branch and cannot be deleted."
    case .revertConflicts:
        return "The revert has conflicts. Resolve them, then commit the changes to finish reverting."
    case .emptyRebasePatch:
        return "There aren’t any changes left to apply."
    case .noMatchingRemoteBranch:
        return "There aren’t any remote branches that match the current branch."
    case .nothingToCommit:
        return "There are no changes to commit."
    case .noSubmoduleMapping:
        return "A submodule was removed from .gitmodules, but the folder still exists in the repository. Delete the folder, commit the change, then try again."
    case .submoduleRepositoryDoesNotExist:
        return "A submodule points to a location that doesn't exist."
    case .invalidSubmoduleSHA:
        return "A submodule points to a commit that doesn't exist."
    case .localPermissionDenied:
        return "Permission denied."
    case .invalidMerge:
        return "Git can't merge this."
    case .invalidRebase:
        return "Git can't rebase this."
    case .nonFastForwardMergeIntoEmptyHead:
        return "This merge isn't a fast-forward, so it can't be done on a branch with no commits."
    case .patchDoesNotApply:
        return "The requested changes conflict with one or more files in the repository."
    case .branchAlreadyExists:
        return "A branch with that name already exists."
    case .badRevision:
        return "Bad revision."
    case .notAGitRepository:
        return "This isn't a Git repository."
    case .protectedBranchForcePush:
        return "This branch is protected from force pushes."
    case .protectedBranchRequiresReview:
        return "This branch is protected, and changes to it need an approved review. Open a pull request for this branch instead."
    case .pushWithFileSizeExceedingLimit:
        return "The push includes a file larger than GitHub's 100 MB limit. Remove the file from your history and try again."
    case .hexBranchNameRejected:
        return "A branch name can't be 40 hexadecimal characters, because Git uses that format for object IDs."
    case .forcePushRejected:
        return "The remote rejected the force push to the current branch."
    case .invalidRefLength:
        return "A ref cannot be longer than 255 characters."
    case .cannotMergeUnrelatedHistories:
        return "These branches have unrelated histories and can't be merged."
    case .pushWithPrivateEmail:
        return "These commits use an email address marked private on GitHub, so they can't be pushed. To push anyway, turn off \u{201C}Keep my email addresses private\u{201D} at https://github.com/settings/emails, push from Espalier, then turn the setting back on."
    case .lfsAttributeDoesNotMatch:
        return "A Git LFS setting in your global Git configuration doesn't have the value Git LFS expects."
    case .protectedBranchDeleteRejected:
        return "This branch is protected, so it can't be deleted from the remote."
    case .protectedBranchRequiredStatus:
        return "The remote rejected the push because a required status check hasn't passed."
    case .branchRenameFailed:
        return "The branch could not be renamed."
    case .pathDoesNotExist:
        return "The path does not exist on disk."
    case .invalidObjectName:
        return "The object was not found in the Git repository."
    case .outsideRepository:
        return "This path isn't inside the repository."
    case .lockFileAlreadyExists:
        return "A lock file in the repository is blocking this operation."
    case .noMergeToAbort:
        return "There's no merge to abort."
    case .noExistingRemoteBranch:
        return "The remote branch does not exist."
    case .localChangesOverwritten:
        return "Switching branches would overwrite changes in your working directory. Commit or stash them first."
    case .unresolvedConflicts:
        return "There are unresolved conflicts in the working directory."
    case .configLockFileAlreadyExists:
        // Returning nil deliberately means the stderr will be used as the
        // error message (or stdout if stderr is empty).
        return nil
    case .remoteAlreadyExists:
        return nil
    case .tagAlreadyExists:
        return "A tag with that name already exists."
    case .rebaseWithStagedChanges:
        let action = stderr.contains("cannot pull with rebase:") ? "pull with rebase" : "rebase"
        return "Can't \(action) while you have uncommitted changes. Commit or stash them first."
    case .rebaseAlreadyInProgress:
        return "A rebase is already in progress. Finish or abort it first."
    case .applyingPatchesInProgress:
        return "Git is applying patches (git am). Finish or abort that in Terminal first."
    case .mergeWithLocalChanges,
         .rebaseWithLocalChanges,
         .gpgFailedToSignData,
         .conflictModifyDeletedInBranch,
         .mergeCommitNoMainlineOption,
         .unsafeDirectory,
         .pathExistsButNotInRef,
         .pushWithSecretDetected:
        return nil
    case .sshAuthenticationFailed, .sshPermissionDenied, .httpsAuthenticationFailed:
        // Handled by isAuthFailureError above.
        return nil
    }
}

/// Returns the arguments to use on any git operation that can end up
/// triggering a rebase.
public func gitRebaseArguments() -> [String] {
    // Explicitly set the rebase backend to merge. We need to force this option
    // to be sure that Espalier uses the merge backend even if the user has the
    // apply backend configured, since this is the only one supported. This
    // can go away once git deprecates the apply backend.
    ["-c", "rebase.backend=merge"]
        // `DugiteError` recognizes rebase conflicts by a hint git prints only
        // while this advice is on. With it off, a conflicted rebase would read
        // as a merge conflict (see `rebaseConflictAdviceArguments`).
        + rebaseConflictAdviceArguments
}

/// Returns the SHA of the passed in result of `git commit`, whose first line
/// looks like `[main 1a2b3c4] Commit summary`.
///
/// Git prints `[<branch>[ (root-commit)] <abbreviated SHA>] <summary>`, with
/// `detached HEAD` for the branch on a detached HEAD, so the second word
/// before the first `]` is `(root-commit)` for a first commit, `HEAD` on a
/// detached HEAD, and nothing for a branch whose name contains `]`. Branch
/// names can't contain spaces, so the SHA is the last word before the first
/// `] `.
public func parseCommitSHA(_ result: GitResult) -> String {
    let stdout = result.stdout
    let firstLine = JSCompat.split(stdout, "\n")[0]
    if JSCompat.startsWith(firstLine, "["), let end = firstLine.range(of: "] ", options: .literal) {
        if let sha = firstLine[..<end.lowerBound].split(separator: " ").last {
            return String(sha)
        }
    }

    let beforeBracket = stdout.split(separator: "]", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    let parts = beforeBracket.split(separator: " ", omittingEmptySubsequences: false)
    return parts.count > 1 ? String(parts[1]) : ""
}

// MARK: - Hooks and trampoline seams

/// The environment that lets git call back into the app for credentials and
/// SSH prompts. The app implements this with its askpass server; see
/// `GitRuntime.trampoline`.
public protocol GitTrampoline: Sendable {
    func withTrampolineEnv<T: Sendable>(
        path: String,
        isBackgroundTask: Bool,
        customEnv: [String: String?]?,
        _ operation: @Sendable ([String: String?]) async throws -> T
    ) async throws -> T
}

/// Routes the hooks named in `options.interceptHooks` through the hooks
/// proxy, so they run in the user's login shell environment and report
/// progress. The operation receives the environment to add (or `options.env`
/// when nothing is intercepted).
public protocol GitHooksEnvironment: Sendable {
    func withHooksEnv<T: Sendable>(
        path: String,
        options: GitExecutionOptions,
        _ operation: @Sendable ([String: String?]?) async throws -> T
    ) async throws -> T
}

func withHooksEnv<T: Sendable>(
    path: String,
    options: GitExecutionOptions,
    runtime: GitRuntime,
    _ operation: @Sendable ([String: String?]?) async throws -> T
) async throws -> T {
    if let hooks = runtime.hooks, options.interceptHooks != nil {
        return try await hooks.withHooksEnv(path: path, options: options, operation)
    }
    return try await operation(options.env)
}

func withTrampolineEnv<T: Sendable>(
    path: String,
    isBackgroundTask: Bool,
    customEnv: [String: String?]?,
    runtime: GitRuntime,
    _ operation: @Sendable ([String: String?]) async throws -> T
) async throws -> T {
    if let trampoline = runtime.trampoline {
        return try await trampoline.withTrampolineEnv(
            path: path,
            isBackgroundTask: isBackgroundTask,
            customEnv: customEnv,
            operation
        )
    }
    return try await operation([:])
}
