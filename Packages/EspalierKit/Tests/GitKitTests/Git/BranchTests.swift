// Ported from desktop/app/test/unit/git/branch-test.ts
//
// The tip comes from `loadTip` (TestSupport).

import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// Whether the volume test repositories live on ignores case in names.
private func temporaryVolumeIsCaseInsensitive() -> Bool {
    let values = try? URL(filePath: NSTemporaryDirectory()).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    return values?.volumeSupportsCaseSensitiveNames == false
}

@Suite("git/branch")
struct BranchTests {
    @Suite("tip")
    struct TipTests {
        @Test("returns correct ref if checkout occurs")
        func unbornAfterCheckout() async throws {
            let repository = try setupEmptyRepository()

            _ = try await Dugite.exec(["checkout", "-b", "not-master"], repository.path)

            let tip = try await loadTip(repository)

            #expect(tip.kind == .unborn)
            guard case .unborn(let ref) = tip else { return }
            #expect(ref == "not-master")
        }

        @Test("returns detached for arbitrary checkout")
        func detached() async throws {
            let path = try setupFixtureRepository("detached-head")
            let repository = Repository(path: path)

            let tip = try await loadTip(repository)

            #expect(tip.kind == .detached)
            guard case .detached(let currentSha) = tip else { return }
            #expect(currentSha == "2acb028231d408aaa865f9538b1c89de5a2b9da8")
        }

        @Test("returns current branch when on a valid HEAD")
        func valid() async throws {
            let path = try setupFixtureRepository("repo-with-many-refs")
            let repository = Repository(path: path)

            let tip = try await loadTip(repository)

            #expect(tip.kind == .valid)
            guard case .valid(let branch) = tip else { return }
            #expect(branch.name == "commit-with-long-description")
            #expect(branch.tip.sha == "dfa96676b65e1c0ed43ca25492252a5e384c8efd")
        }
    }

    @Suite("upstreamWithoutRemote")
    struct UpstreamWithoutRemote {
        @Test("returns the upstream name without the remote prefix")
        func upstreamWithoutRemote() async throws {
            let path = try setupFixtureRepository("repo-with-multiple-remotes")
            let repository = Repository(path: path)

            let tip = try await loadTip(repository)

            #expect(tip.kind == .valid)

            guard case .valid(let branch) = tip else { return }
            #expect(branch.upstreamRemoteName == "bassoon")
            #expect(branch.upstream == "bassoon/master")
            #expect(branch.upstreamWithoutRemote == "master")
        }
    }

    @Suite("getBranchesPointedAt")
    struct GetBranchesPointedAt {
        @Suite("in a local repo")
        struct InALocalRepo {
            @Test("finds no branch names")
            func findsNone() async throws {
                let path = try setupFixtureRepository("test-repo")
                let repository = Repository(path: path)

                let branches = try #require(try await getBranchesPointedAt(repository, "HEAD^"))
                #expect(branches.count == 0)
            }

            @Test("returns null on a malformed committish")
            func malformed() async throws {
                let path = try setupFixtureRepository("test-repo")
                let repository = Repository(path: path)

                let branches = try await getBranchesPointedAt(repository, "MERGE_HEAD")
                #expect(branches == nil)
            }
        }

        @Suite("in a repo with identical branches")
        struct InARepoWithIdenticalBranches {
            @Test("finds multiple branch names")
            func findsMultiple() async throws {
                let path = try setupFixtureRepository("repo-with-multiple-remotes")
                let repository = Repository(path: path)
                try await createBranch(repository, "other-branch", nil)

                let branches = try #require(try await getBranchesPointedAt(repository, "HEAD"))
                #expect(branches.count == 2)
                #expect(branches.contains("other-branch"))
                #expect(branches.contains("master"))
            }
        }
    }

    @Suite("deleteRemoteBranch")
    struct DeleteRemoteBranch {
        @Test("delete a local branches upstream branch")
        func deletesUpstream() async throws {
            let path = try setupFixtureRepository("test-repo")
            let mockRemote = Repository(path: path)

            let name = "test-branch"
            try await createBranch(mockRemote, name, nil)
            let localRef = "refs/heads/\(name)"

            let mockLocal = try await setupLocalForkOfRepository(mockRemote)

            let remoteRef = "refs/remotes/origin/\(name)"
            let remoteBranch = try #require(try await getBranches(mockLocal, remoteRef).first)

            try await checkoutBranch(mockLocal, remoteBranch, nil)
            try await git(["checkout", "-"], mockLocal.path, "checkoutPrevious")

            #expect(try await getBranches(mockLocal, localRef).count == 1)
            #expect(try await getBranches(mockRemote, localRef).count == 1)

            let localBranch = try #require(try await getBranches(mockLocal, localRef).first)
            let upstreamRemoteName = try #require(localBranch.upstreamRemoteName)
            let upstreamWithoutRemote = try #require(localBranch.upstreamWithoutRemote)

            try await deleteRemoteBranch(mockLocal, Remote(name: upstreamRemoteName, url: ""), upstreamWithoutRemote)

            #expect(try await getBranches(mockLocal, localRef).count == 1)
            #expect(try await getBranches(mockLocal, remoteRef).count == 0)
            #expect(try await getBranches(mockRemote, localRef).count == 0)
        }

        @Test("handles attempted delete of removed remote branch")
        func alreadyDeleted() async throws {
            let path = try setupFixtureRepository("test-repo")
            let mockRemote = Repository(path: path)

            let name = "test-branch"
            try await createBranch(mockRemote, name, nil)
            let localRef = "refs/heads/\(name)"

            #expect(try await getBranches(mockRemote, localRef).count == 1)

            let mockLocal = try await setupLocalForkOfRepository(mockRemote)

            let remoteRef = "refs/remotes/origin/\(name)"
            let remoteBranch = try #require(try await getBranches(mockLocal, remoteRef).first)

            try await checkoutBranch(mockLocal, remoteBranch, nil)
            try await git(["checkout", "-"], mockLocal.path, "checkoutPrevious")

            #expect(try await getBranches(mockLocal, localRef).count == 1)
            #expect(try await getBranches(mockRemote, localRef).count == 1)

            let upstreamBranch = try #require(try await getBranches(mockRemote, localRef).first)
            try await deleteLocalBranch(mockRemote, upstreamBranch.name)
            #expect(try await getBranches(mockRemote, localRef).count == 0)

            let localBranch = try #require(try await getBranches(mockLocal, localRef).first)
            let upstreamRemoteName = try #require(localBranch.upstreamRemoteName)
            let upstreamWithoutRemote = try #require(localBranch.upstreamWithoutRemote)

            try await deleteRemoteBranch(mockLocal, Remote(name: upstreamRemoteName, url: ""), upstreamWithoutRemote)

            #expect(try await getBranches(mockLocal, remoteRef).count == 0)
            #expect(try await getBranches(mockRemote, localRef).count == 0)
        }
    }

    // MARK: - Espalier

    @Suite("createBranch")
    struct CreateBranch {
        @Test("starts the branch at the given start point, or at HEAD")
        func startPoints() async throws {
            let repository = try await setupTwoCommitRepo()
            let first = try await getRefOrError(repository, "HEAD~1")
            let head = try await getTipOrError(repository)
            try await createTag(repository, "v1", first.sha)

            try await createBranch(repository, "from-head", nil)
            try await createBranch(repository, "from-sha", first.sha, noTrack: false)
            try await createBranch(repository, "from-tag", "v1", noTrack: false)
            try await createBranch(repository, "from-branch", "from-sha", noTrack: false)

            #expect(try await getBranchOrError(repository, "from-head").tip.sha == head.sha)
            #expect(try await getBranchOrError(repository, "from-sha").tip.sha == first.sha)
            #expect(try await getBranchOrError(repository, "from-tag").tip.sha == first.sha)
            #expect(try await getBranchOrError(repository, "from-branch").tip.sha == first.sha)

            // Creating a branch doesn't switch to it.
            let tip = try await loadTip(repository)
            guard case .valid(let current) = tip else {
                Issue.record("Expected a valid tip, got \(tip)")
                return
            }
            #expect(current.name == "master")
        }

        @Test("fails for an existing or invalid name and changes nothing")
        func failures() async throws {
            let repository = try await setupTwoCommitRepo()
            let first = try await getRefOrError(repository, "HEAD~1")
            try await createBranch(repository, "existing", first.sha, noTrack: false)

            let error = await #expect(throws: GitError.self) {
                try await createBranch(repository, "existing", nil)
            }
            #expect(error?.result.gitError == .branchAlreadyExists)
            #expect(try await getBranchOrError(repository, "existing").tip.sha == first.sha)

            await #expect(throws: GitError.self) {
                try await createBranch(repository, "two..dots", nil)
            }
            // A leading dash is a name, not an option, after `--`.
            await #expect(throws: GitError.self) {
                try await createBranch(repository, "-D", nil)
            }
            #expect(try await getBranchNames(repository).sorted() == ["existing", "master"])
        }

        @Test("keeps a non-ASCII name exactly")
        func nonASCII() async throws {
            let repository = try await setupTwoCommitRepo()
            let name = "f\u{EB}ature/caf\u{E9}-\u{1F333}"

            try await createBranch(repository, name, nil)

            let branch = try await getBranchOrError(repository, name)
            #expect(Array(branch.name.utf8) == Array(name.utf8))
            #expect(try await getBranchNames(repository).contains { JSCompat.strictEquals($0, name) })

            try await checkoutBranch(repository, branch, nil)
            let tip = try await loadTip(repository)
            guard case .valid(let current) = tip else {
                Issue.record("Expected a valid tip, got \(tip)")
                return
            }
            #expect(Array(current.name.utf8) == Array(name.utf8))
        }
    }

    @Suite("renameBranch")
    struct RenameBranch {
        @Test("renames a branch and keeps its commits")
        func renames() async throws {
            let repository = try await setupTwoCommitRepo()
            try await createBranch(repository, "old-name", "HEAD~1", noTrack: false)
            let branch = try await getBranchOrError(repository, "old-name")

            try await renameBranch(repository, branch, "new-name")

            #expect(try await getBranches(repository, "refs/heads/old-name").isEmpty)
            #expect(try await getBranchOrError(repository, "new-name").tip.sha == branch.tip.sha)
        }

        @Test("renames the current branch")
        func renamesCurrent() async throws {
            let repository = try await setupTwoCommitRepo()
            let branch = try await getBranchOrError(repository, "master")

            try await renameBranch(repository, branch, "main")

            let tip = try await loadTip(repository)
            guard case .valid(let current) = tip else {
                Issue.record("Expected a valid tip, got \(tip)")
                return
            }
            #expect(current.name == "main")
            #expect(current.tip.sha == branch.tip.sha)
        }

        @Test("renames a branch when only the case changes")
        func caseOnly() async throws {
            let repository = try await setupTwoCommitRepo()
            try await createBranch(repository, "Feature", "HEAD~1", noTrack: false)
            let branch = try await getBranchOrError(repository, "Feature")

            try await renameBranch(repository, branch, "feature")

            let names = try await getBranchNames(repository)
            #expect(names.contains("feature"))
            #expect(!names.contains("Feature"))
            #expect(try await getBranchOrError(repository, "feature").tip.sha == branch.tip.sha)
        }

        @Test("doesn't replace an existing branch")
        func existingName() async throws {
            let repository = try await setupTwoCommitRepo()
            try await createBranch(repository, "first", "HEAD~1", noTrack: false)
            try await createBranch(repository, "second", "HEAD", noTrack: false)
            let first = try await getBranchOrError(repository, "first")
            let second = try await getBranchOrError(repository, "second")

            let error = await #expect(throws: GitError.self) {
                try await renameBranch(repository, first, "second")
            }
            #expect(error?.result.gitError == .branchAlreadyExists)

            #expect(try await getBranchOrError(repository, "first").tip.sha == first.tip.sha)
            #expect(try await getBranchOrError(repository, "second").tip.sha == second.tip.sha)
        }

        @Test("doesn't force a case-only rename onto a branch with exactly the new name")
        func caseOnlyOntoExistingBranch() async throws {
            let repository = try await setupTwoCommitRepo()
            let first = try await getRefOrError(repository, "HEAD~1")
            let head = try await getTipOrError(repository)
            // Branches whose names differ only in case exist side by side as
            // packed refs, even on a case-insensitive file system.
            try await createBranch(repository, "Topic", first.sha, noTrack: false)
            _ = try await Dugite.exec(["pack-refs", "--all"], repository.path)
            _ = try await Dugite.exec(["update-ref", "refs/heads/topic", head.sha], repository.path)
            _ = try await Dugite.exec(["pack-refs", "--all"], repository.path)
            let topic = try await getBranchOrError(repository, "Topic")

            // `-M` would replace the other branch.
            let error = await #expect(throws: GitError.self) {
                try await renameBranch(repository, topic, "topic")
            }
            #expect(error?.result.gitError == .branchAlreadyExists)

            #expect(try await getBranchOrError(repository, "Topic").tip.sha == first.sha)
            #expect(try await getBranchOrError(repository, "topic").tip.sha == head.sha)
        }

        @Test("forces a rename when asked to")
        func forced() async throws {
            let repository = try await setupTwoCommitRepo()
            let first = try await getRefOrError(repository, "HEAD~1")
            try await createBranch(repository, "replacement", first.sha, noTrack: false)
            try await createBranch(repository, "replaced", nil)
            let replacement = try await getBranchOrError(repository, "replacement")

            try await renameBranch(repository, replacement, "replaced", force: true)

            #expect(try await getBranches(repository, "refs/heads/replacement").isEmpty)
            #expect(try await getBranchOrError(repository, "replaced").tip.sha == first.sha)
        }

        // Only a case-insensitive file system refuses a case-only rename.
        @Test(
            "doesn't retry a case-only rename when told not to force it",
            .enabled(if: temporaryVolumeIsCaseInsensitive(), "a case-sensitive volume allows any case-only rename")
        )
        func explicitlyNotForced() async throws {
            let repository = try await setupTwoCommitRepo()
            try await createBranch(repository, "Mixed", nil)
            let mixed = try await getBranchOrError(repository, "Mixed")

            await #expect(throws: GitError.self) {
                try await renameBranch(repository, mixed, "mixed", force: false)
            }
            #expect(try await getBranchNames(repository).contains("Mixed"))
        }
    }

    @Suite("deleteLocalBranch failures")
    struct DeleteLocalBranchFailures {
        @Test("refuses to delete the current branch")
        func currentBranch() async throws {
            let repository = try await setupTwoCommitRepo()
            let head = try await getTipOrError(repository)

            let error = await #expect(throws: GitError.self) {
                try await deleteLocalBranch(repository, "master")
            }
            #expect(error?.message.contains("cannot delete branch 'master'") == true)
            #expect(try await getBranchOrError(repository, "master").tip.sha == head.sha)
            #expect(try await loadTip(repository).kind == .valid)
        }

        @Test("deletes an unmerged branch")
        func unmerged() async throws {
            let repository = try await setupTwoCommitRepo()
            try await createBranch(repository, "unmerged", nil)
            let branch = try await getBranchOrError(repository, "unmerged")
            try await checkoutBranch(repository, branch, nil)
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "only-here", contents: "x")]))
            try await checkoutBranch(repository, try await getBranchOrError(repository, "master"), nil)

            // `-D`: the commits stay reachable from the reflog.
            try await deleteLocalBranch(repository, "unmerged")
            #expect(try await getBranches(repository, "refs/heads/unmerged").isEmpty)
        }
    }

    @Suite("getMergedBranches")
    struct GetMergedBranches {
        @Test("lists the branches merged into a branch, without that branch")
        func merged() async throws {
            let repository = try await setupTwoCommitRepo()
            let first = try await getRefOrError(repository, "HEAD~1")
            let head = try await getTipOrError(repository)
            try await createBranch(repository, "behind", first.sha, noTrack: false)
            try await createBranch(repository, "same", nil)
            try await createBranch(repository, "ahead", nil)
            let ahead = try await getBranchOrError(repository, "ahead")
            try await checkoutBranch(repository, ahead, nil)
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "ahead", contents: "x")]))
            try await checkoutBranch(repository, try await getBranchOrError(repository, "master"), nil)

            let merged = try await getMergedBranches(repository, "master")

            #expect(merged == [
                "refs/heads/behind": first.sha,
                "refs/heads/same": head.sha,
            ])
        }
    }
}
