// The pull request's place built from the models. The overview shows the
// checks GitHub reports (a workflow's jobs with their steps, and a commit
// status) and the description; beside it, "Changes Not Available" when the
// pull request's head isn't in the repository (in light), or its files and
// the first file's diff when it is (in light and dark), and a file's menu
// views it on GitHub at the pull request's head. GitHub is a mock.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Pull request place", .offline, .hangGuard(minutes: 5)) @MainActor
struct PullRequestPlaceTests {
    private let area = "GitHub"

    private static let body = """
        Adds the **sign-in sheet** with the device flow.

        - Copy Code copies the code
        - The code expires after 15 minutes
        """

    /// The place's overview and changes, side by side as its split shows
    /// them (the split itself remembers its divider between runs).
    private func image(_ fixture: GitHubWindowFixture, _ pullRequest: PullRequest, appearance: SnapshotAppearance) -> NSBitmapImageRep {
        let panes = HStack(spacing: 0) {
            PullRequestOverview(repository: fixture.model, pullRequest: pullRequest)
                .frame(width: 440)
            Divider()
            PullRequestChangesView(repository: fixture.model, pullRequest: pullRequest)
        }
        .environment(\.historySplitAutosavePrefix, "EspalierTests.\(UUID().uuidString)")
        // The diff's rows and the description are built off the main actor;
        // a snapshot needs them now.
        .environment(\.diffBuildsSynchronously, true)
        .environment(\.markdownParsesSynchronously, true)
        return Snapshot.render(panes.windowEnvironment(fixture.context), size: CGSize(width: 1_100, height: 620), appearance: appearance)
    }

    /// Loads the pull request's checks (as the place's `.task` would, which
    /// doesn't run offscreen) and its changes, and renders the place in
    /// `appearances` as `name`.
    private func assertPlace(
        _ fixture: GitHubWindowFixture,
        _ pullRequest: PullRequest,
        named name: String,
        appearances: [SnapshotAppearance] = SnapshotAppearance.allCases
    ) async {
        let gitHub = fixture.model.gitHub
        let subscription = gitHub.commitStatuses.subscribe(CheckRunsKey(pullRequest), branchName: pullRequest.head.ref)
        let changes = fixture.model.history.pullRequestChanges
        await changes.showChanges(of: pullRequest)
        await changes.idle()
        await fixture.settle()
        #expect(gitHub.hasLoadedChecks(for: pullRequest, branchName: pullRequest.head.ref))
        #expect(gitHub.checks(for: pullRequest)?.checks.count == 3)
        for appearance in appearances {
            assertSnapshot(image(fixture, pullRequest, appearance: appearance), named: name, area: area, appearance: appearance)
        }
        subscription.cancel()
        await fixture.settle()
    }

    @Test("a pull request whose head isn't in the repository: Changes Not Available beside its overview")
    func changesNotAvailable() async throws {
        let fixture = try await GitHubWindowFixture.make(pullRequests: [
            apiPullRequest(5, title: "Add the sign-in sheet", head: "feature/sign-in", body: Self.body),
        ])
        GitHubFixtures.mockChecks(fixture.harness.gitHub)
        let pullRequest = try #require(fixture.model.gitHub.openPullRequests.first)
        await assertPlace(fixture, pullRequest, named: "place-changesNotAvailable", appearances: [.light])
        #expect(fixture.model.history.pullRequestChanges.status == .changesNotAvailable)
    }

    @Test("a pull request whose head is in the repository: its files and the first file's diff beside its overview")
    func filesAndDiff() async throws {
        let fixture = try await GitHubWindowFixture.make(prepare: pushFeature)
        let head = JSCompat.trim(try await runGit(["rev-parse", "origin/feature"], fixture.local))
        fixture.pulls.pullRequests = [apiPullRequest(5, title: "Add a feature", head: "feature", headSHA: head, body: Self.body)]
        await fixture.model.gitHub.refreshPullRequests()
        await fixture.settle()
        GitHubFixtures.mockChecks(fixture.harness.gitHub)
        let pullRequest = try #require(fixture.model.gitHub.openPullRequests.first)
        await assertPlace(fixture, pullRequest, named: "place-filesAndDiff")
        let changes = fixture.model.history.pullRequestChanges
        #expect(changes.status == .loaded)
        #expect(changes.selection.changeset.value?.files.map(\.path) == ["feature.txt"])
        #expect(changes.selection.file?.path == "feature.txt")
    }

    @Test("the toolbar search filters a pull request's files: No Matching Files when none match")
    func noMatchingFiles() async throws {
        let fixture = try await GitHubWindowFixture.make(prepare: pushFeature)
        let head = JSCompat.trim(try await runGit(["rev-parse", "origin/feature"], fixture.local))
        fixture.pulls.pullRequests = [apiPullRequest(5, title: "Add a feature", head: "feature", headSHA: head, body: Self.body)]
        await fixture.model.gitHub.refreshPullRequests()
        await fixture.settle()
        GitHubFixtures.mockChecks(fixture.harness.gitHub)
        let pullRequest = try #require(fixture.model.gitHub.openPullRequests.first)
        fixture.context.state.searchText = "readme"
        await assertPlace(fixture, pullRequest, named: "place-noMatchingFiles")
        let files = try #require(fixture.model.history.pullRequestChanges.selection.changeset.value?.files)
        #expect(ChangedFilesList.files(files, filter: "readme").isEmpty)
        #expect(ChangedFilesList.files(files, filter: "FEATURE").map(\.path) == ["feature.txt"])
    }

    @Test("a pull request's file menu views the file on GitHub at the pull request's head, and only for its own changes")
    func fileMenu() async throws {
        let fixture = try await GitHubWindowFixture.make(prepare: pushFeature)
        let head = JSCompat.trim(try await runGit(["rev-parse", "origin/feature"], fixture.local))
        fixture.pulls.pullRequests = [apiPullRequest(5, title: "Add a feature", head: "feature", headSHA: head, body: Self.body)]
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
        #expect(menu.gitHubTitle == "View on GitHub")
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
