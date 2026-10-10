// Ported from desktop/app/test/unit/git/pull/only-ahead-test.ts

import GitKit
import Testing
import TestSupport

private let featureBranch = "this-is-a-feature"
private let remote = Remote(name: "origin", url: "file://")
private let remoteBranch = "\(remote.name)/\(featureBranch)"

private func setup(_ pullFFConfig: String? = nil) async throws -> (repository: Repository, previousTip: Commit, newTip: Commit) {
    let remoteRepository = try await createRepository(featureBranch)
    let repository = try await cloneRepository(remoteRepository)

    // add a commit to the local branch so that it is now "ahead"

    let changesForLocalRepository = Tree(
        entries: [
            TreeEntry(path: "CONTRIBUTING.md", contents: "# HELLO WORLD! \nTHINGS GO HERE\nYES, THINGS"),
        ],
        commitMessage: "Added a new file to the local repository"
    )

    try await makeCommit(repository, changesForLocalRepository)
    try await fetch(repository, remote)

    if let pullFFConfig {
        try await setupLocalConfig(repository, [("pull.ff", pullFFConfig)])
    }

    let previousTip = try await getTipOrError(repository)

    try await pull(repository, remote)

    let newTip = try await getTipOrError(repository)

    return (repository, previousTip, newTip)
}

// Each suite is one test that sets the repository up once; a comment names
// the ported test before each of its assertions.
@Suite("git/pull")
struct PullOnlyAheadTests {
    @Suite("only ahead of tracking branch")
    struct OnlyAhead {
        @Suite("by default")
        struct ByDefault {
            @Test("leaves the branch ahead of its tracking branch")
            func pulls() async throws {
                let (repository, previousTip, newTip) = try await setup()

                // does not create new commit
                #expect(newTip.sha == previousTip.sha)

                // is different from tracking branch
                let remoteCommit = try await getRefOrError(repository, remoteBranch)
                #expect(remoteCommit.sha != newTip.sha)

                // remains ahead of tracking branch
                let range = revSymmetricDifference(featureBranch, remoteBranch)
                let aheadBehind = try await getAheadBehind(repository, range)
                #expect(aheadBehind == AheadBehind(ahead: 1, behind: 0))
            }
        }

        @Suite("with pull.ff=false set in config")
        struct NoFastForward {
            @Test("leaves the branch ahead of its tracking branch")
            func pulls() async throws {
                let (repository, previousTip, newTip) = try await setup("false")

                // does not create new commit
                #expect(newTip.sha == previousTip.sha)

                // is different to tracking branch
                let remoteCommit = try await getRefOrError(repository, remoteBranch)
                #expect(remoteCommit.sha != newTip.sha)

                // is ahead of tracking branch
                let range = revSymmetricDifference(featureBranch, remoteBranch)
                let aheadBehind = try await getAheadBehind(repository, range)
                #expect(aheadBehind == AheadBehind(ahead: 1, behind: 0))
            }
        }

        @Suite("with pull.ff=only set in config")
        struct FastForwardOnly {
            @Test("leaves the branch ahead of its tracking branch")
            func pulls() async throws {
                let (repository, previousTip, newTip) = try await setup("only")

                // does not create new commit
                #expect(newTip.sha == previousTip.sha)

                // is different from tracking branch
                let remoteCommit = try await getRefOrError(repository, remoteBranch)
                #expect(remoteCommit.sha != newTip.sha)

                // is ahead of tracking branch
                let range = revSymmetricDifference(featureBranch, remoteBranch)
                let aheadBehind = try await getAheadBehind(repository, range)
                #expect(aheadBehind == AheadBehind(ahead: 1, behind: 0))
            }
        }
    }
}
