// Ported from desktop/app/src/lib/git/reset.ts

/// The reset modes which are supported.
public enum GitResetMode: Int, Hashable, Sendable {
    /// Resets the index and working tree. Any changes to tracked files in the
    /// working tree since <commit> are discarded.
    case hard = 0

    /// Does not touch the index file or the working tree at all (but resets the
    /// head to <commit>, just like all modes do). This leaves all your changed
    /// files "Changes to be committed", as git status would put it.
    case soft

    /// Resets the index but not the working tree (i.e., the changed files are
    /// preserved but not marked for commit) and reports what has not been updated.
    /// This is the default action for git reset.
    case mixed
}

private func resetModeToArgs(_ mode: GitResetMode, _ ref: String) -> [String] {
    switch mode {
    case .hard:
        ["reset", "--hard", ref]
    case .mixed:
        ["reset", ref]
    case .soft:
        ["reset", "--soft", ref]
    }
}

/// Reset with the mode to the ref.
///
/// Returns `true`, so a caller can tell success apart from a failed
/// operation.
@discardableResult
public func reset(_ repository: Repository, _ mode: GitResetMode, _ ref: String) async throws -> Bool {
    let args = resetModeToArgs(mode, ref)
    try await git(args, repository.path, "reset")
    return true
}

/// Updates the index with information from a particular tree for a given
/// set of paths.
///
/// - Parameters:
///   - repository: The repository in which to reset the index.
///   - mode: Which mode to use when resetting, see the GitResetMode
///     enum for more information.
///   - ref: A string which resolves to a tree, for example 'HEAD' or a
///     commit sha.
///   - paths: The paths that should be updated in the index with information
///     from the given tree
public func resetPaths(
    _ repository: Repository,
    _ mode: GitResetMode,
    _ ref: String,
    _ paths: [String]
) async throws {
    if paths.isEmpty {
        return
    }

    let baseArgs = resetModeToArgs(mode, ref)

    // The paths are literal pathspecs, so resetting `a*.txt` doesn't also
    // unstage ab.txt.
    let args = baseArgs + ["--"] + literalPathspecs(paths)
    try await git(args, repository.path, "resetPaths")
}

/// Unstage all paths.
@discardableResult
public func unstageAll(_ repository: Repository) async throws -> Bool {
    try await git(["reset", "--", "."], repository.path, "unstageAll")
    return true
}
