// Ported from desktop/app/src/lib/git/for-each-ref.ts

import EspalierSupport
import Foundation

private enum BranchField: Hashable, Sendable {
    case fullName, shortName, upstreamShortName, sha, symRef
}

/// Get all the branches.
///
/// - Parameter prefixes: The ref prefixes to list; `refs/heads` and
///   `refs/remotes` when none are given.
public func getBranches(_ repository: Repository, _ prefixes: String...) async throws -> [Branch] {
    try await getBranches(repository, prefixes: prefixes)
}

/// Get all the branches under `prefixes` (`refs/heads` and `refs/remotes`
/// when empty). The array form of `getBranches(_:_:)`.
public func getBranches(_ repository: Repository, prefixes: [String]) async throws -> [Branch] {
    let parser = createForEachRefParser([
        BranchField.fullName: "%(refname)",
        .shortName: "%(refname:short)",
        .upstreamShortName: "%(upstream:short)",
        .sha: "%(objectname)",
        .symRef: "%(symref)",
    ])

    let prefixes = prefixes.isEmpty ? ["refs/heads", "refs/remotes"] : prefixes

    let result = try await git(
        ["for-each-ref"] + parser.formatArgs + prefixes,
        repository.path,
        "getBranches",
        options: GitExecutionOptions(expectedErrors: [.notAGitRepository])
    )

    if result.gitError == .notAGitRepository {
        return []
    }

    var branches: [Branch] = []

    for ref in try parser.parse(result.stdout) {
        // excude symbolic refs from the branch list
        if !ref[.symRef].isEmpty {
            continue
        }

        let tip = BranchTip(sha: ref[.sha])

        let type: BranchType = JSCompat.startsWith(ref[.fullName], "refs/heads") ? .local : .remote

        let upstream = ref[.upstreamShortName].isEmpty ? nil : ref[.upstreamShortName]

        branches.append(Branch(name: ref[.shortName], upstream: upstream, tip: tip, type: type, ref: ref[.fullName]))
    }

    return branches
}

private enum TrackingField: Hashable, Sendable {
    case fullName, sha, upstream, symref, head
}

/// Gets all branches that differ from their upstream (i.e. they're ahead,
/// behind or both), excluding the current branch.
/// Useful to narrow down a list of branches that could potentially be fast
/// forwarded.
///
/// - Parameter repository: Repository to get the branches from.
public func getBranchesDifferingFromUpstream(_ repository: Repository) async throws -> [TrackingBranch] {
    let parser = createForEachRefParser([
        TrackingField.fullName: "%(refname)",
        .sha: "%(objectname)", // SHA
        .upstream: "%(upstream)",
        .symref: "%(symref)",
        .head: "%(HEAD)",
    ])

    let prefixes = ["refs/heads", "refs/remotes"]

    let result = try await git(
        ["for-each-ref"] + parser.formatArgs + prefixes,
        repository.path,
        "getBranchesDifferingFromUpstream",
        options: GitExecutionOptions(expectedErrors: [.notAGitRepository])
    )

    if result.gitError == .notAGitRepository {
        return []
    }

    var localBranches: [(ref: String, sha: String, upstream: String)] = []
    var remoteBranchShas: [String: String] = [:]

    // First we need to collect the relevant info from the command output:
    // - For local branches with upstream: name, ref, SHA and the upstream.
    // - For remote branches we only need the sha (and the ref as key).
    for ref in try parser.parse(result.stdout) {
        if !ref[.symref].isEmpty || ref[.head] == "*" {
            // Exclude symbolic refs and the current branch
            continue
        }

        if JSCompat.startsWith(ref[.fullName], "refs/heads") {
            if ref[.upstream].isEmpty {
                // Exclude local branches without upstream
                continue
            }

            localBranches.append((ref: ref[.fullName], sha: ref[.sha], upstream: ref[.upstream]))
        } else {
            remoteBranchShas[ref[.fullName]] = ref[.sha]
        }
    }

    var eligibleBranches: [TrackingBranch] = []

    // Compare the SHA of every local branch with the SHA of its upstream and
    // collect the names of local branches that differ from their upstream.
    for branch in localBranches {
        if let remoteSha = remoteBranchShas[branch.upstream], !JSCompat.strictEquals(remoteSha, branch.sha) {
            eligibleBranches.append(TrackingBranch(
                ref: branch.ref,
                sha: branch.sha,
                upstreamRef: branch.upstream,
                upstreamSha: remoteSha
            ))
        }
    }

    return eligibleBranches
}
