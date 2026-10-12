// The menu bar: every item has a handler and validates in each window
// state, Next and Previous Place, and the router gates actions on handlers,
// rules, and modals.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

/// What the router test's handler saw.
@MainActor
private final class RouterState {
    var enabled = true
    var fetched = 0
}

@Suite("Commands", .hangGuard(minutes: 5)) @MainActor
struct CommandsTests {
    // MARK: Validation

    /// Every catalog action's kind.
    private var catalogKinds: Set<ActionKind> {
        Set((MenuCatalog.all.flatMap(\.actions) + MenuCatalog.debug.actions).map(\.kind))
    }

    @Test("every menu item has a handler", .offline)
    func handlers() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let context = WindowContext(app: app)
        let missing = catalogKinds.subtracting(context.actions.registeredKinds)
        #expect(missing.isEmpty, "no handler for \(missing.map(\.rawValue).sorted())")
        // Every kind the router knows has a handler, menu item or not.
        #expect(Set(ActionKind.allCases).subtracting(context.actions.registeredKinds).isEmpty)
    }

    @Test("every menu item validates in each window state", .offline)
    func validates() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let context = WindowContext(app: app)
            let actions = MenuCatalog.all.flatMap(\.actions)

            // The welcome flow: repository commands are off, and so are
            // New, Add, and Clone.
            #expect(!app.preferences.hasShownWelcomeFlow)
            for action in actions {
                _ = context.actions.canPerform(action)
                _ = context.actions.title(for: action)
            }
            #expect(!context.actions.canPerform(.newRepository(path: nil)))
            #expect(!context.actions.canPerform(.push))

            // No repositories: the app's commands only.
            app.preferences.hasShownWelcomeFlow = true
            #expect(context.actions.canPerform(.addLocalRepository))
            #expect(!context.actions.canPerform(.switchRepository))
            #expect(!context.actions.canPerform(.fetch))
            #expect(!context.actions.canPerform(.showChanges))

            // A repository with a remote, in sync.
            let (local, _) = try await setupRepositoryWithRemote()
            _ = try await harness.addAndSelect(local, to: app)
            for action in actions {
                _ = context.actions.canPerform(action)
                #expect(!context.actions.title(for: action).isEmpty)
            }
            #expect(context.actions.canPerform(.switchRepository))
            #expect(context.actions.canPerform(.showChanges))
            #expect(context.actions.canPerform(.fetch))
            #expect(context.actions.canPerform(.pull))
            #expect(!context.actions.canPerform(.discardAllChanges))
            #expect(!context.actions.canPerform(.deleteBranch(name: nil)))

            // The history scope is remembered per repository.
            #expect(context.actions.isChecked(.setHistoryScope(HistoryScope.defaultScope)))
            await context.actions.performAndWait(.setHistoryScope(.allBranches))
            #expect(context.repository?.history.scope == .allBranches)
            #expect(context.actions.isChecked(.setHistoryScope(.allBranches)))
            #expect(!context.actions.isChecked(.setHistoryScope(.currentBranch)))

            // A modal disables the repository's commands.
            let task = Task { await context.presenter.ask(.discardStash()) }
            await waitUntil { context.presenter.confirmation != nil }
            #expect(!context.actions.canPerform(.fetch))
            #expect(!context.actions.canPerform(.showChanges))
            context.presenter.respond(to: context.presenter.confirmation!.id, with: .cancelled)
            _ = await task.value
            #expect(context.actions.canPerform(.fetch))
            await app.idle()
        }
    }

    // MARK: Next and Previous Place

    @Test("Next and Previous Place go between Changes and History, from elsewhere to Changes and History, and are off where Changes and History are", .offline)
    func nextAndPreviousPlace() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            app.preferences.hasShownWelcomeFlow = true
            let context = WindowContext(app: app)
            let actions = context.actions

            // No repository: off, as ⌘1 and ⌘2 are.
            #expect(!actions.canPerform(.showChanges))
            #expect(!actions.canPerform(.showNextPlace))
            #expect(!actions.canPerform(.showPreviousPlace))

            _ = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
            #expect(actions.canPerform(.showNextPlace))
            #expect(actions.canPerform(.showPreviousPlace))

            // Between Changes and History, either way.
            context.select(.changes)
            await actions.performAndWait(.showNextPlace)
            #expect(context.state.place == .history)
            await actions.performAndWait(.showNextPlace)
            #expect(context.state.place == .changes)
            await actions.performAndWait(.showPreviousPlace)
            #expect(context.state.place == .history)
            await actions.performAndWait(.showPreviousPlace)
            #expect(context.state.place == .changes)

            // From any other place: Next to Changes, Previous to History.
            let others: [SidebarPlace] = [
                .branch(ref: "refs/heads/main"), .tag(name: "v1.0"), .stash(branch: "main"), .pullRequest(number: 7),
            ]
            for place in others {
                context.select(place)
                await actions.performAndWait(.showNextPlace)
                #expect(context.state.place == .changes, "\(place)")
                context.select(place)
                await actions.performAndWait(.showPreviousPlace)
                #expect(context.state.place == .history, "\(place)")
            }

            // A confirmation turns them off, as it does ⌘1 and ⌘2.
            let task = Task { await context.presenter.ask(.discardStash()) }
            await waitUntil { context.presenter.confirmation != nil }
            #expect(!actions.canPerform(.showHistory))
            #expect(!actions.canPerform(.showNextPlace))
            #expect(!actions.canPerform(.showPreviousPlace))
            context.presenter.respond(to: context.presenter.confirmation!.id, with: .cancelled)
            _ = await task.value
            #expect(actions.canPerform(.showNextPlace))

            // So does a sheet.
            let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            defer { withExtendedLifetime(window) {} }
            context.modals.window = window
            context.modals.presentSheet(id: "sheet") { Text("Sheet") }
            #expect(context.modals.isPresentingSheet(id: "sheet"))
            #expect(!actions.canPerform(.showChanges))
            #expect(!actions.canPerform(.showNextPlace))
            #expect(!actions.canPerform(.showPreviousPlace))
            await app.idle()
        }
    }

    // MARK: The router

    @Test("actions run only with a handler that's enabled")
    func router() async {
        let actions = WindowActions()
        #expect(!actions.canPerform(.fetch))

        let state = RouterState()
        actions.register(.fetch, isEnabled: { _ in state.enabled }) { _ in
            state.fetched += 1
        }
        #expect(actions.canPerform(.fetch))
        await actions.performAndWait(.fetch)
        actions.perform(.fetch)
        await actions.idle()
        #expect(state.fetched == 2)

        state.enabled = false
        #expect(!actions.canPerform(.fetch))
        await actions.performAndWait(.fetch)
        #expect(state.fetched == 2)

        // Window rules and modals gate repository actions.
        state.enabled = true
        actions.availability = { $0 != .fetch }
        #expect(!actions.canPerform(.fetch))
        actions.availability = nil
        actions.isModalPresented = { true }
        #expect(!actions.canPerform(.fetch))
        actions.register(.search) { _ in }
        #expect(actions.canPerform(.search))
    }
}
