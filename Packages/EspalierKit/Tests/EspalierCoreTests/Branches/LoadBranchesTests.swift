// Ported from desktop/app/test/unit/git-store-test.ts
// The loadBranches cases, run against the refresher's
// `loadBranches(_:record:defaultRemoteName:)`.

@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import Testing
import TestSupport

@Suite("GitStore")
struct LoadBranchesTests {
    @Suite("loadBranches")
    struct LoadBranches {
        struct Repositories {
            let upstream: Repository
            let repository: Repository
        }

        func setupRepositories() async throws -> Repositories {
            let upstream = try setupEmptyRepository()
            try await makeCommit(upstream, Tree(
                entries: [TreeEntry(path: "README.md", contents: "some words go here")],
                commitMessage: "first commit"
            ))
            try await makeCommit(upstream, Tree(
                entries: [TreeEntry(path: "README.md", contents: "some words go here\nand some more words")],
                commitMessage: "second commit"
            ))
            try await switchTo(upstream, "some-other-branch")
            try await makeCommit(upstream, Tree(
                entries: [TreeEntry(path: "README.md", contents: "changing some words")],
                commitMessage: "branch commit"
            ))
            try await makeCommit(upstream, Tree(
                entries: [TreeEntry(path: "README.md", contents: "and even more changing of words")],
                commitMessage: "second branch commit"
            ))

            // move this repository back to `master` before cloning
            try await switchTo(upstream, "master")

            let repository = try await cloneLocalRepository(upstream)

            return Repositories(upstream: upstream, repository: repository)
        }

        func load(_ repository: Repository) async throws -> BranchesSnapshot {
            let remotes = try await getRemotes(repository)
            let record = ModelFixtures.record(path: repository.path)
            return try #require(await loadBranches(repository, record: record, defaultRemoteName: findDefaultRemote(remotes)?.name))
        }

        @Test("will merge a local and remote branch when tracking branch set")
        func mergesLocalAndRemote() async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try await setupRepositories().repository
                let branches = try await load(repository)

                #expect(branches.all.count == 2)

                let defaultBranch = try #require(branches.all.first { $0.name == "master" })
                #expect(defaultBranch.upstream == "origin/master")

                let remoteBranch = try #require(branches.all.first { $0.name == "origin/some-other-branch" })
                #expect(remoteBranch.type == .remote)
            }
        }

        @Test("the tracking branch is not cleared when the remote branch is removed")
        func trackingKept() async throws {
            try await withIsolatedGitConfig { _ in
                let repositories = try await setupRepositories()
                let upstream = repositories.upstream
                let repository = repositories.repository
                // checkout the other branch after cloning
                _ = try await Dugite.exec(["checkout", "some-other-branch"], repository.path)

                let before = try await load(repository)
                let currentBranchBefore = try #require(before.all.first { $0.name == "some-other-branch" })
                #expect(currentBranchBefore.upstream == "origin/some-other-branch")

                // delete the ref in the upstream branch
                _ = try await Dugite.exec(["branch", "-D", "some-other-branch"], upstream.path)

                // update the local repository state to remove the remote ref
                _ = try await Dugite.exec(["fetch", "--prune", "--all"], repository.path)
                let after = try await load(repository)

                let currentBranchAfter = try #require(after.all.first { $0.name == "some-other-branch" })

                // ensure the tracking information is unchanged
                #expect(currentBranchAfter.upstream == "origin/some-other-branch")
            }
        }

        @Test("finds the default branch through the remote's HEAD")
        func defaultBranch() async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try await setupRepositories().repository
                let branches = try await load(repository)
                #expect(branches.defaultBranch?.name == "master")
                #expect(branches.defaultBranch?.type == .local)
                #expect(branches.upstreamDefaultBranch == nil)
            }
        }

        @Test("the remote's default branch is the default branch when only a branch of another name tracks it")
        func trackedRemoteDefaultBranch() async throws {
            try await withIsolatedGitConfig { _ in
                let repository = try await setupRepositories().repository
                _ = try await Dugite.exec(["checkout", "-b", "feature", "--track", "origin/master"], repository.path)
                _ = try await Dugite.exec(["branch", "-D", "master"], repository.path)

                let branches = try await load(repository)
                #expect(branches.defaultBranch?.name == "origin/master")
                #expect(branches.defaultBranch?.type == .remote)
            }
        }
    }
}
