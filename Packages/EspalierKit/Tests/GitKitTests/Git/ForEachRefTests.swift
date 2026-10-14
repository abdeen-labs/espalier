// Ported from desktop/app/test/unit/git/for-each-ref-test.ts

import Foundation
import GitKit
import Testing
import TestSupport

@Suite("git/for-each-ref")
struct ForEachRefTests {
    @Suite("getBranches")
    struct GetBranches {
        @Test("fetches branches using for-each-ref")
        func fetchesBranches() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-many-refs")
            let repository = Repository(path: testRepoPath)

            let branches = try await getBranches(repository).filter { $0.type == .local }

            #expect(branches.count == 3)
            try #require(branches.count == 3)

            let commitWithBody = branches[0]
            #expect(commitWithBody.name == "commit-with-long-description")
            #expect(commitWithBody.upstream == nil)
            #expect(commitWithBody.tip.sha == "dfa96676b65e1c0ed43ca25492252a5e384c8efd")

            let commitNoBody = branches[1]
            #expect(commitNoBody.name == "commit-with-no-body")
            #expect(commitNoBody.upstream == nil)
            #expect(commitNoBody.tip.sha == "49ec1e05f39eef8d1ab6200331a028fb3dd96828")

            let master = branches[2]
            #expect(master.name == "master")
            #expect(master.upstream == nil)
            #expect(master.tip.sha == "b9ccfc3307240b86447bca2bd6c51a4bb4ade493")
        }

        @Test("finds the remote of an upstream and of a remote branch when the remote's name has a slash")
        func remoteNameWithSlash() async throws {
            let repository = try await setupTwoCommitRepo()
            let remote = try setupEmptyDirectory()
            _ = try await git(["init", "-q", "--bare"], remote.path, "remoteNameWithSlash")
            _ = try await git(["remote", "add", "team/alice", remote.path], repository.path, "remoteNameWithSlash")
            _ = try await git(["push", "-q", "-u", "team/alice", "master"], repository.path, "remoteNameWithSlash")

            let branches = try await getBranches(repository)
            let master = try #require(branches.first { $0.ref == "refs/heads/master" })
            #expect(master.upstream == "team/alice/master")
            #expect(master.upstreamRemoteName == "team/alice")
            #expect(master.upstreamWithoutRemote == "master")

            let remoteMaster = try #require(branches.first { $0.ref == "refs/remotes/team/alice/master" })
            #expect(try remoteMaster.remoteName == "team/alice")
            #expect(remoteMaster.nameWithoutRemote == "master")
        }

        @Test("should return empty list for empty repo")
        func emptyListForEmptyRepo() async throws {
            let repo = try setupEmptyRepository()
            let branches = try await getBranches(repo)
            #expect(branches.isEmpty)
        }

        @Test("should return empty list for directory without a .git directory")
        func emptyListForDirectoryWithoutGit() async throws {
            let repo = try setupEmptyDirectory()
            let status = try await getBranches(repo)
            #expect(status.isEmpty)
        }
    }

    @Suite("getBranchesDifferingFromUpstream")
    struct GetBranchesDifferingFromUpstream {
        @Test("filters branches differing from upstream using for-each-ref")
        func filtersBranchesDifferingFromUpstream() async throws {
            let testRepoPath = try setupFixtureRepository("repo-with-non-updated-branches")
            let repository = Repository(path: testRepoPath)

            let branches = try await getBranchesDifferingFromUpstream(repository)

            let branchRefs = branches.map(\.ref)
            #expect(branchRefs.count == 3)

            // All branches that are behind and/or ahead must be included
            #expect(branchRefs.contains("refs/heads/branch-behind"))
            #expect(branchRefs.contains("refs/heads/branch-ahead"))
            #expect(branchRefs.contains("refs/heads/branch-ahead-and-behind"))

            // `main` is the current branch, and shouldn't be included
            #expect(!branchRefs.contains("refs/heads/main"))

            // Branches that are up to date shouldn't be included
            #expect(!branchRefs.contains("refs/heads/branch-up-to-date"))
        }
    }
}
