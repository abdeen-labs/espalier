// Ported from desktop/app/src/lib/git/init.ts

/// Init a new git repository in the given path.
public func initGitRepository(_ path: String) async throws {
    let defaultBranch = try await getDefaultBranch()
    try await git(
        ["-c", "init.defaultBranch=\(defaultBranch)", "init"],
        path,
        "initGitRepository"
    )
}
