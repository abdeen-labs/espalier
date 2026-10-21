// Ported from desktop/app/test/unit/git/push-test.ts

import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// Creates a bare clone of a repository to use as an upstream remote.
/// Bare repos accept pushes to any branch.
private func createBareUpstream(_ source: Repository) async throws -> String {
    let barePath = try createTempDirectory()
    _ = try await Dugite.exec(["clone", "--bare", source.path, barePath], source.path)
    return barePath
}

private func stdout(_ result: Dugite.Result) -> String {
    String(decoding: result.stdout, as: UTF8.self)
}

@Suite("git/push")
struct PushTests {
    @Test("pushes commits to a local remote")
    func pushes() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "README.md", contents: "initial")],
            commitMessage: "initial commit"
        ))

        // Create a bare upstream and add it as origin
        let barePath = try await createBareUpstream(repo)
        _ = try await Dugite.exec(["remote", "add", "origin", barePath], repo.path)

        // Create a new commit to push
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "new-file.txt", contents: "new content")],
            commitMessage: "add new file"
        ))

        let remote = Remote(name: "origin", url: barePath)
        try await push(repo, remote, "master", "master", nil)

        // Verify the bare upstream received the commit
        let result = try await Dugite.exec(["log", "--oneline"], barePath)
        #expect(stdout(result).contains("add new file"))
    }

    @Test("pushes with --set-upstream for a new branch")
    func setsUpstream() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "README.md", contents: "initial")],
            commitMessage: "initial commit"
        ))

        let barePath = try await createBareUpstream(repo)
        _ = try await Dugite.exec(["remote", "add", "origin", barePath], repo.path)

        // Create and switch to a new branch
        _ = try await Dugite.exec(["checkout", "-b", "new-branch"], repo.path)
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "branch-file.txt", contents: "branch content")],
            commitMessage: "branch commit"
        ))

        let remote = Remote(name: "origin", url: barePath)

        // Push with remoteBranch=nil should set upstream
        try await push(repo, remote, "new-branch", nil, nil)

        // Verify the branch exists on the bare upstream
        let result = try await Dugite.exec(["rev-parse", "--verify", "new-branch"], barePath)
        #expect(result.exitCode == 0)

        let upstream = try await Dugite.exec(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            repo.path
        )
        #expect(JSCompat.trim(stdout(upstream)) == "origin/new-branch")
    }

    @Test("pushes with force-with-lease")
    func forceWithLease() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "README.md", contents: "initial")],
            commitMessage: "initial commit"
        ))

        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "README.md", contents: "before rewrite")],
            commitMessage: "commit before rewrite"
        ))

        let barePath = try await createBareUpstream(repo)
        _ = try await Dugite.exec(["remote", "add", "origin", barePath], repo.path)

        let remote = Remote(name: "origin", url: barePath)
        try await push(repo, remote, "master", "master", nil)

        _ = try await Dugite.exec(["reset", "--hard", "HEAD~1"], repo.path)
        try Data("rewritten history".utf8).write(to: URL(filePath: "\(repo.path)/README.md"))
        _ = try await Dugite.exec(["add", "README.md"], repo.path)
        _ = try await Dugite.exec(["commit", "-m", "rewritten commit"], repo.path)

        let error = await #expect(throws: GitError.self) {
            try await push(repo, remote, "master", "master", nil)
        }
        #expect(error?.result.gitError == .pushNotFastForward)

        try await push(repo, remote, "master", "master", nil, PushOptions(forceWithLease: true))

        // Verify the bare upstream has the rewritten commit
        let result = try await Dugite.exec(["log", "--oneline", "-1"], barePath)
        #expect(stdout(result).contains("rewritten commit"))
    }

    @Test("reports progress when callback is provided")
    func reportsProgress() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "README.md", contents: "initial")],
            commitMessage: "initial commit"
        ))

        let barePath = try await createBareUpstream(repo)
        _ = try await Dugite.exec(["remote", "add", "origin", barePath], repo.path)

        try await makeCommit(repo, Tree(
            entries: [TreeEntry(path: "file.txt", contents: "content")],
            commitMessage: "new commit"
        ))

        let remote = Remote(name: "origin", url: barePath)
        let progressEvents = Mutex<[PushProgress]>([])

        try await push(repo, remote, "master", "master", nil, nil) { progress in
            progressEvents.withLock { $0.append(progress) }
        }

        // At minimum we should get the initial progress event
        let events = progressEvents.withLock { $0 }
        #expect(!events.isEmpty, "Expected at least one progress event")
        #expect(events.first?.value == 0)
        #expect(events.first?.remote == "origin")
        #expect(events.first?.branch == "master")
    }

    // MARK: - Espalier

    @Test("runs the pre-push hook unless told not to")
    func noVerify() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "README.md", contents: "initial")]))
        let barePath = try await createBareUpstream(repo)
        _ = try await Dugite.exec(["remote", "add", "origin", barePath], repo.path)
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "README.md", contents: "second")]))

        let hooks = POSIXPath.join(repo.path, ".git", "hooks")
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        let hook = POSIXPath.join(hooks, "pre-push")
        try Data("#!/bin/sh\necho 'rejected by hook' >&2\nexit 1\n".utf8).write(to: URL(filePath: hook))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)

        let remote = Remote(name: "origin", url: barePath)
        await #expect(throws: GitError.self) {
            try await push(repo, remote, "master", "master", nil)
        }

        try await push(repo, remote, "master", "master", nil, PushOptions(noVerify: true))
        let result = try await Dugite.exec(["rev-parse", "master"], barePath)
        #expect(JSCompat.trim(stdout(result)) == (try await getTipOrError(repo)).sha)
    }

    @Test("pushes to the remote's branch when a tag on the remote has its name")
    func destinationBesideRemoteTag() async throws {
        let repo = try setupEmptyRepository()
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "README.md", contents: "initial")]))
        let barePath = try await createBareUpstream(repo)
        _ = try await Dugite.exec(["remote", "add", "origin", barePath], repo.path)
        // The remote has a branch and a tag named `shared`, at the first commit.
        _ = try await Dugite.exec(["branch", "shared"], barePath)
        _ = try await Dugite.exec(["tag", "shared"], barePath)
        let first = (try await getTipOrError(repo)).sha
        try await makeCommit(repo, Tree(entries: [TreeEntry(path: "README.md", contents: "second")]))

        try await push(repo, Remote(name: "origin", url: barePath), "master", "shared", nil)

        let branch = try await Dugite.exec(["rev-parse", "refs/heads/shared"], barePath)
        #expect(JSCompat.trim(stdout(branch)) == (try await getTipOrError(repo)).sha)
        let tag = try await Dugite.exec(["rev-parse", "refs/tags/shared"], barePath)
        #expect(JSCompat.trim(stdout(tag)) == first)
    }
}
