// The primary suggestion for real repositories, in order (the stash,
// publishing the repository, publishing the branch, pulling, pushing, a
// pull request), and none before the repository's state has loaded; the
// cards' words and shortcuts, and snapshots.

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

@Suite("Suggestions", .offline) @MainActor
struct SuggestionsTests {
    /// The primary suggestion for the fixture's repository.
    private func primary(_ fixture: ChangesWindowFixture) -> SuggestionsContent.Primary? {
        SuggestionsContent.make(fixture.repository, app: fixture.app, actions: fixture.context.actions).primary
    }

    @Test("the primary suggestion follows the branch, in desktop's order")
    func primaryOrder() async throws {
        try await withIsolatedGitConfig { _ in
            // In sync, on the default branch: nothing to suggest.
            let (local, remote) = try await setupRepositoryWithRemote()
            let fixture = try await ChangesWindowFixture.make(local)
            #expect(primary(fixture) == nil)
            #expect(ChangesDetailKind.make(fixture.repository) == .suggestions)

            // Ahead: push.
            try fixture.write("one.txt", "one\n")
            try await fixture.git(["add", "one.txt"])
            try await fixture.git(["commit", "-m", "One"])
            await fixture.refresh()
            #expect(primary(fixture) == .push(remote: "origin", ahead: 1, tags: 0, isGitHub: false))

            // Behind too: pull comes first.
            try await pushCommitFromAnotherClone(remote, path: "two.txt", contents: "two\n")
            try await fixture.git(["fetch", "origin"])
            await fixture.refresh()
            #expect(primary(fixture) == .pull(branch: "main", remote: "origin", behind: 1, isGitHub: false))

            // A branch without an upstream: publish it.
            try await fixture.git(["checkout", "-q", "-b", "feature"])
            await fixture.refresh()
            #expect(primary(fixture) == .publishBranch(branch: "feature", isGitHub: false))

            // A stash on the branch comes before all of them.
            try fixture.write("wip.txt", "wip\n")
            await fixture.refresh()
            try await fixture.repository.stash.stashAllChanges()
            await fixture.settle()
            #expect(primary(fixture) == .viewStash)
            await fixture.app.idle()
        }
    }

    @Test("a repository without a remote is published; a detached HEAD gets nothing")
    func publishRepository() async throws {
        try await withIsolatedGitConfig { _ in
            let local = try setupEmptyRepository()
            try Data("hello\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "hello.txt")))
            try await runGit(["add", "hello.txt"], local)
            try await runGit(["commit", "-m", "Hello"], local)
            let fixture = try await ChangesWindowFixture.make(local)
            #expect(primary(fixture) == .publishRepository)

            try await fixture.git(["checkout", "-q", "--detach"])
            await fixture.refresh()
            #expect(primary(fixture) == nil)
            await fixture.app.idle()
        }
    }

    @Test("a published GitHub branch without a pull request suggests one, as the user chose")
    func pullRequest() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithRemote()
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            try await runGit(["push", "-q", "-u", "origin", "feature"], local)
            let fixture = try await ChangesWindowFixture.make(local)
            fixture.app.updateRecord(fixture.repository.id) {
                $0.gitHubRepository = ModelFixtures.gitHubRepository(owner: "octo-org", name: "website")
            }
            await fixture.refresh()
            #expect(primary(fixture) == .pullRequest(branch: "feature", choice: .previewPullRequest))
            fixture.app.preferences.pullRequestSuggestedNextAction = .createPullRequest
            #expect(primary(fixture) == .pullRequest(branch: "feature", choice: .createPullRequest))

            // GitHub repositories get the View on GitHub card.
            let content = SuggestionsContent.make(fixture.repository, app: fixture.app, actions: fixture.context.actions)
            #expect(content.isGitHub)
            #expect(content.gitHubCard?.buttonTitle == "View on GitHub")
            await fixture.app.idle()
        }
    }

    @Test("a repository with only its status loaded, as its sidebar indicator leaves it, suggests nothing until selecting it loads the rest")
    func partlyLoadedRepository() async throws {
        try await withIsolatedGitConfig { _ in
            // A commit ahead of its remote: Push, once everything is loaded.
            let (local, _) = try await setupRepositoryWithRemote()
            try Data("one\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "one.txt")))
            try await runGit(["add", "one.txt"], local)
            try await runGit(["commit", "-q", "-m", "One"], local)
            let harness = try AppHarness()
            let listed = await harness.loadedApp()
            let id = try #require(try await listed.addRepositories([local.path]).added.first)
            // Another repository is selected, and launch selects it again.
            let other = try #require(try await listed.addRepositories([try setupEmptyRepository().path]).added.first)
            listed.select(.repository(other))
            await listed.idle()

            // After a relaunch, the indicator refreshes the repository's
            // status (and the refs of its new tip), which shows its branch
            // but none of its remotes.
            let app = await harness.loadedApp()
            app.preferences.hasShownWelcomeFlow = true
            await app.idle()
            #expect(app.selection == .repository(other))
            let repository = try #require(app.repository(id))
            let context = WindowContext(app: app)
            await repository.refresh(.status, reason: .background)
            // The refresh returns once the status lands; the same pass goes
            // on to load the new tip's refs.
            await repository.idle()
            #expect(repository.gitState.tip.branch?.name == "main")
            #expect(repository.gitState.remotes.currentRemote == nil)
            #expect(repository.gitState.loaded == [.status, .refs])
            #expect(SuggestionsContent.make(repository, app: app, actions: context.actions).primary == nil)

            app.select(.repository(id))
            await app.idle()
            #expect(repository.gitState.loaded == .full)
            #expect(SuggestionsContent.make(repository, app: app, actions: context.actions).primary == .push(remote: "origin", ahead: 1, tags: 0, isGitHub: false))
            await app.idle()
        }
    }

    @Test("after rewriting pushed commits, nothing is suggested until the force push")
    func forcePushRecommended() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, remote) = try await setupRepositoryWithRemote()
            let fixture = try await ChangesWindowFixture.make(local)
            try await pushCommitFromAnotherClone(remote, path: "two.txt", contents: "two\n")
            try await fixture.git(["fetch", "origin"])
            await fixture.refresh()
            try await fixture.repository.commit.startAmending(confirmed: [.rewritePublishedCommits])
            fixture.repository.commit.draft.summary = "Initial commit, amended"
            _ = try await fixture.repository.commit.commit()
            await fixture.settle()
            #expect(fixture.repository.operations.forcePushState == .recommended)
            #expect(primary(fixture) == nil)
            await fixture.app.idle()
        }
    }

    @Test("the cards' words and where else their actions live")
    func cards() {
        let format = defaultNumberFormat
        let push = SuggestionsContent.Primary.push(remote: "origin", ahead: 2, tags: 1, isGitHub: true).card(numberFormat: format)
        #expect(push.title == "Push commits and tags to the origin remote")
        #expect(push.description == "You have 2 local commits and 1 tag waiting to be pushed to GitHub.")
        #expect(push.discoverability == "Always available in the toolbar when there are local commits waiting to be pushed, or ⌘P")
        #expect(push.buttonTitle == "Push origin")
        #expect(push.action == .push)
        #expect(push.action.actionID.kind == .push)
        // Each row shows its action's shortcut as a key cap.
        #expect(push.action.shortcut == "⌘P")
        #expect(SuggestionAction.showInFinder.shortcut == "⇧⌘F")

        let pull = SuggestionsContent.Primary.pull(branch: "main", remote: "upstream", behind: 1, isGitHub: false).card(numberFormat: format)
        #expect(pull.title == "Pull 1 commit from the upstream remote")
        #expect(pull.description == "The current branch (main) has a commit on the remote that doesn't exist on this Mac.")
        #expect(pull.discoverability.hasSuffix("⇧⌘P"))
        #expect(pull.buttonTitle == "Pull upstream")

        let publish = SuggestionsContent.Primary.publishBranch(branch: "feature", isGitHub: false).card(numberFormat: format)
        #expect(publish.description == "The current branch (feature) hasn't been published to the remote yet. Publish it to share it and collaborate with others.")

        // The line under the title says what's left: the primary
        // suggestion's description, or the general note without one.
        let pushing = SuggestionsContent(primary: .push(remote: "origin", ahead: 2, tags: 0, isGitHub: true), editorTitle: nil, isGitHub: true)
        #expect(pushing.subtitle == "You have 2 local commits waiting to be pushed to GitHub.")
        let content = SuggestionsContent(primary: nil, editorTitle: "Open in Xcode", isGitHub: false)
        #expect(content.subtitle == "There are no uncommitted changes in this repository. Here are some suggestions for what to do next.")
        #expect(content.editorCard?.discoverability == "Repository menu or ⇧⌘A")
        #expect(content.editorCard?.descriptionLinksToSettings == true)
        #expect(content.finderCard.discoverability == "Repository menu or ⇧⌘F")
        #expect(content.gitHubCard == nil)
        #expect(SuggestionsContent.Primary.viewStash.card(numberFormat: format).discoverability == "View menu or ⌃H")
        #expect(SuggestionsContent.Primary.pullRequest(branch: "f", choice: .createPullRequest).card(numberFormat: format).discoverability == "Branch menu or ⌘R")
    }

    @Test("suggestions snapshots: a primary card with the editor and GitHub, and none")
    func snapshots() {
        // The other cards differ only in their words (`cards` above).
        let primaries: [(String, SuggestionsContent.Primary?)] = [
            ("none", nil),
            ("push", .push(remote: "origin", ahead: 2, tags: 0, isGitHub: true)),
        ]
        for (name, primary) in primaries {
            let content = SuggestionsContent(primary: primary, editorTitle: name == "none" ? nil : "Open in Xcode", isGitHub: true)
            assertSnapshot(
                NoChangesSuggestions(content),
                named: "suggestions-\(name)",
                area: "Changes",
                size: CGSize(width: 640, height: 520),
                appearances: [.light]
            )
        }
    }
}
