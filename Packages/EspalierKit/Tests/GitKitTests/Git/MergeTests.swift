// Ported from desktop/app/test/unit/git/merge-test.ts

import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("git/merge")
struct MergeTests {
    @Suite("merge")
    struct Merge {
        @Suite("and is successful")
        struct Successful {
            @Test("returns MergeResult.Success")
            func success() async throws {
                let path = try setupFixtureRepository("merge-base-test")
                let repository = Repository(path: path)
                #expect(try await merge(repository, "dev") == .success)
            }
        }

        @Suite("and is a noop")
        struct Noop {
            @Test("returns MergeResult.AlreadyUpToDate")
            func alreadyUpToDate() async throws {
                let path = try setupFixtureRepository("merge-base-test")
                let repository = Repository(path: path)
                _ = try await merge(repository, "dev")
                #expect(try await merge(repository, "dev") == .alreadyUpToDate)
            }
        }
    }

    @Suite("getMergeBase")
    struct GetMergeBase {
        @Test("accepts a -remote or --remote tracking ref in either argument position", arguments: ["-remote", "--remote"])
        func remoteTrackingRef(remoteName: String) async throws {
            let path = try setupFixtureRepository("merge-base-test")
            let repository = Repository(path: path)
            let upstream = "\(remoteName)/dev"
            try await git(
                ["update-ref", "refs/remotes/\(upstream)", "dev"],
                repository.path,
                "create remote-tracking ref"
            )

            let expected = "df0d73dc92ff496c6a61f10843d527b7461703f4"
            #expect(try await getMergeBase(repository, "master", upstream) == expected)
            #expect(try await getMergeBase(repository, upstream, "master") == expected)
        }

        @Test("returns the common ancestor of two branches")
        func commonAncestor() async throws {
            let path = try setupFixtureRepository("merge-base-test")
            let repository = Repository(path: path)

            let allBranches = try await getBranches(repository)
            let first = try #require(allBranches.first { $0.nameWithoutRemote == "master" }, "Unable to find branch: master")
            let second = try #require(allBranches.first { $0.nameWithoutRemote == "dev" }, "Unable to find branch: dev")

            let ref = try await getMergeBase(repository, first.tip.sha, second.tip.sha)
            #expect(ref == "df0d73dc92ff496c6a61f10843d527b7461703f4")
        }

        @Test("returns null when the branches do not have a common ancestor")
        func noCommonAncestor() async throws {
            let repository = try setupEmptyRepository()

            let firstBranch = "master"
            let secondBranch = "gh-pages"

            // create the first commit
            _ = try await Dugite.exec(["commit", "--allow-empty", "-m", "first commit on master"], repository.path)

            // create a second branch that's orphaned from our current branch
            _ = try await Dugite.exec(["checkout", "--orphan", secondBranch], repository.path)

            // add a commit to this new branch
            _ = try await Dugite.exec(["commit", "--allow-empty", "-m", "first commit on gh-pages"], repository.path)

            let allBranches = try await getBranches(repository)
            let first = try #require(allBranches.first { $0.nameWithoutRemote == firstBranch }, "Unable to find branch \(firstBranch)")
            let second = try #require(allBranches.first { $0.nameWithoutRemote == secondBranch }, "Unable to find branch \(secondBranch)")

            let ref = try await getMergeBase(repository, first.tip.sha, second.tip.sha)
            #expect(ref == nil)
        }

        @Test("returns null when a ref cannot be found")
        func missingRef() async throws {
            let repository = try setupEmptyRepository()

            // create the first commit
            _ = try await Dugite.exec(["commit", "--allow-empty", "-m", "first commit on master"], repository.path)

            let ref = try await getMergeBase(repository, "master", "origin/some-unknown-branch")
            #expect(ref == nil)
        }
    }

    @Suite("abortMerge")
    struct AbortMerge {
        @Suite("when there is no in-progress merge")
        struct NoMerge {
            @Test("throws an error")
            func throwsError() async throws {
                let repository = try setupEmptyRepository()
                let error = await #expect(throws: GitError.self) {
                    try await abortMerge(repository)
                }
                #expect(error?.message.contains("There's no merge to abort") == true)
            }
        }

        @Suite("in the middle of resolving conflicts merge")
        struct Conflicted {
            @Test("aborts the merge")
            func aborts() async throws {
                let repository = try await setupConflictedRepo()
                let tip = try await getTipOrError(repository)
                await #expect(throws: Never.self) {
                    try await abortMerge(repository)
                }

                // The merge is gone, and the branch and its files are as they
                // were before it.
                let status = try await getStatusOrThrow(repository)
                #expect(!status.mergeHeadFound)
                #expect(status.workingDirectory.files.isEmpty)
                #expect(status.currentBranch == "other-branch")
                #expect(status.currentTip == tip.sha)
                let foo = try String(contentsOfFile: POSIXPath.join(repository.path, "foo"), encoding: .utf8)
                #expect(foo == "b2")
            }
        }
    }

    // MARK: - Further cases

    @Suite("merge edge cases")
    struct EdgeCases {
        @Test("fast-forwards a branch that is behind")
        func fastForward() async throws {
            let repository = try await setupMergeRepository(diverged: false)
            let feature = try await getBranchOrError(repository, "feature")

            #expect(try await merge(repository, "feature") == .success)
            #expect(try await getTipOrError(repository).sha == feature.tip.sha)
        }

        @Test("a merge commit has both branches as parents")
        func mergeCommit() async throws {
            let repository = try await setupMergeRepository()
            let master = try await getTipOrError(repository)
            let feature = try await getBranchOrError(repository, "feature")

            #expect(try await merge(repository, "feature") == .success)

            let tip = try await getTipOrError(repository)
            #expect(tip.parentSHAs == [master.sha, feature.tip.sha])
            #expect(tip.summary.hasPrefix("Merge branch 'feature'"))
            #expect(try read(repository, "feature-only") == "feature\n")
        }

        @Test("conflicts return Failed and leave the merge in progress; abortMerge restores the tree and local changes")
        func conflictsThenAbort() async throws {
            let repository = try await setupMergeRepository(conflicting: true)
            let tip = try await getTipOrError(repository)
            // A local change to a file the merge doesn't touch.
            try write(repository, "unrelated", "local\n")

            #expect(try await merge(repository, "feature") == .failed)

            #expect(await isMergeHeadSet(repository))
            let status = try await getStatusOrThrow(repository)
            #expect(status.mergeHeadFound)
            #expect(status.doConflictedFilesExist)
            #expect(status.workingDirectory.files.filter { $0.status.kind == .conflicted }.map(\.path) == ["shared"])
            #expect(try read(repository, "shared").contains("<<<<<<<"))

            try await abortMerge(repository)

            #expect(!(await isMergeHeadSet(repository)))
            #expect(try await getTipOrError(repository).sha == tip.sha)
            #expect(try read(repository, "shared") == "master\n")
            #expect(try read(repository, "unrelated") == "local\n")
            #expect(try await getStatusOrThrow(repository).workingDirectory.files.map(\.path) == ["unrelated"])
        }

        @Test("local changes the merge would overwrite throw, and the repository is left as it was", arguments: [false, true])
        func localChangesOverwritten(squash: Bool) async throws {
            let repository = try await setupMergeRepository(conflicting: true)
            let tip = try await getTipOrError(repository)
            try write(repository, "shared", "local\n")

            let error = await #expect(throws: GitError.self) {
                try await merge(repository, "feature", MergeOptions(squash: squash))
            }
            #expect(error?.result.gitError == .mergeWithLocalChanges)
            #expect(error?.message.contains("Your local changes to the following files would be overwritten by merge") == true)

            #expect(try read(repository, "shared") == "local\n")
            #expect(try await getTipOrError(repository).sha == tip.sha)
            #expect(!(await isMergeHeadSet(repository)))
            #expect(!(await isSquashMsgSet(repository)))
        }

        @Test("untracked files the merge would overwrite throw with git's message, and are kept")
        func untrackedFilesOverwritten() async throws {
            let repository = try await setupMergeRepository()
            let tip = try await getTipOrError(repository)
            try write(repository, "feature-only", "untracked\n")

            let error = await #expect(throws: GitError.self) {
                try await merge(repository, "feature")
            }
            #expect(error?.result.gitError == nil)
            #expect(error?.message.contains("The following untracked working tree files would be overwritten by merge") == true)

            #expect(try read(repository, "feature-only") == "untracked\n")
            #expect(try await getTipOrError(repository).sha == tip.sha)
        }

        @Test("unrelated histories throw", arguments: [false, true])
        func unrelatedHistories(squash: Bool) async throws {
            let repository = try setupEmptyRepository()
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "a", contents: "a\n")], commitMessage: "on master"))
            _ = try await Dugite.exec(["checkout", "--orphan", "orphan"], repository.path)
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "b", contents: "b\n")], commitMessage: "on orphan"))

            let error = await #expect(throws: GitError.self) {
                try await merge(repository, "master", MergeOptions(squash: squash))
            }
            #expect(error?.result.gitError == .cannotMergeUnrelatedHistories)
            #expect(error?.message == "These branches have unrelated histories and can't be merged.")
        }

        // No `--ff` option is passed, so the user's `merge.ff` applies.
        @Test("with merge.ff=only, diverged branches throw git's own message")
        func fastForwardOnly() async throws {
            let repository = try await setupMergeRepository()
            try await setupLocalConfig(repository, [("merge.ff", "only")])
            let tip = try await getTipOrError(repository)

            for squash in [false, true] {
                let error = await #expect(throws: GitError.self) {
                    try await merge(repository, "feature", MergeOptions(squash: squash))
                }
                #expect(error?.result.gitError == nil)
                #expect(error?.message.contains("fatal: Not possible to fast-forward, aborting.") == true)
                #expect(try await getTipOrError(repository).sha == tip.sha)
            }
        }

        @Test("with merge.ff=false, a branch that could fast-forward gets a merge commit")
        func noFastForward() async throws {
            let repository = try await setupMergeRepository(diverged: false)
            try await setupLocalConfig(repository, [("merge.ff", "false")])
            let master = try await getTipOrError(repository)
            let feature = try await getBranchOrError(repository, "feature")

            #expect(try await merge(repository, "feature") == .success)
            #expect(try await getTipOrError(repository).parentSHAs == [master.sha, feature.tip.sha])
        }

        @Test("noVerify skips a merge's pre-merge-commit and commit-msg hooks", arguments: ["pre-merge-commit", "commit-msg"])
        func noVerify(hook: String) async throws {
            let repository = try await setupMergeRepository()
            try writeHook(repository, hook, "echo '\(hook) says no' >&2\nexit 1")
            let tip = try await getTipOrError(repository)

            // git leaves the merge in progress, with its result staged.
            let error = await #expect(throws: GitError.self) {
                try await merge(repository, "feature")
            }
            #expect(error?.message.contains("\(hook) says no") == true)
            #expect(error?.message.contains("Not committing merge") == true)
            #expect(await isMergeHeadSet(repository))
            #expect(try await getTipOrError(repository).sha == tip.sha)
            try await abortMerge(repository)

            #expect(try await merge(repository, "feature", MergeOptions(noVerify: true)) == .success)
            #expect(try await getTipOrError(repository).parentSHAs.count == 2)
        }

        @Test("a failing post-merge hook doesn't fail the merge")
        func postMerge() async throws {
            let repository = try await setupMergeRepository()
            try writeHook(repository, "post-merge", "exit 1")

            #expect(try await merge(repository, "feature") == .success)
            #expect(try await getTipOrError(repository).parentSHAs.count == 2)
        }
    }

    @Suite("squash merge")
    struct Squash {
        @Test("commits the branch's changes as one new commit")
        func squashes() async throws {
            let repository = try await setupMergeRepository()
            let master = try await getTipOrError(repository)

            #expect(try await merge(repository, "feature", MergeOptions(squash: true)) == .success)

            let tip = try await getTipOrError(repository)
            #expect(tip.parentSHAs == [master.sha])
            #expect(tip.summary == "Squashed commit of the following:")
            #expect(try read(repository, "feature-only") == "feature\n")
            #expect(!(await isSquashMsgSet(repository)))
            #expect(try await getStatusOrThrow(repository).workingDirectory.files.isEmpty)
        }

        @Test("leaves unrelated local changes out of the commit")
        func localChangesStayLocal() async throws {
            let repository = try await setupMergeRepository(diverged: false)
            try write(repository, "unrelated", "local\n")

            #expect(try await merge(repository, "feature", MergeOptions(squash: true)) == .success)

            let files = try await git(["show", "--name-only", "--format=", "HEAD"], repository.path, "test").stdout
            #expect(files == "feature-only\n")
            #expect(try read(repository, "unrelated") == "local\n")
            let status = try await getStatusOrThrow(repository)
            #expect(status.workingDirectory.files.map(\.path) == ["unrelated"])
        }

        @Test("conflicts return Failed and leave SQUASH_MSG without MERGE_HEAD")
        func conflicts() async throws {
            let repository = try await setupMergeRepository(conflicting: true)
            let tip = try await getTipOrError(repository)

            #expect(try await merge(repository, "feature", MergeOptions(squash: true)) == .failed)

            #expect(await isSquashMsgSet(repository))
            #expect(!(await isMergeHeadSet(repository)))
            let status = try await getStatusOrThrow(repository)
            #expect(status.squashMsgFound)
            #expect(!status.mergeHeadFound)
            #expect(status.doConflictedFilesExist)
            #expect(try await getTipOrError(repository).sha == tip.sha)

            // `git merge --abort` needs MERGE_HEAD, which is why a squash merge
            // is aborted another way.
            let error = await #expect(throws: GitError.self) {
                try await abortMerge(repository)
            }
            #expect(error?.result.gitError == .noMergeToAbort)
        }

        // Nothing to commit, so `git commit` isn't run (it would fail with
        // "There are no changes to commit.").
        @Test("returns AlreadyUpToDate for a branch that is already in the current branch")
        func alreadyMerged() async throws {
            let repository = try await setupMergeRepository()
            _ = try await Dugite.exec(["branch", "old", "HEAD~1"], repository.path)
            let tip = try await getTipOrError(repository)

            #expect(try await merge(repository, "old", MergeOptions(squash: true)) == .alreadyUpToDate)

            #expect(try await getTipOrError(repository).sha == tip.sha)
            #expect(!(await isSquashMsgSet(repository)))
        }

        // A squash merge leaves no merge in the history, so git merges the
        // branch again and finds nothing to change; `git commit` would fail
        // with "There are no changes to commit."
        @Test("returns AlreadyUpToDate when merging a branch again, without running commit hooks or leaving SQUASH_MSG")
        func mergedAgain() async throws {
            let repository = try await setupMergeRepository()
            #expect(try await merge(repository, "feature", MergeOptions(squash: true)) == .success)
            let tip = try await getTipOrError(repository)
            let marker = POSIXPath.join(try createTempDirectory(), "pre-commit-ran")
            try writeHook(repository, "pre-commit", "touch '\(marker)'\nexit 1")

            #expect(try await merge(repository, "feature", MergeOptions(squash: true)) == .alreadyUpToDate)

            #expect(try await getTipOrError(repository).sha == tip.sha)
            #expect(!(await isSquashMsgSet(repository)))
            let status = try await getStatusOrThrow(repository)
            #expect(!status.squashMsgFound)
            #expect(status.workingDirectory.files.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: marker))
        }

        // `--no-verify` reaches the commit, not only `git merge --squash`.
        @Test("noVerify skips the commit's pre-commit and commit-msg hooks", arguments: ["pre-commit", "commit-msg"])
        func noVerify(hook: String) async throws {
            let repository = try await setupMergeRepository()
            try writeHook(repository, hook, "echo '\(hook) says no' >&2\nexit 1")
            let tip = try await getTipOrError(repository)

            // The squashed changes stay staged, as with git.
            let error = await #expect(throws: GitError.self) {
                try await merge(repository, "feature", MergeOptions(squash: true))
            }
            #expect(error?.message.contains("\(hook) says no") == true)
            #expect(try await getTipOrError(repository).sha == tip.sha)
            #expect(await isSquashMsgSet(repository))
            #expect(try await git(["diff", "--cached", "--name-only"], repository.path, "test").stdout == "feature-only\n")
            _ = try await Dugite.exec(["reset", "--hard"], repository.path)

            #expect(try await merge(repository, "feature", MergeOptions(squash: true, noVerify: true)) == .success)
            #expect(try await getTipOrError(repository).parentSHAs == [tip.sha])
        }

        @Test("sends the output of the merge and the commit to one subscriber, in order")
        func terminalOutput() async throws {
            let repository = try await setupMergeRepository()
            let calls = Atomic(0)
            let output = Mutex("")

            let result = try await merge(repository, "feature", MergeOptions(
                squash: true,
                onTerminalOutputAvailable: { subscribe in
                    calls.add(1, ordering: .relaxed)
                    _ = subscribe { chunk in output.withLock { $0 += chunk } }
                }
            ))

            #expect(result == .success)
            #expect(calls.load(ordering: .relaxed) == 1)
            let text = output.withLock { $0 }
            let merged = try #require(text.range(of: "Squash commit -- not updating HEAD"))
            let committed = try #require(text.range(of: "] Squashed commit of the following:"))
            #expect(merged.lowerBound < committed.lowerBound)
        }
    }
}

// MARK: - Helpers

/// A repository on `master` whose `feature` branch adds `feature-only` and
/// changes `shared` (to "feature" when `conflicting`, else leaving it).
/// When `diverged`, `master` has a commit of its own that changes `shared`
/// to "master" (when conflicting) or adds `master-only`.
private func setupMergeRepository(diverged: Bool = true, conflicting: Bool = false) async throws -> Repository {
    let repository = try setupEmptyRepository()
    try await makeCommit(repository, Tree(
        entries: [
            TreeEntry(path: "shared", contents: "base\n"),
            TreeEntry(path: "unrelated", contents: "base\n"),
        ],
        commitMessage: "base"
    ))
    try await createBranch(repository, "feature", "HEAD")

    if diverged {
        try await makeCommit(repository, Tree(
            entries: [conflicting ? TreeEntry(path: "shared", contents: "master\n") : TreeEntry(path: "master-only", contents: "master\n")],
            commitMessage: "master changes"
        ))
    }

    try await switchTo(repository, "feature")
    var featureEntries = [TreeEntry(path: "feature-only", contents: "first\n")]
    if conflicting {
        featureEntries.append(TreeEntry(path: "shared", contents: "feature\n"))
    }
    try await makeCommit(repository, Tree(entries: featureEntries, commitMessage: "feature changes"))
    try await makeCommit(repository, Tree(entries: [TreeEntry(path: "feature-only", contents: "feature\n")], commitMessage: "more feature changes"))
    try await switchTo(repository, "master")
    return repository
}

private func write(_ repository: Repository, _ path: String, _ contents: String) throws {
    try Data(contents.utf8).write(to: URL(filePath: POSIXPath.join(repository.path, path)))
}

private func read(_ repository: Repository, _ path: String) throws -> String {
    try String(contentsOfFile: POSIXPath.join(repository.path, path), encoding: .utf8)
}

/// Writes an executable hook into the repository's hooks directory.
func writeHook(_ repository: Repository, _ name: String, _ body: String) throws {
    let hooks = POSIXPath.join(repository.resolvedGitDir, "hooks")
    try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
    let path = POSIXPath.join(hooks, name)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(filePath: path))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}
