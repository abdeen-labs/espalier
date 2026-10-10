// Ported from desktop/app/test/unit/git/remote-operations-test.ts
//
// Each test runs inside `withIsolatedGitConfig`. The remote names and
// options are test arguments.

import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

private let remoteNames = ["origin", "--remote"]

/// A clone of an upstream repository that has one more commit than the
/// clone has fetched. The clone reaches the upstream through a remote named
/// `name`, with remote-tracking branches under `refs/remotes/<name>/`.
private func setupRemote(_ name: String) async throws -> (repository: Repository, upstream: Repository, remote: Remote) {
    let upstream = try setupEmptyRepository()
    try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "initial")]))

    let repository = try await cloneRepository(upstream)
    if name != "origin" {
        try await git(
            ["config", "--rename-section", "remote.origin", "remote.\(name)"],
            repository.path,
            "rename remote configuration"
        )
        try await git(["config", "branch.master.remote", name], repository.path, "set upstream remote")
        try await git(
            ["config", "remote.\(name).fetch", "+refs/heads/*:refs/remotes/\(name)/*"],
            repository.path,
            "set remote-tracking namespace"
        )
        try await git(["fetch", "--", name], repository.path, "initialize remote-tracking refs")
    }

    try await makeCommit(upstream, Tree(entries: [TreeEntry(path: "README.md", contents: "updated")]))

    let remote = Remote(name: name, url: upstream.path)
    return (repository, upstream, remote)
}

/// Counts its calls.
private final class MockFunction: Sendable {
    private let calls = Mutex(0)

    var callCount: Int {
        calls.withLock { $0 }
    }

    /// A callback that counts its calls, or nil when `enabled` is false.
    func callback<Value>(_ enabled: Bool = true) -> (@Sendable (Value) -> Void)? {
        guard enabled else {
            return nil
        }
        return { _ in self.calls.withLock { $0 += 1 } }
    }
}

/// Installs a pre-push hook that rejects every push.
private func writeRejectingPrePushHook(_ repository: Repository) throws {
    let hooks = POSIXPath.join(repository.path, ".git", "hooks")
    try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
    let hook = POSIXPath.join(hooks, "pre-push")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: URL(filePath: hook))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
}

private func readFile(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

@Suite("git/remote operations")
struct RemoteOperationsTests {
    @Suite("remote named origin or --remote")
    struct RemoteNamed {
        @Test("discovers unpushed tags without modifying the remote", arguments: remoteNames)
        func discoversUnpushedTags(_ remoteName: String) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, upstream, remote) = try await setupRemote(remoteName)
                try await git(["tag", "-a", "-m", "Release", "v1.0"], repository.path, "create annotated tag")
                try writeRejectingPrePushHook(repository)
                let before = try await getTipOrError(upstream)

                #expect(try await fetchTagsToPush(repository, remote, "master") == ["v1.0"])

                #expect(try await getAllTags(upstream).isEmpty)
                #expect(try await getTipOrError(upstream).sha == before.sha)
            }
        }

        @Test("adds a worktree from a canonical remote ref", arguments: remoteNames, [nil, "linked-branch"] as [String?])
        func addsWorktreeFromRemoteRef(_ remoteName: String, _ branchName: String?) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, upstream, remote) = try await setupRemote(remoteName)
                try await fetch(repository, remote)
                let worktreePath = try createTempDirectory()

                try await addWorktree(repository, worktreePath, AddWorktreeOptions(
                    createBranch: branchName,
                    commitish: "refs/remotes/\(remoteName)/master"
                ))

                let head = try await git(["rev-parse", "HEAD"], worktreePath, "get worktree commit")
                let expected = try await getTipOrError(upstream)
                #expect(JSCompat.trim(head.stdout) == expected.sha)
                let branch = try await git(
                    ["symbolic-ref", "--quiet", "--short", "HEAD"],
                    worktreePath,
                    "get worktree branch",
                    options: GitExecutionOptions(successExitCodes: [0, 1])
                )
                #expect(branch.exitCode == (branchName == nil ? 1 : 0))
                #expect(JSCompat.trim(branch.stdout) == (branchName ?? ""))
                if let branchName {
                    let tracking = try await git(
                        ["config", "--get", "branch.\(branchName).remote"],
                        worktreePath,
                        "get worktree upstream remote"
                    )
                    #expect(JSCompat.trim(tracking.stdout) == remoteName)
                }
                #expect(try readFile(POSIXPath.join(worktreePath, "README.md")) == "updated")
            }
        }

        @Test("adds a worktree for a new or an existing local branch", arguments: ["origin"], [false, true])
        func addsWorktreeForLocalBranch(_ remoteName: String, _ createNewBranch: Bool) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, _, _) = try await setupRemote(remoteName)
                let worktreePath = try createTempDirectory()
                let branchName = "local-worktree"
                let expected = try await getTipOrError(repository)

                if !createNewBranch {
                    try await git(["branch", branchName], repository.path, "create local worktree branch")
                }

                try await addWorktree(
                    repository,
                    worktreePath,
                    createNewBranch
                        ? AddWorktreeOptions(createBranch: branchName)
                        : AddWorktreeOptions(commitish: branchName)
                )

                let head = try await git(["rev-parse", "HEAD"], worktreePath, "get worktree commit")
                #expect(JSCompat.trim(head.stdout) == expected.sha)
                let branch = try await git(["symbolic-ref", "--short", "HEAD"], worktreePath, "get worktree branch")
                #expect(JSCompat.trim(branch.stdout) == branchName)
                #expect(try readFile(POSIXPath.join(worktreePath, "README.md")) == "initial")
                let tracking = try await git(
                    ["config", "--get", "branch.\(branchName).remote"],
                    worktreePath,
                    "check worktree has no upstream",
                    options: GitExecutionOptions(successExitCodes: [0, 1])
                )
                #expect(tracking.exitCode == 1)
            }
        }

        @Test("checks out a remote branch and configures upstream tracking", arguments: remoteNames)
        func checksOutRemoteBranch(_ remoteName: String) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, upstream, remote) = try await setupRemote(remoteName)
                try await git(["branch", "topic"], upstream.path, "create remote branch")
                try await git(
                    ["config", "branch.autoSetupMerge", "true"],
                    repository.path,
                    "enable automatic upstream tracking"
                )
                try await fetch(repository, remote)
                let branch = try #require(try await getBranches(repository, "refs/remotes/\(remoteName)/topic").first)

                try await checkoutBranch(repository, branch, remote)

                let current = try await git(["symbolic-ref", "--short", "HEAD"], repository.path, "get checked out branch")
                #expect(JSCompat.trim(current.stdout) == "topic")
                let local = try await getBranchOrError(repository, "topic")
                #expect(local.upstream == "\(remoteName)/topic")
                #expect(local.tip.sha == branch.tip.sha)
                #expect(try readFile(POSIXPath.join(repository.path, "README.md")) == "updated")
            }
        }

        @Test("rebases onto a remote ref with progress", arguments: remoteNames, [false, true])
        func rebasesOntoRemoteRef(_ remoteName: String, _ withProgress: Bool) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, upstream, remote) = try await setupRemote(remoteName)
                try await makeCommit(repository, Tree(entries: [TreeEntry(path: "local.txt", contents: "local change")]))
                try await fetch(repository, remote)
                let base = try #require(try await getBranches(repository, "refs/remotes/\(remoteName)/master").first)
                let target = try await getBranchOrError(repository, "master")
                let progress = MockFunction()

                #expect(
                    try await rebase(repository, base, target, progressCallback: progress.callback(withProgress))
                        == .completedWithoutError
                )

                let after = try await getTipOrError(repository)
                let expected = try await getTipOrError(upstream)
                #expect(after.parentSHAs == [expected.sha])
                #expect(try readFile(POSIXPath.join(repository.path, "local.txt")) == "local change")
                #expect((progress.callCount > 0) == withProgress)
            }
        }

        @Test("merges a remote ref with squash", arguments: remoteNames, [false, true])
        func mergesRemoteRef(_ remoteName: String, _ squash: Bool) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, upstream, remote) = try await setupRemote(remoteName)
                try await fetch(repository, remote)
                let before = try await getTipOrError(repository)

                #expect(
                    try await merge(repository, "\(remoteName)/master", MergeOptions(squash: squash, noVerify: true))
                        == .success
                )

                let after = try await getTipOrError(repository)
                let expected = try await getTipOrError(upstream)
                if squash {
                    #expect(after.parentSHAs == [before.sha])
                } else {
                    #expect(after.sha == expected.sha)
                }
                #expect(try readFile(POSIXPath.join(repository.path, "README.md")) == "updated")
            }
        }

        @Test("creates a branch from a remote ref with noTrack", arguments: remoteNames, [false, true])
        func createsBranchFromRemoteRef(_ remoteName: String, _ noTrack: Bool) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, _, _) = try await setupRemote(remoteName)
                try await git(
                    ["config", "branch.autoSetupMerge", "true"],
                    repository.path,
                    "enable automatic upstream tracking"
                )
                let startPoint = "\(remoteName)/master"
                let expected = try await getRefOrError(repository, "refs/remotes/\(startPoint)")

                // GitKit's, not TestSupport's helper of the same name.
                try await GitKit.createBranch(repository, "from-remote", startPoint, noTrack: noTrack)

                let branch = try await getBranchOrError(repository, "from-remote")
                #expect(branch.tip.sha == expected.sha)
                #expect(branch.upstream == (noTrack ? nil : startPoint))
            }
        }

        @Test("deletes a remote branch and its tracking ref", arguments: remoteNames)
        func deletesRemoteBranch(_ remoteName: String) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, upstream, remote) = try await setupRemote(remoteName)
                try await git(["branch", "topic"], upstream.path, "create remote branch")
                try await fetch(repository, remote)
                _ = try await getRefOrError(repository, "refs/remotes/\(remoteName)/topic")

                try await deleteRemoteBranch(repository, remote, "topic")

                for (path, ref) in [
                    (upstream.path, "refs/heads/topic"),
                    (repository.path, "refs/remotes/\(remoteName)/topic"),
                ] {
                    let result = try await git(
                        ["show-ref", "--verify", "--quiet", ref],
                        path,
                        "verify deleted branch",
                        options: GitExecutionOptions(successExitCodes: [0, 1])
                    )
                    #expect(result.exitCode == 1, "\(ref) still exists")
                }
            }
        }

        @Test("fetches updates with progress", arguments: remoteNames, [false, true])
        func fetchesUpdates(_ remoteName: String, _ withProgress: Bool) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, upstream, remote) = try await setupRemote(remoteName)
                let progress = MockFunction()

                try await fetch(repository, remote, progressCallback: progress.callback(withProgress))

                let actual = try await getRefOrError(repository, "refs/remotes/\(remoteName)/master")
                let expected = try await getTipOrError(upstream)
                #expect(actual.sha == expected.sha)
                #expect((progress.callCount > 0) == withProgress)
            }
        }

        @Test("pushes a branch and tags with progress", arguments: remoteNames, [false, true])
        func pushesBranchAndTags(_ remoteName: String, _ withProgress: Bool) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, upstream, remote) = try await setupRemote(remoteName)
                try await makeCommit(repository, Tree(entries: [TreeEntry(path: "new-file.txt", contents: "new content")]))
                try await git(["tag", "v1.0"], repository.path, "create tag")
                try writeRejectingPrePushHook(repository)
                let progress = MockFunction()

                try await push(
                    repository,
                    remote,
                    "master",
                    "published",
                    ["refs/tags/v1.0"],
                    PushOptions(noVerify: true),
                    progressCallback: progress.callback(withProgress)
                )

                let expected = try await getTipOrError(repository)
                let branch = try await getRefOrError(upstream, "refs/heads/published")
                let tag = try await getRefOrError(upstream, "refs/tags/v1.0")
                #expect(branch.sha == expected.sha)
                #expect(tag.sha == expected.sha)
                #expect((progress.callCount > 0) == withProgress)
            }
        }

        @Test("fetches an explicit refspec", arguments: remoteNames)
        func fetchesExplicitRefspec(_ remoteName: String) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, upstream, remote) = try await setupRemote(remoteName)

                try await fetchRefspec(repository, remote, "refs/heads/master:refs/remotes/\(remoteName)/explicit")

                let actual = try await getRefOrError(repository, "refs/remotes/\(remoteName)/explicit")
                let expected = try await getTipOrError(upstream)
                #expect(actual.sha == expected.sha)
            }
        }

        // MARK: - Espalier

        // The lease itself, which is what keeps someone else's commits, not
        // just a force-with-lease push that succeeds.
        @Test("force-with-lease keeps remote commits that weren't fetched", arguments: remoteNames)
        func forceWithLeaseKeepsUnfetchedCommits(_ remoteName: String) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, upstream, remote) = try await setupRemote(remoteName)
                // The repository sees `shared` at the upstream's first commit...
                try await git(["branch", "shared", "HEAD~1"], upstream.path, "create shared branch")
                try await fetch(repository, remote)
                // ...and then someone else moves it on.
                try await git(["branch", "--force", "shared", "master"], upstream.path, "update shared branch")
                let theirs = try await getRefOrError(upstream, "refs/heads/shared")
                try await makeCommit(repository, Tree(entries: [TreeEntry(path: "local.txt", contents: "local change")]))

                await #expect(throws: GitError.self) {
                    try await push(repository, remote, "master", "shared", nil, PushOptions(forceWithLease: true))
                }
                #expect(try await getRefOrError(upstream, "refs/heads/shared").sha == theirs.sha)

                // Once their commit is fetched, the lease holds.
                try await fetch(repository, remote)
                try await push(repository, remote, "master", "shared", nil, PushOptions(forceWithLease: true))
                let ours = try await getTipOrError(repository)
                #expect(try await getRefOrError(upstream, "refs/heads/shared").sha == ours.sha)
            }
        }

        // `git worktree add -B` would reset the branch to the start point and
        // drop its commits.
        @Test("adding a worktree on a new branch never moves an existing branch", arguments: remoteNames)
        func addWorktreeKeepsExistingBranch(_ remoteName: String) async throws {
            try await withIsolatedGitConfig { _ in
                let (repository, _, remote) = try await setupRemote(remoteName)
                try await fetch(repository, remote)
                try await makeCommit(repository, Tree(entries: [TreeEntry(path: "local.txt", contents: "unpushed")]))
                try await git(["branch", "local-work"], repository.path, "create a branch with unpushed work")
                let unpushed = try await getRefOrError(repository, "refs/heads/local-work")
                let worktreePath = try createTempDirectory()

                await #expect(throws: GitError.self) {
                    try await addWorktree(repository, worktreePath, AddWorktreeOptions(
                        createBranch: "local-work",
                        commitish: "refs/remotes/\(remoteName)/master"
                    ))
                }

                #expect(try await getBranchOrError(repository, "local-work").tip.sha == unpushed.sha)
                #expect(try await listWorktrees(repository).count == 1)
            }
        }
    }

    @Test("rejects an unknown option-looking remote during fetch", arguments: ["fetch", "fetch with progress"])
    func rejectsOptionLookingRemote(_ operation: String) async throws {
        try await withIsolatedGitConfig { _ in
            let (repository, upstream, _) = try await setupRemote("origin")
            let before = try await getRefOrError(repository, "refs/remotes/origin/master")
            let remote = Remote(name: "--dry-run", url: upstream.path)
            let progress = MockFunction()

            let error = await #expect(throws: GitError.self) {
                try await fetch(
                    repository,
                    remote,
                    progressCallback: progress.callback(operation == "fetch with progress")
                )
            }
            #expect(error?.result.stderr.contains("'--dry-run'") == true)

            let after = try await getRefOrError(repository, "refs/remotes/origin/master")
            #expect(after.sha == before.sha)
        }
    }

    @Test("leaves origin unchanged when fetching a refspec from an unknown remote")
    func leavesOriginUnchanged() async throws {
        try await withIsolatedGitConfig { _ in
            let (repository, upstream, _) = try await setupRemote("origin")
            let before = try await getRefOrError(repository, "refs/remotes/origin/master")

            try await fetchRefspec(repository, Remote(name: "--multiple", url: upstream.path), "origin")

            let after = try await getRefOrError(repository, "refs/remotes/origin/master")
            #expect(after.sha == before.sha)
        }
    }

    @Test("pulls updates with progress", arguments: [false, true])
    func pullsUpdates(_ withProgress: Bool) async throws {
        try await withIsolatedGitConfig { _ in
            let (repository, upstream, remote) = try await setupRemote("origin")
            let progress = MockFunction()

            try await pull(repository, remote, PullOptions(
                progressCallback: progress.callback(withProgress),
                noVerify: withProgress
            ))

            let actual = try await getTipOrError(repository)
            let expected = try await getTipOrError(upstream)
            #expect(actual.sha == expected.sha)
            #expect((progress.callCount > 0) == withProgress)
        }
    }

    @Test("rejects pulling from a leading-dash remote before reporting progress", arguments: ["-remote", "--dry-run"])
    func rejectsPullingFromLeadingDashRemote(_ name: String) async throws {
        try await withIsolatedGitConfig { _ in
            let (repository, _, remote) = try await setupRemote(name)
            let before = try await getTipOrError(repository)
            let progress = MockFunction()
            let branch = try await getBranchOrError(repository, "master")
            #expect(branch.upstream == "\(name)/master")
            let upstream = try #require(branch.upstream)

            #expect(try await getMergeBase(repository, branch.name, upstream) == before.sha)

            let error = await #expect(throws: PullRemoteNameError.self) {
                try await pull(repository, remote, PullOptions(progressCallback: progress.callback()))
            }
            #expect(error?.localizedDescription == "Cannot pull from a remote whose name starts with '-'.")

            let after = try await getTipOrError(repository)
            #expect(after.sha == before.sha)
            #expect(progress.callCount == 0)
        }
    }
}
