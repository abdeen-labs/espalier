// The default branch's order of preference against real repositories.

@testable import EspalierCore
import GitKit
import TestSupport
import Testing

@Suite("findDefaultBranch")
struct FindDefaultBranchTests {
    /// A clone of a two-commit repository: `origin/HEAD` is `origin/master`,
    /// and `master` tracks `origin/master`.
    private func makeClone() async throws -> Repository {
        try await cloneRepository(try await setupTwoCommitRepo())
    }

    private func run(_ repository: Repository, _ args: [String]) async throws {
        _ = try await git(args, repository.path, "findDefaultBranchTest")
    }

    private func findDefault(_ record: RepositoryRecord, defaultRemote: String? = "origin") async throws -> Branch? {
        try await findDefaultBranch(record, try await getBranches(record.gitRepository), defaultRemote)
    }

    @Test("prefers the local branch named like the default branch, without an upstream, to another branch tracking the remote's")
    func namedBranchFirst() async throws {
        let clone = try await makeClone()
        try await run(clone, ["branch", "--unset-upstream", "master"])
        // A branch made from the remote's default branch tracks it.
        try await run(clone, ["branch", "--track", "feature", "origin/master"])

        let branch = try #require(try await findDefault(RepositoryRecord(path: clone.path)))
        #expect(branch.name == "master")
        #expect(branch.upstream == nil)
    }

    @Test("without a local branch named like the default branch, prefers one tracking the remote's default branch")
    func trackingBranch() async throws {
        let clone = try await makeClone()
        try await run(clone, ["checkout", "-b", "tracker", "--track", "origin/master"])
        try await run(clone, ["branch", "-D", "master"])

        let branch = try #require(try await findDefault(RepositoryRecord(path: clone.path)))
        #expect(branch.name == "tracker")
        #expect(branch.type == .local)
    }

    @Test("among tracking branches, prefers the one named like the default branch")
    func trackingBranchWithTheName() async throws {
        let clone = try await makeClone()
        // `aaa` comes first in the list and tracks the default branch too.
        try await run(clone, ["branch", "--track", "aaa", "origin/master"])

        let branch = try #require(try await findDefault(RepositoryRecord(path: clone.path)))
        #expect(branch.name == "master")
        #expect(branch.upstream == "origin/master")
    }

    @Test("falls back to the local branch named like the default branch")
    func localBranchWithTheName() async throws {
        let clone = try await makeClone()
        try await run(clone, ["branch", "--unset-upstream", "master"])

        let branch = try #require(try await findDefault(RepositoryRecord(path: clone.path)))
        #expect(branch.name == "master")
        #expect(branch.upstream == nil)
    }

    @Test("falls back to the remote branch when no local branch matches")
    func remoteBranch() async throws {
        let clone = try await makeClone()
        try await run(clone, ["checkout", "-b", "other"])
        try await run(clone, ["branch", "-D", "master"])

        let branch = try #require(try await findDefault(RepositoryRecord(path: clone.path)))
        #expect(branch.name == "origin/master")
        #expect(branch.type == .remote)
    }

    @Test("without a remote HEAD, uses init.defaultBranch, else main")
    func configuredDefaultBranch() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await setupTwoCommitRepo()
            try await run(repository, ["branch", "trunk"])
            try await run(repository, ["branch", "main"])
            let record = RepositoryRecord(path: repository.path)

            #expect(try await findDefault(record, defaultRemote: nil)?.name == "main")

            try await setGlobalConfigValue("init.defaultBranch", "trunk")
            #expect(try await findDefault(record, defaultRemote: nil)?.name == "trunk")
            // A remote without a HEAD also falls back, and so does an empty
            // remote name.
            #expect(try await findDefault(record, defaultRemote: "origin")?.name == "trunk")
            #expect(try await findDefault(record, defaultRemote: "")?.name == "trunk")
        }
    }

    @Test("finds nothing when no branch matches")
    func nothingMatches() async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try await setupTwoCommitRepo()
            let record = RepositoryRecord(path: repository.path)
            // The only branch is `master`, and the default is `main`.
            #expect(try await findDefault(record, defaultRemote: nil) == nil)
        }
    }

    @Test("a fork contributing to its parent uses the upstream remote's default branch")
    func forkUsesUpstream() async throws {
        let clone = try await makeClone()
        let parentRepository = try setupEmptyRepository("develop")
        try await makeCommit(parentRepository, Tree(entries: [TreeEntry(path: "README.md", contents: "parent")]))

        try await run(clone, ["remote", "add", "upstream", parentRepository.path])
        try await run(clone, ["fetch", "upstream"])
        try await run(clone, ["remote", "set-head", "upstream", "--auto"])
        try await run(clone, ["branch", "--track", "develop", "upstream/develop"])

        let parent = gitHubRepoFixture(owner: "desktop", name: "desktop")
        var record = RepositoryRecord(
            path: clone.path,
            gitHubRepository: gitHubRepoFixture(owner: "contributor", name: "desktop", parent: parent)
        )
        #expect(try await findDefault(record)?.name == "develop")

        // Contributing to the fork itself: origin's default branch.
        record.workflowPreferences.forkContributionTarget = .fork
        #expect(try await findDefault(record)?.name == "master")
    }
}
