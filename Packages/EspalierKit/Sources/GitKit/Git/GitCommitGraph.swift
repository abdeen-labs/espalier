import EspalierSupport
import Foundation

/// Whether the repository's object database has a commit-graph: a single
/// `objects/info/commit-graph`, or a split chain
/// (`objects/info/commit-graphs/commit-graph-chain`). A linked worktree
/// shares its main repository's objects, and `git rev-parse --git-path`
/// finds them.
public func hasCommitGraph(_ repository: Repository) async throws -> Bool {
    let result = try await git(["rev-parse", "--git-path", "objects/info"], repository.path, "hasCommitGraph")
    let info = POSIXPath.resolve(repository.path, JSCompat.trim(result.stdout))
    if await pathExists(POSIXPath.join(info, "commit-graph")) {
        return true
    }
    return await pathExists(POSIXPath.join(info, "commit-graphs", "commit-graph-chain"))
}

/// Writes a commit-graph of every reachable commit as an incremental chain
/// (`git commit-graph write --reachable --split`), as `git maintenance`'s
/// commit-graph task does. Walks in topological order, merge bases, and
/// ahead/behind counts use it; commits added later are walked as before.
public func writeCommitGraph(_ repository: Repository) async throws {
    try await git(
        ["commit-graph", "write", "--reachable", "--split", "--no-progress"],
        repository.path,
        "writeCommitGraph"
    )
}
