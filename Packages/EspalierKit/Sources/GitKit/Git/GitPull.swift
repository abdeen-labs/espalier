// Ported from desktop/app/src/lib/git/pull.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "pull")

/// The error `pull` throws for a remote whose name git would read as an
/// option.
public struct PullRemoteNameError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public init() {}

    public var description: String { "Cannot pull from a remote whose name starts with '-'." }
    public var errorDescription: String? { description }
}

/// Options for `pull`.
public struct PullOptions: Sendable {
    /// An optional function which will be invoked with information about the
    /// current progress of the pull operation. When provided this enables the
    /// '--progress' command line flag for 'git pull'.
    public var progressCallback: (@Sendable (PullProgress) -> Void)?

    public var onHookProgress: (@Sendable (HookProgress) -> Void)?

    public var onHookFailure: (@Sendable (_ hookName: String, _ terminalOutput: TerminalOutput) async -> HookFailureResolution)?

    public var onTerminalOutputAvailable: TerminalOutputCallback?

    public var noVerify: Bool

    /// Invoked with `git pull`'s process right after it starts, as
    /// `stopPullFetch(_:)` takes it.
    public var processCallback: (@Sendable (ChildProcess) -> Void)?

    public init(
        progressCallback: (@Sendable (PullProgress) -> Void)? = nil,
        onHookProgress: (@Sendable (HookProgress) -> Void)? = nil,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? = nil,
        onTerminalOutputAvailable: TerminalOutputCallback? = nil,
        noVerify: Bool = false,
        processCallback: (@Sendable (ChildProcess) -> Void)? = nil
    ) {
        self.progressCallback = progressCallback
        self.onHookProgress = onHookProgress
        self.onHookFailure = onHookFailure
        self.onTerminalOutputAvailable = onTerminalOutputAvailable
        self.noVerify = noVerify
        self.processCallback = processCallback
    }
}

/// Pull from the specified remote.
///
/// - Parameters:
///   - repository: The repository in which the pull should take place
///   - remote: The name of the remote that should be pulled from
///   - options: The progress callback, hook callbacks, and whether to skip
///     hooks; see `PullOptions`.
public func pull(_ repository: Repository, _ remote: Remote, _ options: PullOptions? = nil) async throws {
    // Git pull forwards the remote name to its child git fetch without a `--`
    // separator. Reject leading dashes here even though direct fetch and push
    // can handle them with a separator.
    if JSCompat.startsWith(remote.name, "-") {
        throw PullRemoteNameError()
    }

    var env = await envForRemoteOperation(remote.url)
    // `GIT_ADVICE=0` overrides the `advice.mergeConflict=true` that
    // `gitRebaseArguments()` sets, and without git's hint a pull with rebase
    // that stops on conflicts would read as a merge's conflicts. Rebase
    // commands remove it too (`rebaseEnvironment`).
    env.updateValue(nil, forKey: "GIT_ADVICE")

    var opts = GitExecutionOptions(
        env: env,
        // git pull triggers merge or rebase hooks depending on config, instead of
        // trying to check pull.rebase and friends we'll just intercept all possible
        // hooks that could be run as part of a pull operation.
        interceptHooks: [
            "pre-merge-commit",
            "prepare-commit-msg",
            "commit-msg",
            "post-merge",
            "pre-rebase",
            "pre-commit",
            "post-rewrite",
        ],
        // Passed on, so a hook failure during a pull reaches the caller.
        onHookProgress: options?.onHookProgress,
        onHookFailure: options?.onHookFailure,
        onTerminalOutputAvailable: options?.onTerminalOutputAvailable
    )

    if let progressCallback = options?.progressCallback {
        let title = "Pulling \(remote.name)"

        opts.trackLFSProgress = true
        opts = await executionOptionsWithProgress(opts, PullProgressParser()) { progress in
            // In addition to progress output from the remote end and from
            // git itself, the stderr output from pull contains information
            // about ref updates. We don't need to bring those into the progress
            // stream so we'll just punt on anything we don't know about for now.
            if case .context(let output) = progress {
                if !JSCompat.startsWith(output.text, "remote: Counting objects") {
                    return
                }
            }

            progressCallback(PullProgress(
                value: progress.percent,
                title: title,
                description: progress.text,
                remote: remote.name
            ))
        }

        // Initial progress
        progressCallback(PullProgress(value: 0, title: title, remote: remote.name))
    }

    // After the progress's, which reads the process's output.
    if let onProcess = options?.processCallback {
        let readsProgress = opts.processCallback
        opts.processCallback = { process in
            readsProgress?(process)
            onProcess(process)
        }
    }

    let args = gitRebaseArguments()
        + ["pull"]
        + (await getDefaultPullDivergentBranchArguments(repository))
        + ["--recurse-submodules"]
        + (options?.progressCallback != nil ? ["--progress"] : [])
        + (options?.noVerify == true ? ["--no-verify"] : [])
        + ["--", remote.name]

    try await git(args, repository.path, "pull", options: opts)
}

/// Stops a pull that's still fetching: ends the `git fetch` that `git pull`
/// runs and every process the fetch started (the transport, ssh,
/// upload-pack), so the pull fails before it merges or rebases. Once the
/// fetch is over, the pull is merging, rebasing, or updating submodules,
/// which stopping would leave half done in the working tree and the index,
/// and nothing is stopped.
///
/// - Parameter pull: The `git pull` process (`PullOptions.processCallback`).
/// - Returns: Whether a fetch was stopped.
@discardableResult
public func stopPullFetch(_ pull: ChildProcess) -> Bool {
    // While `git pull` hasn't been reaped, its identifier is its own.
    pull.whileRunning { pullID in
        let fetches = ProcessTree.children(of: pullID).filter { pid in
            ProcessTree.arguments(of: pid).map(isGitFetch) ?? false
        }
        guard !fetches.isEmpty else {
            return false
        }
        // Each fetch's processes are found before it ends, while they're
        // still its own.
        let processes = fetches.flatMap { [$0] + ProcessTree.descendants(of: $0) }
        for pid in processes {
            _ = kill(pid, SIGTERM)
        }
        return true
    }
}

/// Whether `arguments` run `git fetch`, as `git pull` runs it: `git`, then
/// `fetch`.
func isGitFetch(_ arguments: [String]) -> Bool {
    arguments.count >= 2
        && JSCompat.strictEquals(POSIXPath.basename(arguments[0]), "git")
        && JSCompat.strictEquals(arguments[1], "fetch")
}

/// Defaults the pull default for divergent paths to try to fast forward and if
/// not perform a merge. Aka uses the flag --ff
///
/// It checks whether the user has a config set for this already, if so, no need for
/// default.
private func getDefaultPullDivergentBranchArguments(_ repository: Repository) async -> [String] {
    do {
        let pullFF = try await getConfigValue(repository, "pull.ff")
        return pullFF != nil ? [] : ["--ff"]
    } catch {
        logger.error("Couldn't read 'pull.ff' config: \(error.localizedDescription, privacy: .public)")
    }

    // If there is a failure in checking the config, we still want to use any
    // config and not overwrite the user's set config behavior. This will show the
    // git error if no config is set.
    return []
}
