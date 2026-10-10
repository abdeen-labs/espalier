// Ported from desktop/app/test/helpers/git.ts

import GitKit

/// Get the tip commit of the current repository
///
/// Throws an error if the repository is unborn, to indicate an invalid state.
public func getTipOrError(_ repository: Repository) async throws -> Commit {
    guard let commit = try await getCommit(repository, "HEAD") else {
        throw TestSupportError(
            "Unable to find commit for HEAD - check that you are not working with an unborn repository"
        )
    }

    return commit
}

/// Get the commit associated with a provided ref (could also be a commit ID or a branch name).
///
/// Throws an error if the commit cannot be found in the repository.
public func getRefOrError(_ repository: Repository, _ ref: String) async throws -> Commit {
    guard let commit = try await getCommit(repository, ref) else {
        throw TestSupportError(
            "Unable to find commit for \(ref) - check that this exists in the repository"
        )
    }

    return commit
}

/// Get the branch object associated with a local branch name.
///
/// Throws an error if it cannot find the expected `refs/heads/{name}` ref in the
/// repository.
public func getBranchOrError(_ repository: Repository, _ name: String) async throws -> Branch {
    let ref = "refs/heads/\(name)"
    let branches = try await getBranches(repository, ref)

    guard let branch = branches.first else {
        throw TestSupportError(
            "Unable to find branch matching \(ref) - check that this exists in the repository"
        )
    }

    return branch
}
