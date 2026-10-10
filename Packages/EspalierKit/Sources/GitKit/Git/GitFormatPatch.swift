// Ported from desktop/app/src/lib/git/format-patch.ts

/// Generate a patch representing the changes associated with a range of commits
///
/// The patch is decoded as UTF-8, so text that isn't valid UTF-8 doesn't
/// survive.
///
/// - Parameters:
///   - repository: where to generate path from
///   - base: starting commit in range
///   - head: ending commit in rage
/// - Returns: patch generated
public func formatPatch(_ repository: Repository, _ base: String, _ head: String) async throws -> String {
    let range = revRange(base, head)
    let args = ["format-patch", "--unified=1", "--minimal", "--stdout", range]
    return try await git(args, repository.path, "formatPatch").stdout
}
