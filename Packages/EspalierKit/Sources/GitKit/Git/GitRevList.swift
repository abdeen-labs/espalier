// Ported from desktop/app/src/lib/git/rev-list.ts

import EspalierSupport
import Foundation

/// Convert two refs into the Git range syntax representing the set of commits
/// that are reachable from `to` but excluding those that are reachable from
/// `from`. This will not be inclusive to the `from` ref, see
/// `revRangeInclusive`.
///
/// Each parameter can be the commit SHA or a ref name, or specify an empty
/// string to represent HEAD.
///
/// - Parameters:
///   - from: The start of the range
///   - to: The end of the range
public func revRange(_ from: String, _ to: String) -> String {
    "\(from)..\(to)"
}

/// Convert two refs into the Git range syntax representing the set of commits
/// that are reachable from `to` but excluding those that are reachable from
/// `from`. However as opposed to `revRange`, this will also include `from` ref.
///
/// Each parameter can be the commit SHA or a ref name, or specify an empty
/// string to represent HEAD.
///
/// - Parameters:
///   - from: The start of the range
///   - to: The end of the range
public func revRangeInclusive(_ from: String, _ to: String) -> String {
    "\(from)^..\(to)"
}

/// Convert two refs into the Git symmetric difference syntax, which represents
/// the set of commits that are reachable from either `from` or `to` but not
/// from both.
///
/// Each parameter can be the commit SHA or a ref name, or you can use an empty
/// string to represent HEAD.
///
/// - Parameters:
///   - from: The start of the range
///   - to: The end of the range
public func revSymmetricDifference(_ from: String, _ to: String) -> String {
    "\(from)...\(to)"
}

/// Calculate the number of commits the range is ahead and behind.
public func getAheadBehind(_ repository: Repository, _ range: String) async throws -> AheadBehind? {
    // `--left-right` annotates the list of commits in the range with which side
    // they're coming from. When used with `--count`, it tells us how many
    // commits we have from the two different sides of the range.
    let args = [
        "rev-list",
        "--left-right",
        "--count",
        "--end-of-options",
        range,
        "--",
    ]
    let result = try await git(args, repository.path, "getAheadBehind", options: GitExecutionOptions(
        expectedErrors: [.badRevision]
    ))

    // This means one of the refs (most likely the upstream branch) no longer
    // exists. In that case we can't be ahead/behind at all.
    if result.gitError == .badRevision {
        return nil
    }

    let stdout = result.stdout
    let pieces = JSCompat.split(stdout, "\t")
    if pieces.count != 2 {
        return nil
    }

    guard let ahead = JSCompat.parseInt(pieces[0]) else {
        return nil
    }

    guard let behind = JSCompat.parseInt(pieces[1]) else {
        return nil
    }

    return AheadBehind(ahead: ahead, behind: behind)
}

/// Calculate the number of commits `branch` is ahead/behind its upstream.
public func getBranchAheadBehind(_ repository: Repository, _ branch: Branch) async throws -> AheadBehind? {
    if branch.type == .remote {
        return nil
    }

    guard let upstream = branch.upstream, !upstream.isEmpty else {
        return nil
    }

    // NB: The three dot form means we'll go all the way back to the merge base
    // of the branch and its upstream. Practically this is important for seeing
    // "through" merges.
    let range = revSymmetricDifference(branch.name, upstream)
    return try await getAheadBehind(repository, range)
}

/// Get a list of commits from the target branch that do not exist on the base
/// branch, ordered how they will be applied to the base branch.
/// Therefore, this will not include the baseBranchSha commit.
///
/// This emulates how `git rebase` initially determines what will be applied to
/// the repository.
///
/// Returns `nil` when the rebase is not possible to perform, because of a
/// missing commit ID
public func getCommitsBetweenCommits(
    _ repository: Repository,
    _ baseBranchSha: String,
    _ targetBranchSha: String
) async throws -> [CommitOneLine]? {
    let range = revRange(baseBranchSha, targetBranchSha)

    return try await getCommitsInRange(repository, range)
}

/// `/^([a-z0-9]{40}) (.*)$/`
///
/// Also accepts 64-character object IDs, for SHA-256 repositories.
private let commitSummaryRe = JSCompat.regex("^([a-z0-9]{40}|[a-z0-9]{64}) (\(JSCompat.dot)*)\\z")

/// Get a list of commits inside the provided range.
///
/// Returns `nil` when it is not possible to perform because of a bad range.
public func getCommitsInRange(_ repository: Repository, _ range: String) async throws -> [CommitOneLine]? {
    let args = [
        "rev-list",
        "--reverse",
        // the combination of these two arguments means each line of the stdout
        // will contain the full commit sha and a commit summary
        "--oneline",
        "--no-abbrev-commit",
        "--end-of-options",
        range,
        "--",
    ]

    let options = GitExecutionOptions(expectedErrors: [.badRevision])

    let result = try await git(args, repository.path, "getCommitsInRange", options: options)

    if result.gitError == .badRevision {
        return nil
    }

    let lines = JSCompat.split(result.stdout, "\n")

    var commits: [CommitOneLine] = []

    for line in lines {
        if let match = JSCompat.match(line, commitSummaryRe), match.count == 3,
           let sha = match[1], let summary = match[2] {
            commits.append(CommitOneLine(sha: sha, summary: summary))
        }
    }

    return commits
}

/// Determine if merge commits exist in history after given commit
/// If commitRef is nil, goes back to HEAD of branch.
public func doMergeCommitsExistAfterCommit(_ repository: Repository, _ commitRef: String?) async throws -> Bool {
    let revision = commitRef.map { revRange($0, "HEAD") } ?? "HEAD"
    let args = [
        "rev-list",
        "-1",
        "--merges",
        "--end-of-options",
        revision,
        "--",
    ]

    let result = try await git(args, repository.path, "doMergeCommitsExistAfterCommit", options: GitExecutionOptions(
        // 128 here means there's no HEAD, i.e we're on an unborn branch
        successExitCodes: [0, 128]
    ))
    return !result.stdoutData.isEmpty
}
