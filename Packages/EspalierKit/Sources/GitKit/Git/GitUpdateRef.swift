// Ported from desktop/app/src/lib/git/update-ref.ts

/// Update the ref to a new value.
///
/// - Parameters:
///   - repository: The repository in which the ref exists.
///   - ref: The ref to update. Must be fully qualified
///     (e.g., `refs/heads/NAME`).
///   - oldValue: The value we expect the ref to have currently. If it
///     doesn't match, the update will be aborted.
///   - newValue: The new value for the ref.
///   - reason: The reflog entry.
public func updateRef(
    _ repository: Repository,
    _ ref: String,
    _ oldValue: String,
    _ newValue: String,
    _ reason: String
) async throws {
    try await git(
        ["update-ref", ref, newValue, oldValue, "-m", reason],
        repository.path,
        "updateRef"
    )
}

/// Deletes `ref` only while it points at `expectedValue`, in one step: git
/// compares and deletes it under the ref's lock (`git update-ref -d <ref>
/// <expectedValue>`), so a ref that moves in between is never deleted. A
/// symbolic ref is deleted itself, not the ref it points at (`--no-deref`),
/// as `git branch -D` deletes a branch. Its reflog goes with it.
///
/// - Parameters:
///   - repository: The repository in which the ref exists.
///   - ref: The ref to delete, fully qualified (`refs/heads/NAME`).
///   - expectedValue: The SHA the ref must still point at.
/// - Returns: Whether the ref was deleted: false when it points at another
///   commit, is gone, or is locked (git exits 1).
@discardableResult
public func deleteRef(_ repository: Repository, _ ref: String, ifAt expectedValue: String) async throws -> Bool {
    let result = try await git(
        ["update-ref", "--no-deref", "-d", ref, expectedValue],
        repository.path,
        "deleteRefIfAt",
        options: GitExecutionOptions(successExitCodes: [0, 1])
    )
    return result.exitCode == 0
}

/// Remove a ref.
///
/// - Parameters:
///   - repository: The repository in which the ref exists.
///   - ref: The ref to remove. Should be fully qualified, but may also be 'HEAD'.
///   - reason: The reflog entry (optional). Note that this is only useful when
///     deleting the HEAD reference as deleting any other reference will
///     implicitly delete the reflog file for that reference as well.
public func deleteRef(_ repository: Repository, _ ref: String, _ reason: String? = nil) async throws {
    var args = ["update-ref", "-d", ref]

    if let reason {
        args.append(contentsOf: ["-m", reason])
    }

    try await git(args, repository.path, "deleteRef")
}
