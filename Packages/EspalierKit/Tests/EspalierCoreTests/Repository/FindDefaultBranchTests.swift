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
        try await makeClones().clone
    }

    /// The two-commit repository and a clone of it.
    private func makeClones() async throws -> (origin: Repository, clone: Repository) {
        let origin = try await setupTwoCommitRepo()
        return (origin, try await cloneRepository(origin))
    }

    private func run(_ repository: Repository, _ args: [String]) async throws {
        _ = try await git(args, repository.path, "findDefaultBranchTest")
    }

    private func findDefault(_ record: RepositoryRecord, defaultRemote: String? = "origin") async throws -> Branch? {
        try await findDefaultBranch(record, try await getBranches(record.gitRepository), defaultRemote)
    }

    /// Git commands run in the origin, then in the clone, and the default
    /// branch they leave.
    struct RemoteCase: Sendable {
        var origin: [[String]] = []
        var clone: [[String]]
        var expected = "origin/master"
    }

    @Test(
        "the local branch named like the default branch is it, before another branch tracking the remote's",
        arguments: [
            NamedCase("tracking the remote's default branch", [
                ["branch", "--track", "feature", "origin/master"],
            ]),
            NamedCase("without an upstream", [
                ["branch", "--unset-upstream", "master"],
                ["branch", "--track", "feature", "origin/master"],
            ]),
        ]
    )
    func namedBranchFirst(_ setup: NamedCase<[[String]]>) async throws {
        let clone = try await makeClone()
        for args in setup.value {
            try await run(clone, args)
        }

        let branch = try #require(try await findDefault(RepositoryRecord(path: clone.path)))
        #expect(branch.name == "master")
        #expect(branch.type == .local)
    }

    @Test(
        "without a local branch named like the default branch, the remote's default branch is it",
        arguments: [
            NamedCase("when no branch tracks it", RemoteCase(clone: [
                ["checkout", "-b", "other"],
                ["branch", "-D", "master"],
            ])),
            NamedCase("when a branch of another name tracks it", RemoteCase(clone: [
                ["checkout", "-b", "feature", "--track", "origin/master"],
                ["branch", "-D", "master"],
            ])),
            // The remote's default branch was renamed, and the local branch
            // with the old name tracks the new one.
            NamedCase("when the remote's renamed default branch is tracked by the old name", RemoteCase(
                origin: [
                    ["branch", "-m", "master", "main"],
                ],
                clone: [
                    ["fetch", "--prune", "origin"],
                    ["remote", "set-head", "origin", "--auto"],
                    ["branch", "--set-upstream-to", "origin/main", "master"],
                ],
                expected: "origin/main"
            )),
        ]
    )
    func remoteBranch(_ setup: NamedCase<RemoteCase>) async throws {
        let (origin, clone) = try await makeClones()
        for args in setup.value.origin {
            try await run(origin, args)
        }
        for args in setup.value.clone {
            try await run(clone, args)
        }

        let branch = try #require(try await findDefault(RepositoryRecord(path: clone.path)))
        #expect(branch.name == setup.value.expected)
        #expect(branch.type == .remote)
    }

    @Test("without the remote's HEAD, only the local branch with the configured name is the default branch")
    func remoteWithoutHEAD() async throws {
        try await withIsolatedGitConfig { _ in
            let clone = try await makeClone()
            try await run(clone, ["remote", "set-head", "origin", "--delete"])
            try await run(clone, ["branch", "--track", "feature", "origin/master"])
            let record = RepositoryRecord(path: clone.path)

            // `main`, which no branch is named.
            #expect(try await findDefault(record) == nil)

            try await setGlobalConfigValue("init.defaultBranch", "master")
            let branch = try #require(try await findDefault(record))
            #expect(branch.name == "master")
            #expect(branch.type == .local)
        }
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
