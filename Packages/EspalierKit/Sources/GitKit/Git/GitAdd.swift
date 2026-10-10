// Ported from desktop/app/src/lib/git/add.ts

/// Add a conflicted file to the index.
///
/// Typically done after having resolved conflicts either manually
/// or through checkout --theirs/--ours.
///
/// The path is a literal pathspec.
public func addConflictedFile(_ repository: Repository, _ file: WorkingDirectoryFileChange) async throws {
    try await git(["add", "--", literalPathspec(file.path)], repository.path, "addConflictedFile")
}
