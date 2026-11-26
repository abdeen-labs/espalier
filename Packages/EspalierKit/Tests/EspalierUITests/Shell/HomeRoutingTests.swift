// Where the window goes with Home: it opens on Home while the setting is
// on and on its repository while it's off; Go ▸ Home is offered only with
// the setting on; switching repositories and showing a place leave Home;
// and opening a piece of work selects its repository at its worktree, at
// the place asked for.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Home routing", .offline, .hangGuard(minutes: 5)) @MainActor
struct HomeRoutingTests {
    /// A loaded app with Home `on`, two committed repositories in the list,
    /// the second selected, and a window.
    private func makeWindow(showsHome on: Bool) async throws -> (AppHarness, AppModel, WindowContext, [RepositoryModel]) {
        let harness = try AppHarness(showsHome: on)
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        var models: [RepositoryModel] = []
        for _ in 0..<2 {
            let repository = try setupEmptyRepository()
            try await makeCommit(repository, Tree(entries: [TreeEntry(path: "README.md", contents: "# README\n")]))
            models.append(try await harness.addAndSelect(repository, to: app))
        }
        return (harness, app, WindowContext(app: app), models)
    }

    @Test("a window opens on Home while Home is on, and on its repository while it's off", arguments: [true, false])
    func opens(showsHome: Bool) async throws {
        let (_, app, context, models) = try await makeWindow(showsHome: showsHome)

        #expect(context.state.isShowingHome == showsHome)
        let destination = DetailDestination.make(app: app, isShowingHome: context.state.isShowingHome, place: .changes)
        #expect(destination == (showsHome ? .home : .changes(models[1].id)))
        #expect(context.actions.canPerform(.showHome) == showsHome)
        await app.idle()
    }

    @Test("switching repositories, the selected one too, and showing a place leave Home; Go ▸ Home goes back")
    func leaving() async throws {
        let (_, app, context, models) = try await makeWindow(showsHome: true)

        RepositoryActions.switchTo(.repository(models[1].id), in: context)
        #expect(!context.state.isShowingHome)
        #expect(app.selection == .repository(models[1].id))

        context.actions.perform(.showHome)
        await waitUntil { context.state.isShowingHome }
        RepositoryActions.switchTo(.repository(models[0].id), in: context)
        #expect(!context.state.isShowingHome)
        #expect(app.selection == .repository(models[0].id))

        context.actions.perform(.showHome)
        await waitUntil { context.state.isShowingHome }
        context.select(.history)
        #expect(!context.state.isShowingHome)
        await app.idle()
    }

    @Test("opening a piece of work selects its repository at its worktree, shows the place asked for, and leaves Home")
    func openWork() async throws {
        let (_, app, context, models) = try await makeWindow(showsHome: true)
        let first = models[0]
        let linkedPath = realPath(POSIXPath.join(try createTempDirectory(), "linked"))
        try await runGit(["worktree", "add", "-q", "-b", "linked", linkedPath], first.record.gitRepository)
        let current = realPath(first.record.path)
        app.setWorktreeStatuses(try await listWorktrees(first.record.path).map { entry in
            WorktreeStatus(entry: entry, isCurrent: JSCompat.strictEquals(realPath(entry.path), current))
        }, for: first.id)

        // The worktree the record points at, in another repository.
        await HomeActions.open(WorktreeKey(repositoryID: first.id, path: first.record.path), place: .history, in: context)
        #expect(app.selection == .repository(first.id))
        #expect(context.state.place == .history)
        #expect(!context.state.isShowingHome)

        // A linked worktree: the record switches to it, at its last place.
        context.actions.perform(.showHome)
        await waitUntil { context.state.isShowingHome }
        await HomeActions.open(WorktreeKey(repositoryID: first.id, path: linkedPath), place: nil, in: context)
        await app.idle()
        #expect(realPath(first.record.path) == linkedPath)
        #expect(app.selection == .repository(first.id))
        #expect(!context.state.isShowingHome)
        await app.idle()
    }
}
