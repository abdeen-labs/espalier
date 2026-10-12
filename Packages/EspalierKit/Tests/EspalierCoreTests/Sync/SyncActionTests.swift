// The push/pull button's nine states, in order, on a selected repository
// whose git state is set directly, and nothing until that state has
// loaded; the other Sync tests reach the states through
// real operations.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Sync action", .offline) @MainActor
struct SyncActionTests {
    private let sha = String(repeating: "a", count: 40)

    /// A selected repository on `main`, tracking `origin/main`, settled.
    private func makeRepository() async throws -> SelectedRepository {
        let fixture = try await makeSelectedRepository()
        await fixture.app.idle()
        return fixture
    }

    private func setTip(_ fixture: SelectedRepository, branch: String = "main", upstream: String? = "origin/main") {
        fixture.model.gitState.tip = .valid(branch: ModelFixtures.branch(branch, sha: sha, upstream: upstream))
    }

    @Test("starts as Fetch origin for a repository that is up to date")
    func upToDate() async throws {
        let fixture = try await makeRepository()
        let action = fixture.model.sync.action
        #expect(action == .fetch(remote: "origin"))
        #expect(action.description == nil)
        #expect(action.isEnabled)
        #expect(action.counts == nil)
        #expect(action.alternatives.isEmpty)
    }

    @Test("a network operation in progress comes first and disables the button")
    func inProgress() async throws {
        let fixture = try await makeRepository()
        let operation = ActiveOperation(kind: .fetch, isBackgroundTask: true)
        fixture.model.publish(operation, lanes: [.network])
        #expect(fixture.model.sync.action == .inProgress)
        #expect(fixture.model.sync.action.title == nil)
        #expect(!fixture.model.sync.action.isEnabled)

        // Pull holds both lanes.
        fixture.model.clearActivity(operation.id)
        let pull = ActiveOperation(kind: .pull)
        fixture.model.publish(pull, lanes: [.network, .local])
        #expect(fixture.model.sync.action == .inProgress)
        fixture.model.clearActivity(pull.id)

        // A local operation isn't a network one.
        let commit = ActiveOperation(kind: .commit)
        fixture.model.publish(commit, lanes: [.local])
        #expect(fixture.model.sync.action == .fetch(remote: "origin"))
        fixture.model.clearActivity(commit.id)
    }

    @Test("claims nothing until the status, remotes, and refs have all loaded, though a network operation shows")
    func loading() async throws {
        let fixture = try await makeRepository()
        for partial: RefreshScope in [[], [.status, .refs, .metadata], [.status, .remotes, .metadata], [.remotes, .refs, .metadata]] {
            fixture.model.gitState.loaded = partial
            #expect(fixture.model.sync.action == .loading, "loaded: \(partial)")
        }
        let action = fixture.model.sync.action
        #expect(action.title == nil)
        #expect(action.description == nil)
        #expect(!action.isEnabled)
        #expect(action.counts == nil)
        #expect(action.alternatives.isEmpty)

        let operation = ActiveOperation(kind: .fetch, isBackgroundTask: true)
        fixture.model.publish(operation, lanes: [.network])
        #expect(fixture.model.sync.action == .inProgress)
        fixture.model.clearActivity(operation.id)

        fixture.model.gitState.loaded = [.status, .remotes, .refs]
        #expect(fixture.model.sync.action == .fetch(remote: "origin"))
    }

    @Test("a repository nothing or only its sidebar indicator refreshed claims nothing until selecting it loads the rest, nor while a new path loads")
    func partlyLoadedRepository() async throws {
        try await withIsolatedGitConfig { _ in
            // A branch without an upstream, in a repository with a remote:
            // Publish branch, once everything has loaded.
            let (local, _) = try await setupRepositoryWithRemote()
            try await runGit(["checkout", "-q", "-b", "feature"], local)
            let harness = try AppHarness()
            let listed = await harness.loadedApp()
            let id = try #require(try await listed.addRepositories([local.path]).added.first)
            // Another repository is selected, and launch selects it again.
            let other = try #require(try await listed.addRepositories([try setupEmptyRepository().path]).added.first)
            listed.select(.repository(other))
            await listed.idle()

            // After a relaunch, the repository has no tip and no remotes
            // yet, which would read as one to publish.
            let app = await harness.loadedApp()
            app.preferences.hasShownWelcomeFlow = true
            await app.idle()
            #expect(app.selection == .repository(other))
            let repository = try #require(app.repository(id))
            #expect(repository.gitState.remotes.currentRemote == nil)
            #expect(repository.sync.action == .loading)

            // The indicator refreshes its status (and the refs of its new
            // tip), which shows the branch but none of the remotes.
            await repository.refresh(.status, reason: .background)
            await repository.idle()
            #expect(repository.gitState.tip.branch?.name == "feature")
            #expect(repository.gitState.remotes.currentRemote == nil)
            #expect(repository.sync.action == .loading)

            app.select(.repository(id))
            await app.idle()
            #expect(repository.gitState.hasLoadedRemoteState)
            #expect(repository.sync.action == .publishBranch(remote: "origin", isGitHubRepository: false))

            // A new path keeps the remotes every worktree shares, not the
            // status and refs: nothing until its refresh lands.
            repository.pathDidChange(keepingSharedState: true)
            #expect(repository.sync.action == .loading)
            await app.idle()
            #expect(repository.sync.action == .publishBranch(remote: "origin", isGitHubRepository: false))
            await app.idle()
        }
    }

    @Test("without a remote it publishes the repository")
    func publishRepository() async throws {
        let fixture = try await makeRepository()
        fixture.model.gitState.remotes = RemotesSnapshot()
        setTip(fixture, upstream: nil)
        let action = fixture.model.sync.action
        #expect(action == .publishRepository)
        #expect(action.isEnabled)

        // A branch still tracking a remote that's gone names that remote.
        setTip(fixture, upstream: "origin/main")
        #expect(fixture.model.sync.action == .fetch(remote: "origin"))
    }

    @Test("a detached HEAD can't be published, and says when a rebase is why")
    func detached() async throws {
        let fixture = try await makeRepository()
        fixture.model.gitState.tip = .detached(currentSha: sha)
        var action = fixture.model.sync.action
        #expect(action == .detachedHead(rebaseInProgress: false))
        #expect(!action.isEnabled)

        fixture.model.gitState.inProgress = .rebase(RebaseInternalState(targetBranch: "main", baseBranchTip: sha, originalBranchTip: sha))
        action = fixture.model.sync.action
        #expect(action == .detachedHead(rebaseInProgress: true))
    }

    @Test("a branch without an upstream publishes, to GitHub or the remote")
    func publishBranch() async throws {
        let fixture = try await makeRepository()
        setTip(fixture, branch: "feature", upstream: nil)
        fixture.model.gitState.aheadBehind = nil
        var action = fixture.model.sync.action
        #expect(action == .publishBranch(remote: "origin", isGitHubRepository: false))
        #expect(action.alternatives == [.fetch(remote: "origin")])

        fixture.associate()
        action = fixture.model.sync.action
        #expect(action == .publishBranch(remote: "origin", isGitHubRepository: true))
    }

    @Test("nothing to push or pull fetches, unless tags wait to be pushed")
    func tagsToPush() async throws {
        let fixture = try await makeRepository()
        fixture.app.updateRecord(fixture.model.id) { $0.tagsToPush = ["v1.0", "v1.1"] }
        let action = fixture.model.sync.action
        #expect(action == .push(remote: "origin", aheadBehind: AheadBehind(ahead: 0, behind: 0), tagsToPush: 2))
        #expect(action.counts == SyncCounts(toPush: 2, toPull: 0))
    }

    @Test("a rewritten branch that diverged force pushes, ahead of pulling")
    func forcePush() async throws {
        let fixture = try await makeRepository()
        setTip(fixture)
        fixture.model.gitState.aheadBehind = AheadBehind(ahead: 1, behind: 2)
        fixture.model.operations.rewrittenBranches["main"] = sha
        let action = fixture.model.sync.action
        #expect(action == .forcePush(remote: "origin", aheadBehind: AheadBehind(ahead: 1, behind: 2), tagsToPush: 0))
        #expect(action.description == nil)
        #expect(action.counts == SyncCounts(toPush: 1, toPull: 2))
        #expect(action.alternatives == [.fetch(remote: "origin")])
    }

    @Test("behind pulls, with rebase when pull.rebase says so, offering a force push once it's possible")
    func pull() async throws {
        let fixture = try await makeRepository()
        setTip(fixture)
        fixture.model.gitState.aheadBehind = AheadBehind(ahead: 0, behind: 2)
        var action = fixture.model.sync.action
        #expect(action == .pull(remote: "origin", aheadBehind: AheadBehind(ahead: 0, behind: 2), tagsToPush: 0, withRebase: false, forcePushAvailable: false))
        #expect(action.alternatives == [.fetch(remote: "origin")])

        var branches = fixture.model.gitState.branches
        branches.pullWithRebase = true
        fixture.model.gitState.branches = branches
        #expect(fixture.model.sync.action == .pull(remote: "origin", aheadBehind: AheadBehind(ahead: 0, behind: 2), tagsToPush: 0, withRebase: true, forcePushAvailable: false))

        // Diverged, but nothing rewritten: a force push is available, not
        // recommended.
        fixture.model.gitState.aheadBehind = AheadBehind(ahead: 1, behind: 2)
        action = fixture.model.sync.action
        #expect(action == .pull(remote: "origin", aheadBehind: AheadBehind(ahead: 1, behind: 2), tagsToPush: 0, withRebase: true, forcePushAvailable: true))
        #expect(action.alternatives == [.fetch(remote: "origin"), .forcePush(remote: "origin")])
    }

    @Test("a branch tracking a branch of another name shows the whole upstream")
    func upstreamOfAnotherName() async throws {
        let fixture = try await makeRepository()
        setTip(fixture, branch: "feature", upstream: "origin/main")
        fixture.model.gitState.aheadBehind = AheadBehind(ahead: 1, behind: 0)
        #expect(fixture.model.sync.action == .push(remote: "origin/main", aheadBehind: AheadBehind(ahead: 1, behind: 0), tagsToPush: 0))
    }
}
