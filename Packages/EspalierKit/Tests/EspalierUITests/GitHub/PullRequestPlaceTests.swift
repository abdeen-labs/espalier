// The pull request's place loads from the models: the checks GitHub reports
// (a workflow's jobs and a commit status), and its changes, which aren't
// available when the pull request's head isn't in the repository, or its
// files with the first one selected when it is. The toolbar search filters
// the files, and a file's menu views it on GitHub at the pull request's
// head. GitHub is a mock.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Pull request place", .offline, .hangGuard(minutes: 5)) @MainActor
struct PullRequestPlaceTests {
    /// Loads the pull request's checks, as the place's `.task` does, and its
    /// changes, and checks that the checks loaded.
    private func loadPlace(_ fixture: GitHubWindowFixture, _ pullRequest: PullRequest) async {
        let gitHub = fixture.model.gitHub
        let subscription = gitHub.commitStatuses.subscribe(CheckRunsKey(pullRequest), branchName: pullRequest.head.ref)
        let changes = fixture.model.history.pullRequestChanges
        await changes.showChanges(of: pullRequest)
        await changes.idle()
        await fixture.settle()
        #expect(gitHub.hasLoadedChecks(for: pullRequest, branchName: pullRequest.head.ref))
        #expect(gitHub.checks(for: pullRequest)?.checks.count == 3)
        subscription.cancel()
        await fixture.settle()
    }

    @Test("a pull request whose head isn't in the repository: its checks load, and its changes aren't available")
    func changesNotAvailable() async throws {
        let fixture = try await GitHubWindowFixture.make(pullRequests: [
            apiPullRequest(5, title: "Add the sign-in sheet", head: "feature/sign-in"),
        ])
        GitHubFixtures.mockChecks(fixture.harness.gitHub)
        let pullRequest = try #require(fixture.model.gitHub.openPullRequests.first)
        await loadPlace(fixture, pullRequest)
        #expect(fixture.model.history.pullRequestChanges.status == .changesNotAvailable)
    }

    @Test("a pull request whose head is in the repository: its checks and its files load, the first file selected")
    func filesAndDiff() async throws {
        let fixture = try await GitHubWindowFixture.make(prepare: pushFeature)
        let head = JSCompat.trim(try await runGit(["rev-parse", "origin/feature"], fixture.local))
        fixture.pulls.pullRequests = [apiPullRequest(5, title: "Add a feature", head: "feature", headSHA: head)]
        await fixture.model.gitHub.refreshPullRequests()
        await fixture.settle()
        GitHubFixtures.mockChecks(fixture.harness.gitHub)
        let pullRequest = try #require(fixture.model.gitHub.openPullRequests.first)
        await loadPlace(fixture, pullRequest)
        let changes = fixture.model.history.pullRequestChanges
        #expect(changes.status == .loaded)
        #expect(changes.selection.changeset.value?.files.map(\.path) == ["feature.txt"])
        #expect(changes.selection.file?.path == "feature.txt")
    }

    @Test("the toolbar search filters a pull request's files, ignoring case: none when nothing matches")
    func noMatchingFiles() async throws {
        let fixture = try await GitHubWindowFixture.make(prepare: pushFeature)
        let head = JSCompat.trim(try await runGit(["rev-parse", "origin/feature"], fixture.local))
        fixture.pulls.pullRequests = [apiPullRequest(5, title: "Add a feature", head: "feature", headSHA: head)]
        await fixture.model.gitHub.refreshPullRequests()
        await fixture.settle()
        GitHubFixtures.mockChecks(fixture.harness.gitHub)
        let pullRequest = try #require(fixture.model.gitHub.openPullRequests.first)
        await loadPlace(fixture, pullRequest)
        let files = try #require(fixture.model.history.pullRequestChanges.selection.changeset.value?.files)
        #expect(ChangedFilesList.files(files, filter: "readme").isEmpty)
        #expect(ChangedFilesList.files(files, filter: "FEATURE").map(\.path) == ["feature.txt"])
    }

    @Test("a pull request's file menu views the file on GitHub at the pull request's head, and only for its own changes")
    func fileMenu() async throws {
        let fixture = try await GitHubWindowFixture.make(prepare: pushFeature)
        let head = JSCompat.trim(try await runGit(["rev-parse", "origin/feature"], fixture.local))
        fixture.pulls.pullRequests = [apiPullRequest(5, title: "Add a feature", head: "feature", headSHA: head)]
        await fixture.model.gitHub.refreshPullRequests()
        await fixture.settle()
        let pullRequest = try #require(fixture.model.gitHub.openPullRequests.first)
        let changes = fixture.model.history.pullRequestChanges
        await changes.showChanges(of: pullRequest)
        await changes.idle()
        await fixture.settle()
        #expect(changes.status == .loaded)

        // A file's menu views it on GitHub at the pull request's head, in
        // its base repository; the file isn't on disk on `main`.
        let file = try #require(changes.selection.changeset.value?.files.first)
        let menu = PullRequestFileMenus.pullRequest(file, pullRequest, changes: changes, repositoryPath: fixture.model.record.path)
        #expect(menu.gitHubURL?.absoluteString.hasPrefix("https://github.com/octocat/hello/commit/\(head)#diff-") == true)
        #expect(menu.relativePath == "feature.txt")
        #expect(menu.fullPath == POSIXPath.join(fixture.model.record.path, "feature.txt"))
        #expect(!menu.existsOnDisk)
        // Another pull request's changes: nothing to view yet.
        let other = PullRequest(
            created: pullRequest.created, title: pullRequest.title, pullRequestNumber: 6, head: pullRequest.head,
            base: pullRequest.base, author: pullRequest.author, draft: pullRequest.draft, body: pullRequest.body
        )
        #expect(PullRequestFileMenus.pullRequest(file, other, changes: changes, repositoryPath: fixture.model.record.path).gitHubURL == nil)
        await fixture.settle()
    }
}
