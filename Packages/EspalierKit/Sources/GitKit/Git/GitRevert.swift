// Ported from desktop/app/src/lib/git/revert.ts

import EspalierSupport

/// The hooks git runs while reverting, the same as while cherry-picking
/// (`cherryPickInterceptedHooks`): a revert commits as a cherry-pick does,
/// and continuing it, or committing its resolution, runs `git commit`'s.
public let revertInterceptedHooks = cherryPickInterceptedHooks

/// Creates a new commit that reverts the changes of a previous commit
///
/// When the revert conflicts, git leaves the repository mid-revert
/// (`REVERT_HEAD`, conflicted files in the index) and this throws a
/// `GitError` whose `gitError` is `.revertConflicts`. The caller can offer to
/// resolve the conflicts and commit, or run `git revert --abort`.
///
/// - Parameters:
///   - repository: The repository to update
///   - commit: The commit to be reverted. A merge commit is reverted
///     relative to its first parent (`-m 1`).
///   - currentRemote: The repository's current remote, for the proxy
///     lookup; see `getFallbackUrlForProxyResolve`.
///   - progressCallback: Receives the progress of Git LFS, which is all a
///     revert reports. Only with a progress callback does the revert get the
///     environment of a remote operation.
///   - gitHubHTMLURL: The web URL of the repository's GitHub endpoint, if
///     any; see `getFallbackUrlForProxyResolve`.
public func revertCommit(
    _ repository: Repository,
    _ commit: Commit,
    _ currentRemote: Remote?,
    _ progressCallback: (@Sendable (RevertProgress) -> Void)? = nil,
    gitHubHTMLURL: String? = nil
) async throws {
    var args = ["revert"]
    if commit.parentSHAs.count > 1 {
        args += ["-m", "1"]
    }

    args.append(commit.sha)

    var opts = GitExecutionOptions(interceptHooks: revertInterceptedHooks)
    if let progressCallback {
        let env = await envForRemoteOperation(
            getFallbackUrlForProxyResolve(repository, currentRemote, gitHubHTMLURL: gitHubHTMLURL)
        )
        opts = await executionOptionsWithProgress(
            GitExecutionOptions(env: env, trackLFSProgress: true, interceptHooks: revertInterceptedHooks),
            RevertProgressParser()
        ) { progress in
            let description: String
            let title: String
            switch progress {
            case .progress(let gitProgress):
                description = gitProgress.details.text
                title = gitProgress.details.title
            case .context(let output):
                description = output.text
                title = ""
            }
            let value = progress.percent

            progressCallback(RevertProgress(value: value, title: title, description: description))
        }
    }

    try await git(args, repository.path, "revert", options: opts)
}

/// Check if the `.git/REVERT_HEAD` file exists: a revert stopped on
/// conflicts and waits for them to be resolved.
///
/// The counterpart of `isCherryPickHeadFound`. In a linked worktree the file
/// is in the worktree's git directory, so `repository.gitDir` must be set.
public func isRevertHeadFound(_ repository: Repository) async -> Bool {
    await pathExists(POSIXPath.join(repository.resolvedGitDir, "REVERT_HEAD"))
}
