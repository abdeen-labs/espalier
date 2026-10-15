// Local remotes for push, pull, and fetch tests. Nothing touches the
// network.

import EspalierSupport
import Foundation
import GitKit
import TestSupport

/// A bare clone of `repository` (`git clone --bare`), to push to and fetch
/// from.
public func makeBareRemote(from repository: Repository) async throws -> Repository {
    let path = try createTempDirectory(prefix: "espalier-remote-")
    let result = try await Dugite.exec(["clone", "--bare", "--", repository.path, path], path)
    guard result.exitCode == 0 else {
        throw TestSupportError("Could not make a bare remote: \(String(decoding: result.stderr, as: UTF8.self))")
    }
    return Repository(path: path)
}

/// An empty bare repository, to add as a remote and push to.
public func makeEmptyBareRemote() async throws -> Repository {
    let remote = Repository(path: try createTempDirectory(prefix: "espalier-remote-"))
    _ = try await runGit(["init", "-q", "--bare"], remote)
    return remote
}

/// A bare remote with one commit on `branch`, and a clone of it that tracks
/// `origin/<branch>`.
public func setupRepositoryWithRemote(branch: String = "main") async throws -> (local: Repository, remote: Repository) {
    let seed = Repository(path: try createTempDirectory())
    try await runGit(["init", "-b", branch], seed)
    try Data("# README\n".utf8).write(to: URL(filePath: POSIXPath.join(seed.path, "README.md")))
    try await runGit(["add", "README.md"], seed)
    try await runGit(["commit", "-m", "Initial commit"], seed)
    let remote = try await makeBareRemote(from: seed)
    let local = try await cloneRepository(remote)
    return (local, remote)
}

/// Commits `contents` to `path` in another clone of `remote` and pushes it,
/// so other clones are behind.
@discardableResult
public func pushCommitFromAnotherClone(
    _ remote: Repository,
    path: String,
    contents: String,
    message: String = "Commit from another clone"
) async throws -> String {
    let other = try await cloneRepository(remote)
    try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(other.path, path)))
    try await runGit(["add", "--", path], other)
    try await runGit(["commit", "-m", message], other)
    try await runGit(["push", "origin", "HEAD"], other)
    let sha = try await runGit(["rev-parse", "HEAD"], other)
    return JSCompat.trim(sha)
}

/// Runs git through dugite and requires success; returns its output.
@discardableResult
public func runGit(_ args: [String], _ repository: Repository) async throws -> String {
    let result = try await Dugite.exec(args, repository.path)
    guard result.exitCode == 0 else {
        throw TestSupportError("git \(args.joined(separator: " ")) failed (\(result.exitCode)): \(String(decoding: result.stderr, as: UTF8.self))")
    }
    return String(decoding: result.stdout, as: UTF8.self)
}
