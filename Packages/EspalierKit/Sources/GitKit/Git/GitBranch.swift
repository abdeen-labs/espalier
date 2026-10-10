// Ported from desktop/app/src/lib/git/branch.ts

import EspalierSupport
import Foundation

/// Create a new branch from the given start point.
///
/// - Parameters:
///   - repository: The repository in which to create the new branch
///   - name: The name of the new branch
///   - startPoint: A committish string that the new branch should be based
///     on, or nil if the branch should be created based
///     off of the current state of HEAD
///   - noTrack: Pass `--no-track`, for a branch created directly from a
///     remote branch.
public func createBranch(
    _ repository: Repository,
    _ name: String,
    _ startPoint: String?,
    noTrack: Bool = false
) async throws {
    var args = ["branch"]

    // if we're branching directly from a remote branch, we don't want to track it
    // tracking it will make the rest of Espalier think we want to push to that
    // remote branch's upstream (which would likely be the upstream of the fork)
    if noTrack {
        args.append("--no-track")
    }

    args += ["--", name]
    if let startPoint {
        args.append(startPoint)
    }

    try await git(args, repository.path, "createBranch")
}

private enum BranchNameField: Hashable, Sendable {
    case name
}

/// The short names of the repository's local branches.
public func getBranchNames(_ repository: Repository) async throws -> [String] {
    let parser = createForEachRefParser([BranchNameField.name: "%(refname:short)"])
    let result = try await git(["branch"] + parser.formatArgs, repository.path, "getBranchNames")
    return try parser.parse(result.stdout).map { $0[.name] }
}

/// `/fatal: a branch named '(.+?)' already exists/`
private let branchAlreadyExistsPattern = JSCompat.regex("fatal: a branch named '(\(JSCompat.dot)+?)' already exists")

/// Rename the given branch to a new name.
///
/// - Parameter force: Pass `-M` instead of `-m`. When nil and the rename
///   fails because a branch whose name differs only in case exists, which
///   is how a case-only rename fails on a case-insensitive file system, the
///   rename is retried with `-M` unless a branch with exactly the new name
///   exists.
public func renameBranch(
    _ repository: Repository,
    _ branch: Branch,
    _ newName: String,
    force: Bool? = nil
) async throws {
    do {
        try await git(
            ["branch", force == true ? "-M" : "-m", branch.nameWithoutRemote, newName],
            repository.path,
            "renameBranch"
        )
    } catch let renameError as GitError {
        // If we failed to rename and the branch name only differs by case,
        // we'll try again with the -M flag to force the rename.
        //
        // Only retry if the caller hasn't explicitly asked us to force the rename
        guard force == nil, renameError.result.gitError == .branchAlreadyExists else {
            throw renameError
        }

        let stderr = renameError.result.stderr
        guard let m = JSCompat.match(stderr, branchAlreadyExistsPattern),
              let existing = m[1],
              JSCompat.strictEquals(existing.lowercased(), newName.lowercased())
        else {
            throw renameError
        }

        // At this point we're almost certain that we are dealing with a
        // case-only rename on a case insensitive filesystem, but we can't
        // be 100% sure, macOS might have case sensitive file systems mounted
        // so we have to list all branches and check the names.
        let names: [String]
        do {
            names = try await getBranchNames(repository)
        } catch {
            // Throw the original error if we fail to get the branch names
            throw renameError
        }

        // If we find the new name in the list of branches we can't
        // safely assume it's a case-only rename and have to
        // propagate the original error, otherwise try again with -M
        if names.contains(where: { JSCompat.strictEquals($0, newName) }) {
            throw renameError
        }

        try await renameBranch(repository, branch, newName, force: true)
    }
}

/// Delete the branch locally.
@discardableResult
public func deleteLocalBranch(_ repository: Repository, _ branchName: String) async throws -> Bool {
    try await git(["branch", "-D", branchName], repository.path, "deleteLocalBranch")
    return true
}

/// Deletes a remote branch
///
/// - Parameters:
///   - remote: The remote to delete the branch from
///   - remoteBranchName: The name of the branch on the remote
@discardableResult
public func deleteRemoteBranch(
    _ repository: Repository,
    _ remote: Remote,
    _ remoteBranchName: String
) async throws -> Bool {
    let args = ["push", "--", remote.name, ":\(remoteBranchName)"]

    // If the user is not authenticated, the push is going to fail
    // Let this propagate and leave it to the caller to handle
    let result = try await git(
        args,
        repository.path,
        "deleteRemoteBranch",
        options: GitExecutionOptions(
            env: await envForRemoteOperation(remote.url),
            expectedErrors: [.branchDeletionFailed]
        )
    )

    // It's possible that the delete failed because the ref has already
    // been deleted on the remote. If we identify that specific
    // error we can safely remove our remote ref which is what would
    // happen if the push didn't fail.
    if result.gitError == .branchDeletionFailed {
        let ref = "refs/remotes/\(remote.name)/\(remoteBranchName)"
        try await deleteRef(repository, ref)
    }

    return true
}

/// Finds branches that have a tip equal to the given committish
///
/// - Parameters:
///   - repository: within which to execute the command
///   - commitish: a sha, HEAD, etc that the branch(es) tip should be
/// - Returns: list branch names. nil if an error is encountered
public func getBranchesPointedAt(_ repository: Repository, _ commitish: String) async throws -> [String]? {
    let args = [
        "branch",
        "--points-at=\(commitish)",
        "--format=%(refname:short)",
    ]
    // this command has an implicit \n delimiter
    let result = try await git(
        args,
        repository.path,
        "branchPointedAt",
        options: GitExecutionOptions(
            // - 1 is returned if a common ancestor cannot be resolved
            // - 129 is returned if ref is malformed
            //   "warning: ignoring broken ref refs/remotes/origin/main."
            successExitCodes: [0, 1, 129]
        )
    )
    if result.exitCode == 1 || result.exitCode == 129 {
        return nil
    }
    // split (and remove trailing element cause its always an empty string)
    return Array(JSCompat.split(result.stdout, "\n").dropLast())
}

private enum MergedBranchField: Hashable, Sendable {
    case sha, canonicalRef
}

/// Gets all branches that have been merged into the given branch
///
/// - Parameters:
///   - repository: The repository in which to search
///   - branchName: The to be used as the base branch
/// - Returns: map of branch canonical refs paired to its sha
public func getMergedBranches(_ repository: Repository, _ branchName: String) async throws -> [String: String] {
    let canonicalBranchRef = formatAsLocalRef(branchName)
    let parser = createForEachRefParser([
        MergedBranchField.sha: "%(objectname)",
        .canonicalRef: "%(refname)",
    ])

    let args = ["branch"] + parser.formatArgs + ["--merged", branchName]
    var mergedBranches: [String: String] = [:]
    let result = try await git(args, repository.path, "mergedBranches")

    for branch in try parser.parse(result.stdout) {
        // Don't include the branch we're using to compare against
        // in the list of branches merged into that branch.
        if !JSCompat.strictEquals(branch[.canonicalRef], canonicalBranchRef) {
            mergedBranches[branch[.canonicalRef]] = branch[.sha]
        }
    }

    return mergedBranches
}
