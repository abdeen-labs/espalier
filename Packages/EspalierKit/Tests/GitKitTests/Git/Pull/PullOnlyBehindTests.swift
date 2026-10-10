// Ported from desktop/app/test/unit/git/pull/only-behind-test.ts

import GitKit
import Testing
import TestSupport

private let featureBranch = "this-is-a-feature"
private let remote = Remote(name: "origin", url: "file://")
private let remoteBranch = "\(remote.name)/\(featureBranch)"

private func setup(_ config: [(String, String)]? = nil) async throws -> (repository: Repository, previousTip: Commit, newTip: Commit) {
    let remoteRepository = try await createRepository(featureBranch)
    let repository = try await cloneRepository(remoteRepository)

    // make commits to remote is ahead of local repository

    let firstCommit = Tree(
        entries: [
            TreeEntry(path: "README.md", contents: "# HELLO WORLD! \n WORDS GO HERE! \nLOL"),
        ],
        commitMessage: "Changed a file in the remote repository"
    )

    let secondCommit = Tree(
        entries: [
            TreeEntry(path: "CONTRIBUTING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nYES, THINGS"),
        ],
        commitMessage: "Added a new file to the remote repository"
    )

    try await makeCommit(remoteRepository, firstCommit)
    try await makeCommit(remoteRepository, secondCommit)

    try await fetch(repository, remote)

    if let config {
        try await setupLocalConfig(repository, config)
    }

    let previousTip = try await getTipOrError(repository)

    try await pull(repository, remote)

    let newTip = try await getTipOrError(repository)

    return (repository, previousTip, newTip)
}

// Each suite is one test that sets the repository up once; a comment names
// the ported test before each of its assertions.
@Suite("git/pull")
struct PullOnlyBehindTests {
    @Suite("only behind tracking branch")
    struct OnlyBehind {
        @Suite("with pull.rebase=false and pull.ff=false set in config")
        struct NoRebaseNoFastForward {
            @Test("merges the tracking branch")
            func pulls() async throws {
                let (repository, previousTip, newTip) = try await setup([("pull.rebase", "false"), ("pull.ff", "false")])

                // creates a merge commit
                #expect(newTip.sha != previousTip.sha)
                #expect(newTip.parentSHAs.count == 2)

                // is different from remote branch
                let remoteCommit = try await getRefOrError(repository, remoteBranch)
                #expect(remoteCommit.sha != newTip.sha)

                // is now ahead of tracking branch
                let range = revSymmetricDifference(featureBranch, remoteBranch)
                let aheadBehind = try await getAheadBehind(repository, range)
                #expect(aheadBehind == AheadBehind(ahead: 1, behind: 0))
            }
        }

        @Suite("with pull.ff=only set in config")
        struct FastForwardOnly {
            @Test("fast-forwards to the tracking branch")
            func pulls() async throws {
                let (repository, previousTip, newTip) = try await setup([("pull.ff", "only")])

                // does not create a merge commit
                #expect(newTip.sha != previousTip.sha)
                #expect(newTip.parentSHAs.count == 1)

                // is same as remote branch
                let remoteCommit = try await getRefOrError(repository, remoteBranch)
                #expect(remoteCommit.sha == newTip.sha)

                // is not behind tracking branch
                let range = revSymmetricDifference(featureBranch, remoteBranch)
                let aheadBehind = try await getAheadBehind(repository, range)
                #expect(aheadBehind == AheadBehind(ahead: 0, behind: 0))
            }
        }
    }
}
