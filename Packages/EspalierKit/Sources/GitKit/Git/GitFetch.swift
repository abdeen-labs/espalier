// Ported from desktop/app/src/lib/git/fetch.ts

import EspalierSupport
import Foundation

private func getFetchArgs(_ remote: String, hasProgressCallback: Bool) -> [String] {
    ["fetch"]
        + (hasProgressCallback ? ["--progress"] : [])
        + [
            "--prune",
            "--recurse-submodules=on-demand",
            "--",
            remote,
        ]
}

/// Fetch from the given remote.
///
/// - Parameters:
///   - repository: The repository to fetch into
///   - remote: The remote to fetch from
///   - progressCallback: An optional function which will be invoked
///     with information about the current progress
///     of the fetch operation. When provided this enables
///     the '--progress' command line flag for
///     'git fetch'.
///   - isBackgroundTask: Whether the fetch is being performed as a
///     background task as opposed to being user initiated
public func fetch(
    _ repository: Repository,
    _ remote: Remote,
    progressCallback: (@Sendable (FetchProgress) -> Void)? = nil,
    isBackgroundTask: Bool = false
) async throws {
    // `isBackgroundTask` applies to every fetch, with or without a progress
    // callback.
    var opts = GitExecutionOptions(
        env: await envForRemoteOperation(remote.url),
        successExitCodes: [0],
        isBackgroundTask: isBackgroundTask
    )

    if let progressCallback {
        let title = "Fetching \(remote.name)"

        opts.trackLFSProgress = true
        opts = await executionOptionsWithProgress(opts, FetchProgressParser()) { progress in
            // In addition to progress output from the remote end and from
            // git itself, the stderr output from pull contains information
            // about ref updates. We don't need to bring those into the progress
            // stream so we'll just punt on anything we don't know about for now.
            if case .context(let output) = progress {
                if !JSCompat.startsWith(output.text, "remote: Counting objects") {
                    return
                }
            }

            progressCallback(FetchProgress(
                value: progress.percent,
                title: title,
                description: progress.text,
                remote: remote.name
            ))
        }

        // Initial progress
        progressCallback(FetchProgress(value: 0, title: title, remote: remote.name))
    }

    let args = getFetchArgs(remote.name, hasProgressCallback: progressCallback != nil)

    try await git(args, repository.path, "fetch", options: opts)
}

/// Fetch a given refspec from the given remote.
public func fetchRefspec(_ repository: Repository, _ remote: Remote, _ refspec: String) async throws {
    try await git(
        ["fetch", "--", remote.name, refspec],
        repository.path,
        "fetchRefspec",
        options: GitExecutionOptions(
            env: await envForRemoteOperation(remote.url),
            successExitCodes: [0, 128]
        )
    )
}

/// Fast-forwards the given branches to their upstreams, with `git fetch .`.
/// Branches that can't be fast-forwarded are left as they are.
public func fastForwardBranches(_ repository: Repository, _ branches: [TrackingBranch]) async throws {
    if branches.isEmpty {
        return
    }

    let refPairs = branches.map { "\($0.upstreamRef):\($0.ref)" }

    try await git(
        [
            "fetch",
            ".",
            // Make sure we don't try to update branches that can't be fast-forwarded
            // even if the user disabled this via the git config option
            // `fetch.showForcedUpdates`
            "--show-forced-updates",
            // Prevent `git fetch` from touching the `FETCH_HEAD`
            "--no-write-fetch-head",
            // Take branch refs from stdin to circumvent shell max line length
            // limitations (mainly on Windows)
            "--stdin",
        ],
        repository.path,
        "fastForwardBranches",
        options: GitExecutionOptions(
            env: [
                // This will make sure the reflog entries are correct after
                // fast-forwarding the branches.
                "GIT_REFLOG_ACTION": "pull",
            ],
            stdin: Data(refPairs.joined(separator: "\n").utf8),
            // Fetch exits with an exit code of 1 if one or more refs failed to update
            // which is what we expect will happen
            successExitCodes: [0, 1]
        )
    )
}
