// Ported from desktop/app/src/lib/git/merge-tree.ts

import Foundation

/// Whether merging `theirs` into `ours` would be clean, would conflict (and
/// in how many files), or can't be done because the branches share no
/// history. Nothing in the repository changes.
///
/// Throws a `GitError` when git can't merge the two at all (for example, a
/// tip that isn't a commit in the repository). git exits with 1 then too, as
/// for conflicts, but writes no tree, which would count as -1 conflicted
/// files.
public func determineMergeability(
    _ repository: Repository,
    _ ours: Branch,
    _ theirs: Branch
) async throws -> MergeTreeResult {
    let args = [
        "merge-tree",
        "--write-tree",
        "--name-only",
        "--no-messages",
        "-z",
        ours.tip.sha,
        theirs.tip.sha,
    ]

    let result: GitResult
    do {
        result = try await git(
            args,
            repository.path,
            "determineMergeability",
            options: GitExecutionOptions(successExitCodes: [0, 1])
        )
    } catch where isGitError(error, .cannotMergeUnrelatedHistories) {
        return .invalid
    }

    // The output will be "<tree-id>\0[<filename>\0]*" so we can get the
    // number of conflicted files by counting the number of null bytes and
    // subtracting one for the tree id.
    let nullBytes = result.stdoutData.reduce(0) { count, byte in byte == 0 ? count + 1 : count }

    if nullBytes == 0 {
        throw GitError(result: result, args: args, terminalOutput: result.stderr)
    }

    let conflictedFiles = nullBytes - 1
    return conflictedFiles > 0 ? .conflicts(conflictedFiles: conflictedFiles) : .clean
}
