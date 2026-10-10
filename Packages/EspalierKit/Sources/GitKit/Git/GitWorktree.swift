// Ported from desktop/app/src/lib/git/worktree.ts

import EspalierSupport
import Foundation

/// Parses the output of `git worktree list --porcelain -z`.
public func parseWorktreePorcelainOutput(_ stdout: String) -> [WorktreeEntry] {
    if JSCompat.trim(stdout).isEmpty {
        return []
    }

    // With -z, worktree blocks are separated by double NUL and fields within
    // a block are separated by single NUL
    let withoutTerminator = JSCompat.endsWith(stdout, "\0")
        ? String(decoding: stdout.utf8.dropLast(), as: UTF8.self)
        : stdout
    let blocks = JSCompat.split(withoutTerminator, "\0\0")
    var entries: [WorktreeEntry] = []

    for (i, block) in blocks.enumerated() {
        let lines = JSCompat.split(block, "\0")
        var path = ""
        var head = ""
        var branch: String?
        var isDetached = false
        var isLocked = false
        var isPrunable = false

        for line in lines {
            if JSCompat.startsWith(line, "worktree ") {
                // Repositories added in Espalier always pass through
                // getRepositoryType which uses POSIXPath.resolve to deduce the
                // absolute top level directory and that will normalize paths as well
                // so by normalizing here we can be more confident about comparing paths
                path = POSIXPath.normalize(JSCompat.dropFirst(line, "worktree ".count))
            } else if JSCompat.startsWith(line, "HEAD ") {
                head = JSCompat.dropFirst(line, "HEAD ".count)
            } else if JSCompat.startsWith(line, "branch ") {
                branch = JSCompat.dropFirst(line, "branch ".count)
            } else if JSCompat.strictEquals(line, "detached") {
                isDetached = true
            } else if JSCompat.strictEquals(line, "locked") || JSCompat.startsWith(line, "locked ") {
                isLocked = true
            } else if JSCompat.strictEquals(line, "prunable") || JSCompat.startsWith(line, "prunable ") {
                isPrunable = true
            }
        }

        let type: WorktreeType = i == 0 ? .main : .linked
        entries.append(WorktreeEntry(
            path: path,
            head: head,
            branch: branch,
            isDetached: isDetached,
            type: type,
            isLocked: isLocked,
            isPrunable: isPrunable
        ))
    }

    return entries
}

/// Lists the worktrees of the repository at `repositoryPath`.
public func listWorktrees(_ repositoryPath: String) async throws -> [WorktreeEntry] {
    let result = try await git(
        ["worktree", "list", "--porcelain", "-z"],
        repositoryPath,
        "listWorktrees"
    )

    return parseWorktreePorcelainOutput(result.stdout)
}

/// Lists the worktrees of the repository.
public func listWorktrees(_ repository: Repository) async throws -> [WorktreeEntry] {
    try await listWorktrees(repository.path)
}

/// Lists the worktrees of the repository whose git directory is `gitDir`.
/// This works even when the worktree that `gitDir` belongs to is gone.
public func listWorktreesFromGitDir(_ gitDir: String) async throws -> [WorktreeEntry] {
    let result = try await git(
        ["--git-dir", gitDir, "worktree", "list", "--porcelain", "-z"],
        gitDir,
        "listWorktreesFromGitDir"
    )

    return parseWorktreePorcelainOutput(result.stdout)
}

/// Resolve the path to the main worktree of the repository the given repository
/// belongs to, or nil if it is already the main worktree or cannot be resolved.
///
/// Prefers the path recorded when Espalier switched onto the worktree, falling
/// back to the worktree's administrative git dir when no path was recorded.
/// The fallback only works while that metadata exists — `git worktree remove`
/// and `git worktree prune` both delete it.
///
/// - Parameters:
///   - repository: The repository, with its git directory if known.
///   - mainWorktreePath: The main worktree path recorded for the repository.
public func resolveMainWorktreePath(_ repository: Repository, mainWorktreePath: String?) async throws -> String? {
    let path = repository.path

    if let mainWorktreePath, JSCompat.strictEquals(mainWorktreePath, path) {
        return nil
    }

    // A recorded path can outlive the location it names, so treat it as a hint
    // rather than the answer — otherwise a stale one would suppress the lookup
    // below, which may well still work.
    if let mainWorktreePath, await pathExists(mainWorktreePath) {
        return mainWorktreePath
    }

    guard let gitDir = repository.gitDir else {
        return nil
    }

    let mainWorktree = try await listWorktreesFromGitDir(gitDir).first { $0.type == .main }

    guard let mainWorktree, !JSCompat.strictEquals(mainWorktree.path, path) else {
        return nil
    }
    return mainWorktree.path
}

/// Options for `addWorktree`.
public struct AddWorktreeOptions: Hashable, Sendable {
    /// Branch name used with -b (create new branch)
    public var createBranch: String?

    /// Commit-ish to check out (branch name, ref, or SHA)
    public var commitish: String?

    public init(createBranch: String? = nil, commitish: String? = nil) {
        self.createBranch = createBranch
        self.commitish = commitish
    }
}

/// Adds a linked worktree at `path`.
public func addWorktree(
    _ repository: Repository,
    _ path: String,
    _ options: AddWorktreeOptions = AddWorktreeOptions()
) async throws {
    var args = ["worktree", "add"]

    if let createBranch = options.createBranch, !createBranch.isEmpty {
        args += ["-b", createBranch]
    }

    args += ["--", path]

    if let commitish = options.commitish, !commitish.isEmpty {
        args.append(commitish)
    }

    try await git(args, repository.path, "addWorktree")
}

/// Removes the linked worktree at `worktreePath`.
public func removeWorktree(_ repositoryPath: String, _ worktreePath: String, _ force: Bool = false) async throws {
    var args = ["worktree", "remove"]
    if force {
        args.append("--force")
    }
    args.append(worktreePath)

    try await git(args, repositoryPath, "removeWorktree")
}

/// Moves the linked worktree at `oldPath` to `newPath`.
public func moveWorktree(_ repository: Repository, _ oldPath: String, _ newPath: String) async throws {
    try await git(
        ["worktree", "move", oldPath, newPath],
        repository.path,
        "moveWorktree"
    )
}
