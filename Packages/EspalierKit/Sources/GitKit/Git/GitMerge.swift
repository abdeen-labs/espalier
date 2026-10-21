// Ported from desktop/app/src/lib/git/merge.ts
//
// "Already up to date." is recognized by git's English message. The bundled
// git has no locale data, so its messages are always English.

import EspalierSupport
import Foundation

public enum MergeResult: Hashable, Sendable {
    /// The merge completed successfully
    case success
    /// The merge was a noop since the current branch
    /// was already up to date with the target branch.
    case alreadyUpToDate
    /// The merge failed, likely due to conflicts.
    case failed
}

/// Options for `merge`, including the hook callbacks.
public struct MergeOptions: Sendable {
    /// Whether to perform a squash merge
    public var squash: Bool

    /// Whether to bypass the hooks that `--no-verify` skips: pre-merge-commit
    /// and commit-msg for a merge, pre-commit and commit-msg for the commit a
    /// squash merge makes. Git runs post-merge either way.
    public var noVerify: Bool

    public var onHookProgress: (@Sendable (HookProgress) -> Void)?

    public var onHookFailure: (@Sendable (_ hookName: String, _ terminalOutput: TerminalOutput) async -> HookFailureResolution)?

    public var onTerminalOutputAvailable: TerminalOutputCallback?

    /// The merge commit's message (`-m`) in place of the one git makes; git
    /// still adds the merged commits' summaries after it when `merge.log`
    /// is set.
    var message: String?

    public init(
        squash: Bool = false,
        noVerify: Bool = false,
        onHookProgress: (@Sendable (HookProgress) -> Void)? = nil,
        onHookFailure: (@Sendable (String, TerminalOutput) async -> HookFailureResolution)? = nil,
        onTerminalOutputAvailable: TerminalOutputCallback? = nil
    ) {
        self.squash = squash
        self.noVerify = noVerify
        self.onHookProgress = onHookProgress
        self.onHookFailure = onHookFailure
        self.onTerminalOutputAvailable = onTerminalOutputAvailable
    }
}

/// Merge the named branch into the current branch.
///
/// - A squash merge that has nothing to commit returns `alreadyUpToDate`
///   rather than running `git commit`, which would fail with "There are no
///   changes to commit.": git prints "Already up to date. (nothing to
///   squash)", and a branch squash-merged before is never an ancestor, so
///   merging it again stages nothing. The `SQUASH_MSG` such a merge writes
///   is removed, so status doesn't report a squash merge in progress.
/// - `noVerify` also applies to the commit a squash merge makes, where git
///   runs the pre-commit and commit-msg hooks; `git merge --squash` runs
///   neither.
/// - Every hook git runs is intercepted, so it runs in the login shell's
///   environment and reports failures: the merge also intercepts
///   prepare-commit-msg and pre-auto-gc, and the squash commit intercepts
///   pre-commit (which git commit runs) instead of pre-merge-commit (which it
///   never runs), the hooks `createCommit` intercepts.
///
/// git's errors other than conflicts, such as local changes the merge would
/// overwrite, unrelated histories, or `merge.ff=only` with diverged branches,
/// throw a `GitError`. A hook that fails or is aborted while git creates the
/// merge commit throws too, and leaves the merge in progress (`MERGE_HEAD`)
/// with its result staged, as git does.
public func merge(
    _ repository: Repository,
    _ branch: String,
    _ options: MergeOptions? = nil
) async throws -> MergeResult {
    let onTerminalOutputAvailable = options?.onTerminalOutputAvailable.map {
        createMultiOperationTerminalOutputCallback($0)
    }

    var args = ["merge"]

    if options?.squash == true {
        args.append("--squash")
    }

    if options?.noVerify == true {
        args.append("--no-verify")
    }

    if let message = options?.message {
        args.append(contentsOf: ["-m", message])
    }

    args.append(contentsOf: ["--", branch])

    let result = try await git(args, repository.path, "merge", options: GitExecutionOptions(
        expectedErrors: [.mergeConflicts],
        // https://git-scm.com/docs/githooks
        interceptHooks: ["pre-merge-commit", "prepare-commit-msg", "commit-msg", "post-merge", "pre-auto-gc"],
        onHookProgress: options?.onHookProgress,
        onHookFailure: options?.onHookFailure,
        onTerminalOutputAvailable: onTerminalOutputAvailable
    ))

    if result.exitCode != 0 {
        return .failed
    }

    let stdout = result.stdout

    if options?.squash == true {
        if JSCompat.strictEquals(stdout, noopSquashMergeMessage) || JSCompat.strictEquals(stdout, noopMergeMessage) {
            return .alreadyUpToDate
        }

        // The branch's changes are all in the current branch already, so
        // there's nothing to commit.
        if try await getIndexChanges(repository).isEmpty {
            // We don't want to surface an error if the file is already gone.
            try? FileManager.default.removeItem(atPath: POSIXPath.join(repository.resolvedGitDir, "SQUASH_MSG"))
            return .alreadyUpToDate
        }

        var commitArgs = ["commit", "--no-edit"]

        if options?.noVerify == true {
            commitArgs.append("--no-verify")
        }

        let commitResult = try await git(commitArgs, repository.path, "createSquashMergeCommit", options: GitExecutionOptions(
            interceptHooks: ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-auto-gc"],
            onHookProgress: options?.onHookProgress,
            onHookFailure: options?.onHookFailure,
            onTerminalOutputAvailable: onTerminalOutputAvailable
        ))

        if commitResult.exitCode != 0 {
            return .failed
        }
    }

    return JSCompat.strictEquals(stdout, noopMergeMessage) ? .alreadyUpToDate : .success
}

/// Merges `branch` into the current branch, and only that branch, as
/// `merge(_:_:_:)` merges a name.
///
/// Git reads a short name as the first ref it finds: a tag of the same name
/// (`refs/tags/<name>`) before the branch, and for a remote branch
/// (`origin/feature`) a local branch of that name before the remote-tracking
/// branch. While `branch`'s short name is the only ref git finds for it,
/// the branch is merged by that name, so the message ("Merge branch
/// 'feature'") and the conflict markers' label are git's own. Otherwise
/// it's merged by its full ref, with the message git makes for its short
/// name (`mergeTitle`); the conflict markers then name the full ref.
public func merge(
    _ repository: Repository,
    _ branch: Branch,
    _ options: MergeOptions? = nil
) async throws -> MergeResult {
    if try await nameResolvesOnlyToRef(repository, branch.name, branch.ref) {
        return try await merge(repository, branch.name, options)
    }
    var options = options ?? MergeOptions()
    // A squash merge's message lists the commits, never the branch. Without
    // the title, git's message names the full ref.
    if !options.squash {
        options.message = try? await mergeTitle(repository, branch)
    }
    return try await merge(repository, branch.ref, options)
}

/// Whether `name`, read as a revision, names `ref` and no other ref: `git
/// rev-parse --symbolic-full-name` prints the one full ref it finds, and
/// nothing for a name that two refs have.
func nameResolvesOnlyToRef(_ repository: Repository, _ name: String, _ ref: String) async throws -> Bool {
    let result = try await git(
        ["rev-parse", "--verify", "--quiet", "--symbolic-full-name", "--end-of-options", name],
        repository.path,
        "nameResolvesOnlyToRef",
        options: GitExecutionOptions(successExitCodes: [0, 1, 128])
    )
    return result.exitCode == 0 && JSCompat.strictEquals(JSCompat.trim(result.stdout), ref)
}

/// The message `git merge` makes for merging `branch` by its short name
/// ("Merge branch 'feature'", "Merge remote-tracking branch
/// 'origin/feature' into topic"), without the commits' summaries that
/// `merge.log` adds: `git fmt-merge-msg` given the line `git merge` writes
/// for the branch. Nil when the branch is gone or git makes no message (the
/// branch is merged already).
func mergeTitle(_ repository: Repository, _ branch: Branch) async throws -> String? {
    let tip = try await git(
        ["rev-parse", "--verify", "--quiet", "--end-of-options", branch.ref],
        repository.path,
        "mergeTitleTip",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )
    let sha = JSCompat.trim(tip.stdout)
    guard tip.exitCode == 0, !sha.isEmpty else {
        return nil
    }
    let kind = branch.type == .remote ? "remote-tracking branch" : "branch"
    let result = try await git(
        ["fmt-merge-msg", "--no-log"],
        repository.path,
        "mergeTitle",
        options: GitExecutionOptions(stdin: "\(sha)\t\t\(kind) '\(branch.name)' of .\n")
    )
    let title = JSCompat.trim(result.stdout)
    return title.isEmpty ? nil : title
}

private let noopMergeMessage = "Already up to date.\n"

/// What `git merge --squash` prints instead.
private let noopSquashMergeMessage = "Already up to date. (nothing to squash)\n"

/// Find the base commit between two commit-ish identifiers
///
/// Returns the commit id of the merge base, or nil if the two commit-ish
/// identifiers do not have a common base
public func getMergeBase(
    _ repository: Repository,
    _ firstCommitish: String,
    _ secondCommitish: String
) async throws -> String? {
    let process = try await git(
        ["merge-base", "--", firstCommitish, secondCommitish],
        repository.path,
        "merge-base",
        options: GitExecutionOptions(
            // - 1 is returned if a common ancestor cannot be resolved
            // - 128 is returned if a ref cannot be found
            //   "warning: ignoring broken ref refs/remotes/origin/main."
            successExitCodes: [0, 1, 128]
        )
    )

    if process.exitCode == 1 || process.exitCode == 128 {
        return nil
    }

    return JSCompat.trim(process.stdout)
}

/// Abort a mid-flight (conflicted) merge
///
/// - Parameter repository: where to abort the merge
public func abortMerge(_ repository: Repository) async throws {
    try await git(["merge", "--abort"], repository.path, "abortMerge")
}

/// Check the `.git/MERGE_HEAD` file exists in a repository to confirm
/// that it is in a conflicted state.
public func isMergeHeadSet(_ repository: Repository) async -> Bool {
    let path = POSIXPath.join(repository.resolvedGitDir, "MERGE_HEAD")
    return await pathExists(path)
}

/// Check the `.git/SQUASH_MSG` file exists in a repository
/// This would indicate we did a merge --squash and have not committed.. indicating
/// we have detected a conflict.
///
/// Note: If we abort the merge, this doesn't get cleared automatically which
/// could lead to this being erroneously available in a non merge --squashing scenario.
public func isSquashMsgSet(_ repository: Repository) async -> Bool {
    let path = POSIXPath.join(repository.resolvedGitDir, "SQUASH_MSG")
    return await pathExists(path)
}
