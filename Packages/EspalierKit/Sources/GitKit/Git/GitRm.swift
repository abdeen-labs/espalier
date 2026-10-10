// Ported from desktop/app/src/lib/git/rm.ts

/// Remove all files from the index
///
/// - Parameter repository: the repository to update
public func unstageAllFiles(_ repository: Repository) async throws {
    try await git(
        // these flags are important:
        // --cached to only remove files from the index
        // -r       to recursively remove files, in case files are in folders
        // -f       to ignore differences between working directory and index
        //          which will block this
        ["rm", "--cached", "-r", "-f", "."],
        repository.path,
        "unstageAllFiles"
    )
}

/// Remove conflicted file from  working tree and index
///
/// The path is a literal pathspec, so removing `a*.txt` doesn't also delete
/// ab.txt.
public func removeConflictedFile(_ repository: Repository, _ file: WorkingDirectoryFileChange) async throws {
    try await git(["rm", "--", literalPathspec(file.path)], repository.path, "removeConflictedFile")
}
