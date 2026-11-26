// The commits a worktree has to push, by subject, for a piece of work's
// peek: one local `git log` when a status finds the worktree ahead of its
// upstream, run again only when its tip or its upstream's tip moved.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "worktree-activity")

/// A few of the commits a worktree's branch has that its upstream doesn't,
/// and what they were read for.
public struct UnpushedCommits: Sendable, Equatable, Codable {
    /// How many subjects are kept.
    public static let limit = 3

    /// Their subjects, the newest first: at most `limit`. How many there are
    /// in all is the worktree's ahead count.
    public let subjects: [String]
    /// The commit the branch was at.
    let tip: String
    /// The upstream, as the status named it (`origin/feature`).
    let upstream: String
    /// The commit the upstream was at, when its ref could be read.
    let upstreamTip: String?
    /// How far ahead and behind the branch was.
    let aheadBehind: AheadBehind
}

extension WorktreeActivityModel {
    /// A status of the worktree at `path` of repository `id` loaded: while
    /// its branch is ahead of an upstream, the subjects of the commits to
    /// push are read (`git log`, local), unless they were read for the same
    /// tip and the same upstream tip; otherwise there are none. The ref of
    /// the upstream is read from the git directory's files; no other git
    /// runs. A repository that isn't in the list records nothing.
    ///
    /// - Parameter gitDirectory: The worktree's git directory, where the
    ///   upstream's tip is read; nil when it isn't known (then the ahead and
    ///   behind counts stand in for it).
    public func recordStatusForUnpushedCommits(
        _ status: StatusResult,
        forWorktreeAt path: String,
        gitDirectory: String?,
        of id: RepositoryID
    ) async {
        guard isListed(id) else {
            return
        }
        let key = WorktreeKey(repositoryID: id, path: path)
        guard let aheadBehind = status.branchAheadBehind, aheadBehind.ahead > 0,
              let upstream = status.currentUpstreamBranch, !upstream.isEmpty,
              let tip = status.currentTip, !tip.isEmpty
        else {
            setUnpushedCommits(nil, for: key)
            return
        }
        let upstreamTip = await readUpstreamTip(upstream, gitDirectory: gitDirectory)
        if let known = unpushedCommits[key], JSCompat.strictEquals(known.tip, tip), JSCompat.strictEquals(known.upstream, upstream),
           known.upstreamTip == upstreamTip, known.aheadBehind == aheadBehind {
            return
        }
        let request = beginUnpushedCommitsRequest(for: key)
        let subjects = await environment.withRuntimes { await readSubjects(from: upstreamTip ?? upstream, to: tip, in: path) }
        guard isCurrentUnpushedCommitsRequest(request, for: key), isListed(id) else {
            return
        }
        setUnpushedCommits(
            subjects.map { UnpushedCommits(subjects: $0, tip: tip, upstream: upstream, upstreamTip: upstreamTip, aheadBehind: aheadBehind) },
            for: key
        )
    }
}

/// The subjects of the commits in `tip` that aren't in `base`, the newest
/// first, at most `UnpushedCommits.limit`; nil when git couldn't say.
@concurrent
private func readSubjects(from base: String, to tip: String, in path: String) async -> [String]? {
    do {
        let result = try await git(
            ["log", "--no-color", "--format=%s", "-n", String(UnpushedCommits.limit), "\(base)..\(tip)", "--"],
            path,
            "readUnpushedCommitSubjects"
        )
        let stdout = result.stdout
        return stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    } catch {
        logger.debug("Could not read the commits to push: \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

/// The commit `upstream` (`origin/feature`, or a local branch's name) is
/// at, read from the ref's file or `packed-refs` in the common directory of
/// `gitDirectory`; nil when it can't be read.
@concurrent
private func readUpstreamTip(_ upstream: String, gitDirectory: String?) async -> String? {
    guard let gitDirectory else {
        return nil
    }
    var common = gitDirectory
    if let pointer = readTrimmed(POSIXPath.join(gitDirectory, "commondir")), !pointer.isEmpty {
        common = JSCompat.startsWith(pointer, "/") ? pointer : POSIXPath.join(gitDirectory, pointer)
    }
    let refs = ["refs/remotes/" + upstream, "refs/heads/" + upstream]
    for ref in refs {
        if let sha = readTrimmed(POSIXPath.join(common, ref)), isObjectID(sha) {
            return sha
        }
    }
    guard let packed = readTrimmed(POSIXPath.join(common, "packed-refs")) else {
        return nil
    }
    for line in packed.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("^") {
        let parts = line.split(separator: " ", maxSplits: 1)
        if parts.count == 2, refs.contains(where: { JSCompat.strictEquals($0, String(parts[1])) }), isObjectID(String(parts[0])) {
            return String(parts[0])
        }
    }
    return nil
}

private func readTrimmed(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else {
        return nil
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Whether `text` is a full object ID (SHA-1 or SHA-256), in hexadecimal.
private func isObjectID(_ text: String) -> Bool {
    (text.utf8.count == 40 || text.utf8.count == 64) && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
