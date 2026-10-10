// The pull request updater's cadence on a `ManualScheduler`: at once, then
// every 30 minutes, never within 2 minutes of the last refresh, a tick
// right after another refresh only rescheduling; and stopping.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import Testing
import TestSupport

@Suite("Pull request updater", .offline) @MainActor
struct PullRequestUpdaterTests {
    private func pullsRequests(_ fixture: GitHubFixture) -> Int {
        fixture.gitHub.requests("GET", "/repos/octocat/hello/pulls").count
    }

    @Test("refreshes at once, then 30 minutes after each refresh")
    func cadence() async throws {
        // Not selected: the test drives the app's updater itself.
        let fixture = try await makeGitHubFixture { _, pulls in
            pulls.open = [apiPullRequest(1)]
        }
        let updater = fixture.app.background.pullRequests
        updater.start(for: fixture.model, isFirstSelectionSinceLaunch: false)
        #expect(updater.repositoryID == fixture.model.id)

        await fixture.scheduler.waitForSleepers(1)
        #expect(fixture.scheduler.sleeps == [.zero, .seconds(30 * 60)])
        #expect(pullsRequests(fixture) == 1)
        #expect(fixture.model.gitHub.openPullRequests.map(\.pullRequestNumber) == [1])

        await fixture.scheduler.advance(by: .seconds(30 * 60))
        await fixture.scheduler.waitForSleepers(1)
        #expect(pullsRequests(fixture) == 2)
        #expect(fixture.scheduler.sleeps == [.zero, .seconds(30 * 60), .seconds(30 * 60)])

        updater.stop()
        #expect(!updater.isRunning)
        await settle(until: { fixture.scheduler.sleeperCount == 0 })
        await fixture.settle()
    }

    @Test("a restart within 2 minutes of the last refresh waits out the rest")
    func minimumFrequency() async throws {
        let fixture = try await makeGitHubFixture()
        await fixture.model.gitHub.refreshPullRequests()
        await fixture.scheduler.advance(by: .seconds(30))

        let updater = fixture.app.background.pullRequests
        updater.start(for: fixture.model, isFirstSelectionSinceLaunch: false)
        await fixture.scheduler.waitForSleepers(1)
        #expect(fixture.scheduler.sleeps == [.seconds(90)])
        #expect(pullsRequests(fixture) == 1)

        await fixture.scheduler.advance(by: .seconds(90))
        await fixture.scheduler.waitForSleepers(1)
        #expect(pullsRequests(fixture) == 2)
        #expect(fixture.scheduler.sleeps.last == .seconds(30 * 60))

        updater.stop()
        await settle(until: { fixture.scheduler.sleeperCount == 0 })
        await fixture.settle()
    }

    @Test("a tick right after another refresh only reschedules (desktop refreshed anyway and orphaned a timer)")
    func recentRefreshReschedules() async throws {
        let fixture = try await makeGitHubFixture()
        let updater = fixture.app.background.pullRequests
        updater.start(for: fixture.model, isFirstSelectionSinceLaunch: false)
        await fixture.scheduler.waitForSleepers(1)
        #expect(pullsRequests(fixture) == 1)

        // The list's own refresh, a minute before the tick.
        await fixture.scheduler.advance(by: .seconds(29 * 60))
        await fixture.model.gitHub.refreshPullRequests()
        #expect(pullsRequests(fixture) == 2)

        await fixture.scheduler.advance(by: .seconds(60))
        await fixture.scheduler.waitForSleepers(1)
        #expect(pullsRequests(fixture) == 2)
        #expect(fixture.scheduler.sleeps.last == .seconds(29 * 60))
        #expect(fixture.scheduler.sleeperCount == 1)

        updater.stop()
        await settle(until: { fixture.scheduler.sleeperCount == 0 })
        await fixture.settle()
    }

    @Test("the selected GitHub repository's pull requests load when it's selected, and not while inactive")
    func selection() async throws {
        let fixture = try await makeGitHubFixture(select: true, backgroundServices: .pullRequests) { _, pulls in
            pulls.open = [apiPullRequest(3)]
        }
        let updater = fixture.app.background.pullRequests
        #expect(updater.repositoryID == fixture.model.id)
        #expect(fixture.model.gitHub.openPullRequests.map(\.pullRequestNumber) == [3])

        fixture.app.setActive(false)
        #expect(!updater.isRunning)
        fixture.app.setActive(true)
        #expect(updater.repositoryID == fixture.model.id)
        await fixture.settle()
    }
}
