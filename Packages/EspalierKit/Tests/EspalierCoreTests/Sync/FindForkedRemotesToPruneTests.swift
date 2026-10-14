// Ported from desktop/app/test/unit/find-forked-remotes-to-prune-test.ts

@testable import EspalierCore
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

private func createSamplePullRequest(
    _ gitHubRepository: GitHubRepository,
    _ userName: String,
    _ baseBranchName: String
) -> PullRequest {
    PullRequest(
        created: Date(),
        title: "desktop",
        pullRequestNumber: 1,
        head: PullRequestRef(ref: "main", sha: "deadbeef", gitHubRepository: gitHubRepository),
        base: PullRequestRef(ref: baseBranchName, sha: "deadbeef", gitHubRepository: gitHubRepository),
        author: userName,
        draft: false,
        body: "sample body"
    )
}

private func createSampleBranch(_ name: String, _ upstream: String?) -> Branch {
    Branch(name: name, upstream: upstream, tip: BranchTip(sha: "300acef"), type: .local, ref: "")
}

@Suite("findForkedRemotesToPrune")
struct FindForkedRemotesToPruneTests {
    let testUserName = "sergiou87"

    let originRemote = "origin"
    let nonGitHubDesktopRemote = "non-github-desktop-remote"
    let gitHubDesktopRemoteWithLocalBranch = "github-desktop-niik"
    var gitHubDesktopRemoteWithPullRequest: String { "github-desktop-\(testUserName)" }

    var remotes: [Remote] {
        [
            Remote(name: originRemote, url: "https://github.com/desktop/desktop.git"),
            Remote(name: nonGitHubDesktopRemote, url: "https://github.com/fakeuser/desktop.git"),
            Remote(name: gitHubDesktopRemoteWithLocalBranch, url: "https://github.com/niik/desktop.git"),
            Remote(name: gitHubDesktopRemoteWithPullRequest, url: "https://github.com/\(testUserName)/desktop.git"),
        ]
    }

    /// The remotes the app added: marked in the repository's configuration.
    var forkRemoteNames: Set<ExactString> {
        [gitHubDesktopRemoteWithLocalBranch, gitHubDesktopRemoteWithPullRequest].exactSet
    }

    private func getNamesFromRemotes(_ remotes: [Remote]) -> [String] {
        remotes.map(\.name)
    }

    @Test("never prunes remotes not created by the app")
    func neverPrunesOtherRemotes() {
        let remotesToPrune = findForkedRemotesToPrune(remotes, forkRemoteNames: forkRemoteNames, [], [])

        let names = getNamesFromRemotes(remotesToPrune)
        #expect(!names.isEmpty, "Expected the app's remotes to be pruned")
        #expect(!names.contains(originRemote))
        #expect(!names.contains(nonGitHubDesktopRemote))
    }

    @Test("never prunes remotes with local branches")
    func neverPrunesRemotesWithLocalBranches() {
        let allBranches = [
            createSampleBranch("app-store-refactor", "\(gitHubDesktopRemoteWithLocalBranch)/app-store-refactor"),
        ]

        let remotesToPrune = findForkedRemotesToPrune(remotes, forkRemoteNames: forkRemoteNames, [], allBranches)

        #expect(!getNamesFromRemotes(remotesToPrune).contains(gitHubDesktopRemoteWithLocalBranch))
    }

    @Test("never prunes remotes with pull requests")
    func neverPrunesRemotesWithPullRequests() {
        let forkRepository = gitHubRepoFixture(owner: testUserName, name: "desktop")
        let openPRs = [
            createSamplePullRequest(forkRepository, testUserName, "my-cool-feature"),
        ]

        let remotesToPrune = findForkedRemotesToPrune(remotes, forkRemoteNames: forkRemoteNames, openPRs, [])

        #expect(!getNamesFromRemotes(remotesToPrune).contains(gitHubDesktopRemoteWithPullRequest))
    }

    @Test("prunes remotes without pull requests or local branches")
    func prunesUnusedRemotes() {
        let remotesToPrune = findForkedRemotesToPrune(remotes, forkRemoteNames: forkRemoteNames, [], [])

        let remoteNames = getNamesFromRemotes(remotesToPrune)
        #expect(remoteNames.contains(gitHubDesktopRemoteWithPullRequest))
        #expect(remoteNames.contains(gitHubDesktopRemoteWithLocalBranch))
    }

    // MARK: - Espalier

    @Test("prunes only the remotes the app marked, whatever their names")
    func prunesOnlyMarkedRemotes() {
        let remotes = [
            Remote(name: "espalier-mirror", url: "https://github.com/mirror/desktop.git"),
            Remote(name: "github-desktop-old", url: "https://github.com/old/desktop.git"),
            Remote(name: "espalier-unused", url: "https://github.com/unused/desktop.git"),
            Remote(name: "renamed-fork", url: "https://github.com/renamed/desktop.git"),
        ]
        let marked = ["espalier-unused", "renamed-fork"].exactSet

        #expect(getNamesFromRemotes(findForkedRemotesToPrune(remotes, forkRemoteNames: marked, [], [])) == ["espalier-unused", "renamed-fork"])
    }
}
