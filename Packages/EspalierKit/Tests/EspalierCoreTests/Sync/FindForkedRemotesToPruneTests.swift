// Ported from desktop/app/test/unit/find-forked-remotes-to-prune-test.ts

@testable import EspalierCore
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

    private func getNamesFromRemotes(_ remotes: [Remote]) -> [String] {
        remotes.map(\.name)
    }

    @Test("never prunes remotes not created by the app")
    func neverPrunesOtherRemotes() {
        let remotesToPrune = findForkedRemotesToPrune(remotes, [], [])

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

        let remotesToPrune = findForkedRemotesToPrune(remotes, [], allBranches)

        #expect(!getNamesFromRemotes(remotesToPrune).contains(gitHubDesktopRemoteWithLocalBranch))
    }

    @Test("never prunes remotes with pull requests")
    func neverPrunesRemotesWithPullRequests() {
        let forkRepository = gitHubRepoFixture(owner: testUserName, name: "desktop")
        let openPRs = [
            createSamplePullRequest(forkRepository, testUserName, "my-cool-feature"),
        ]

        let remotesToPrune = findForkedRemotesToPrune(remotes, openPRs, [])

        #expect(!getNamesFromRemotes(remotesToPrune).contains(gitHubDesktopRemoteWithPullRequest))
    }

    @Test("prunes remotes without pull requests or local branches")
    func prunesUnusedRemotes() {
        let remotesToPrune = findForkedRemotesToPrune(remotes, [], [])

        let remoteNames = getNamesFromRemotes(remotesToPrune)
        #expect(remoteNames.contains(gitHubDesktopRemoteWithPullRequest))
        #expect(remoteNames.contains(gitHubDesktopRemoteWithLocalBranch))
    }

    // MARK: - Espalier

    @Test("prunes Espalier's espalier- fork remotes like desktop's")
    func prunesEspalierRemotes() throws {
        let forkRepository = gitHubRepoFixture(owner: "mona", name: "desktop")
        let remotes = [
            Remote(name: "espalier-unused", url: "https://github.com/unused/desktop.git"),
            Remote(name: "espalier-mona", url: try #require(forkRepository.cloneURL)),
            Remote(name: "espalier-tracked", url: "https://github.com/tracked/desktop.git"),
            Remote(name: "espalier", url: "https://github.com/espalier/desktop.git"),
        ]
        let openPRs = [createSamplePullRequest(forkRepository, "mona", "main")]
        let branches = [createSampleBranch("topic", "espalier-tracked/topic")]

        #expect(getNamesFromRemotes(findForkedRemotesToPrune(remotes, openPRs, branches)) == ["espalier-unused"])
    }
}
