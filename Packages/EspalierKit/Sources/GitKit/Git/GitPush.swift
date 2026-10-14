// Ported from desktop/app/src/lib/git/push.ts

import Foundation

/// Options for `push`.
public struct PushOptions: Sendable {
    /// Force-push the branch without losing changes in the remote that
    /// haven't been fetched.
    ///
    /// See https://git-scm.com/docs/git-push#Documentation/git-push.txt---no-force-with-lease
    public var forceWithLease: Bool

    /// The commit the remote branch must still be at for `forceWithLease`
    /// to overwrite it: `--force-with-lease=refs/heads/<remoteBranch>:<sha>`.
    /// Without it the lease is git's default, the remote-tracking branch.
    public var forceWithLeaseExpectedSHA: String?

    /// A branch to push instead of the current branch
    public var branch: Branch?

    public var noVerify: Bool

    public var onHookProgress: (@Sendable (HookProgress) -> Void)?

    public var onHookFailure: (@Sendable (_ hookName: String, _ terminalOutput: TerminalOutput) async -> HookFailureResolution)?

    public var onTerminalOutputAvailable: TerminalOutputCallback?

    public init(
        forceWithLease: Bool = false,
        forceWithLeaseExpectedSHA: String? = nil,
        branch: Branch? = nil,
        noVerify: Bool = false,
        onHookProgress: (@Sendable (HookProgress) -> Void)? = nil,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? = nil,
        onTerminalOutputAvailable: TerminalOutputCallback? = nil
    ) {
        self.forceWithLease = forceWithLease
        self.forceWithLeaseExpectedSHA = forceWithLeaseExpectedSHA
        self.branch = branch
        self.noVerify = noVerify
        self.onHookProgress = onHookProgress
        self.onHookFailure = onHookFailure
        self.onTerminalOutputAvailable = onTerminalOutputAvailable
    }
}

/// Push from the remote to the branch, optionally setting the upstream.
///
/// - Parameters:
///   - repository: The repository from which to push
///   - remote: The remote to push the specified branch to
///   - localBranch: The local branch to push
///   - remoteBranch: The remote branch to push to
///   - tagsToPush: The tags to push along with the branch.
///   - options: Optional customizations for the push execution.
///     see PushOptions for more information.
///   - progressCallback: An optional function which will be invoked
///     with information about the current progress
///     of the push operation. When provided this enables
///     the '--progress' command line flag for
///     'git push'.
public func push(
    _ repository: Repository,
    _ remote: Remote,
    _ localBranch: String,
    _ remoteBranch: String?,
    _ tagsToPush: [String]?,
    _ options: PushOptions? = nil,
    progressCallback: (@Sendable (PushProgress) -> Void)? = nil
) async throws {
    var args = ["push"]

    if remoteBranch == nil || remoteBranch?.isEmpty == true {
        args.append("--set-upstream")
    } else if options?.forceWithLease == true {
        if let remoteBranch, let expected = options?.forceWithLeaseExpectedSHA {
            args.append("--force-with-lease=refs/heads/\(remoteBranch):\(expected)")
        } else {
            args.append("--force-with-lease")
        }
    }

    if options?.noVerify == true {
        args.append("--no-verify")
    }

    var opts = GitExecutionOptions(
        env: await envForRemoteOperation(remote.url),
        interceptHooks: ["pre-push"],
        onHookProgress: options?.onHookProgress,
        onHookFailure: options?.onHookFailure,
        onTerminalOutputAvailable: options?.onTerminalOutputAvailable
    )

    if let progressCallback {
        args.append("--progress")
        let title = "Pushing to \(remote.name)"

        opts.trackLFSProgress = true
        opts = await executionOptionsWithProgress(opts, PushProgressParser()) { progress in
            progressCallback(PushProgress(
                value: progress.percent,
                title: title,
                description: progress.text,
                remote: remote.name,
                branch: localBranch
            ))
        }

        // Initial progress
        progressCallback(PushProgress(value: 0, title: title, remote: remote.name, branch: localBranch))
    }

    if let remoteBranch, !remoteBranch.isEmpty {
        args += ["--", remote.name, "\(localBranch):\(remoteBranch)"]
    } else {
        args += ["--", remote.name, localBranch]
    }

    if let tagsToPush {
        args += tagsToPush
    }

    try await git(args, repository.path, "push", options: opts)
}
