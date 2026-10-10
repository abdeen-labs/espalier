// Ported from desktop/app/test/unit/git/pull/ahead-and-behind-test.ts

import GitKit
import Testing
import TestSupport

private let featureBranch = "this-is-a-feature"
private let remote = Remote(name: "origin", url: "file://")
private let remoteBranch = "\(remote.name)/\(featureBranch)"

private func setup() async throws -> Repository {
    let remoteRepository = try await createRepository(featureBranch)
    let repository = try await cloneRepository(remoteRepository)

    // make a commits to both remote and local so histories diverge

    let changesForRemoteRepository = Tree(
        entries: [
            TreeEntry(path: "README.md", contents: "# HELLO WORLD! \n WORDS GO HERE! \nLOL"),
        ],
        commitMessage: "Changed a file in the remote repository"
    )

    try await makeCommit(remoteRepository, changesForRemoteRepository)

    let changesForLocalRepository = Tree(
        entries: [
            TreeEntry(path: "CONTRIBUTING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nYES, THINGS"),
        ],
        commitMessage: "Added a new file to the local repository"
    )

    try await makeCommit(repository, changesForLocalRepository)
    try await fetch(repository, remote)

    return repository
}

/// Sets up the diverged repository with `config`, then pulls.
private func setupConfig(_ config: [(String, String)]) async throws -> (repository: Repository, previousTip: Commit, newTip: Commit) {
    let repository = try await setup()
    try await setupLocalConfig(repository, config)

    let previousTip = try await getTipOrError(repository)

    try await pull(repository, remote)

    let newTip = try await getTipOrError(repository)
    return (repository, previousTip, newTip)
}

// Each suite is one test that sets the repository up once; a comment names
// the ported test before each of its assertions.
@Suite("git/pull")
struct PullAheadAndBehindTests {
    @Suite("ahead and behind of tracking branch")
    struct AheadAndBehind {
        @Suite("with pull.rebase=false and pull.ff=false set in config")
        struct NoRebaseNoFastForward {
            @Test("merges the tracking branch")
            func pulls() async throws {
                let (repository, previousTip, newTip) = try await setupConfig([("pull.rebase", "false"), ("pull.ff", "false")])

                // creates a merge commit
                #expect(newTip.sha != previousTip.sha)
                #expect(newTip.parentSHAs.count == 2)

                // is different from remote branch
                let remoteCommit = try await getRefOrError(repository, remoteBranch)
                #expect(remoteCommit.sha != newTip.sha)

                // is ahead of tracking branch
                let range = revSymmetricDifference(featureBranch, remoteBranch)
                let aheadBehind = try await getAheadBehind(repository, range)
                #expect(aheadBehind == AheadBehind(ahead: 2, behind: 0))
            }
        }

        @Suite("with pull.rebase=false set in config")
        struct NoRebase {
            @Test("merges the tracking branch")
            func pulls() async throws {
                let (repository, previousTip, newTip) = try await setupConfig([("pull.rebase", "false")])

                // creates a merge commit
                #expect(newTip.sha != previousTip.sha)
                #expect(newTip.parentSHAs.count == 2)

                // is ahead of tracking branch
                let range = revSymmetricDifference(featureBranch, remoteBranch)
                let aheadBehind = try await getAheadBehind(repository, range)
                #expect(aheadBehind == AheadBehind(ahead: 2, behind: 0))
            }
        }

        @Suite("with pull.rebase=true set in config")
        struct Rebase {
            @Test("rebases onto the tracking branch")
            func pulls() async throws {
                let (repository, previousTip, newTip) = try await setupConfig([("pull.rebase", "true")])

                // does not create a merge commit
                #expect(newTip.sha != previousTip.sha)
                #expect(newTip.parentSHAs.count == 1)

                // is ahead of tracking branch
                let range = revSymmetricDifference(featureBranch, remoteBranch)
                let aheadBehind = try await getAheadBehind(repository, range)
                #expect(aheadBehind == AheadBehind(ahead: 1, behind: 0))
            }
        }

        @Suite("with pull.rebase=false and pull.ff=only set in config")
        struct FastForwardOnly {
            @Test("throws an error as the user blocks merge commits on pull")
            func throwsError() async throws {
                let repository = try await setup()
                try await setupLocalConfig(repository, [("pull.rebase", "false"), ("pull.ff", "only")])
                await #expect(throws: (any Error).self) {
                    try await pull(repository, remote)
                }
            }
        }
    }
}
