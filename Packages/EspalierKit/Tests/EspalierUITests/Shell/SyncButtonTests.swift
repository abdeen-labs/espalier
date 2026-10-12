// The sync button's nine states and their menus, derived from real
// repositories; nothing, in the width it last had, while the repository's
// state loads; the button, the last fetch, and the width held while a push,
// pull, or fetch runs; VoiceOver hearing a push, fetch, or pull finish.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Sync button") @MainActor
struct SyncButtonTests {
    // MARK: States and menus

    @Test("each state's symbol, prominence, menu, and whether it's enabled")
    func states() {
        let now = UIFixtures.now
        let ahead = AheadBehind(ahead: 2, behind: 0)
        let diverged = AheadBehind(ahead: 2, behind: 3)

        // A fetch shows the fetch button, its arc in the symbol's place.
        let progress = SyncButtonState(kind: .progress(title: "Fetching origin", description: "Hang on…", value: nil, shown: .fetch(remote: "origin")))
        #expect(progress.systemImage == "arrow.trianglehead.2.clockwise.rotate.90")
        #expect(!progress.isEnabled)
        // A push stays blue, with its chevron.
        let pushing = SyncButtonState(kind: .progress(
            title: "Pushing to origin",
            description: "Hang on…",
            value: 0.5,
            shown: .push(remote: "origin", aheadBehind: AheadBehind(ahead: 2, behind: 0), tagsToPush: 0)
        ))
        #expect(pushing.isProminent)
        #expect(pushing.hasMenu)
        // Another operation: the arc alone.
        let other = SyncButtonState(kind: .progress(title: "Refreshing Repository", description: "Hang on…", value: nil, shown: nil))
        #expect(other.systemImage == nil)
        #expect(!other.isProminent)
        #expect(!other.hasMenu)

        let publishRepository = SyncButtonState(kind: .publishRepository)
        #expect(publishRepository.isProminent)

        let detached = SyncButtonState(kind: .detachedHead(rebaseInProgress: false))
        #expect(!detached.isEnabled)

        let publishBranch = SyncButtonState(kind: .publishBranch(isGitHubRepository: false, remote: "origin"))
        #expect(publishBranch.menuItems == [.fetch(remote: "origin")])

        let pull = SyncButtonState(kind: .pull(remote: "origin", withRebase: true, aheadBehind: diverged, tagsToPush: 0, canForcePush: true), asksBeforeForcePush: false)
        #expect(pull.systemImage == "arrow.down")
        #expect(pull.menuItems == [.fetch(remote: "origin"), .forcePush(remote: "origin", showsWarning: true)])

        let push = SyncButtonState(kind: .push(remote: "upstream", aheadBehind: ahead, tagsToPush: 3))
        #expect(push.behindCount == nil)

        let fetch = SyncButtonState(kind: .fetch(remote: "origin"), lastFetched: now.addingTimeInterval(-20))
        #expect(fetch.menuItems.isEmpty)
        #expect(!fetch.isProminent)
    }

    // MARK: Derived from repositories

    @Test("states come from the repository, in desktop's order", .offline)
    func derived() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()

            /// The button's state, enabled and offering alternatives as the
            /// sync action is.
            @MainActor func kindOf(_ repository: RepositoryModel) -> SyncButtonState.Kind {
                let state = SyncButtonState.make(repository, preferences: app.preferences)
                let action = repository.sync.action
                #expect(state.isEnabled == action.isEnabled)
                let alternatives = state.menuItems.map { item -> SyncAlternative in
                    switch item {
                    case .fetch(let remote): .fetch(remote: remote)
                    case .forcePush(let remote, _): .forcePush(remote: remote)
                    }
                }
                #expect(alternatives == action.alternatives)
                return state.kind
            }

            // No remote: publish the repository, even on an unborn branch.
            let empty = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
            #expect(kindOf(empty) == .publishRepository)

            // In sync with its upstream: fetch.
            let (local, remote) = try await setupRepositoryWithRemote()
            let synced = try await harness.addAndSelect(local, to: app)
            #expect(kindOf(synced) == .fetch(remote: "origin"))

            // Ahead: push.
            try harness.write("new.txt", "new\n", in: local)
            try await runGit(["add", "new.txt"], local)
            try await runGit(["commit", "-m", "Local commit"], local)
            await synced.refresh(reason: .user)
            #expect(kindOf(synced)
                == .push(remote: "origin", aheadBehind: AheadBehind(ahead: 1, behind: 0), tagsToPush: 0))

            // Behind and ahead: pull (no force push without a rewrite).
            try await pushCommitFromAnotherClone(remote, path: "other.txt", contents: "other\n")
            try await runGit(["fetch", "origin"], local)
            await synced.refresh(reason: .user)
            #expect(kindOf(synced)
                == .pull(remote: "origin", withRebase: false, aheadBehind: AheadBehind(ahead: 1, behind: 1), tagsToPush: 0, canForcePush: true))

            // A branch without an upstream: publish the branch.
            try await runGit(["checkout", "-b", "feature"], local)
            await synced.refresh(reason: .user)
            #expect(kindOf(synced)
                == .publishBranch(isGitHubRepository: false, remote: "origin"))

            // A detached HEAD.
            try await runGit(["checkout", "--detach"], local)
            await synced.refresh(reason: .user)
            #expect(kindOf(synced) == .detachedHead(rebaseInProgress: false))

            // An unborn branch with a remote: fetch.
            let unborn = try setupEmptyRepository()
            try await runGit(["remote", "add", "origin", remote.path], unborn)
            let unbornModel = try await harness.addAndSelect(unborn, to: app)
            #expect(kindOf(unbornModel) == .fetchUnborn(remote: "origin"))

            // While a new path's state loads: nothing, until it has.
            unbornModel.pathDidChange(keepingSharedState: true)
            let loading = SyncButtonState.make(unbornModel, preferences: app.preferences)
            #expect(loading.kind == .loading)
            #expect(unbornModel.sync.action == .loading)
            #expect(!loading.isEnabled)
            #expect(!loading.isProminent)
            #expect(!loading.showsLastFetched)
            #expect(loading.menuItems.isEmpty)
            await app.idle()
            #expect(kindOf(unbornModel) == .fetchUnborn(remote: "origin"))
            await app.idle()
        }
    }

    // MARK: Announcements

    @Test("VoiceOver hears a push, fetch, or pull finish, and nothing when it fails", .offline, .hangGuard(minutes: 5))
    func announcements() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, remote) = try await setupRepositoryWithRemote()
            let fixture = try await ChangesWindowFixture.make(local)
            let context = fixture.context
            let recorded = RecordedAnnouncements()
            context.announcer = recorded.announcer

            try fixture.write("new.txt", "new\n")
            try await fixture.git(["add", "new.txt"])
            try await fixture.git(["commit", "-m", "Local commit"])
            await fixture.refresh()
            await context.actions.performAndWait(.push)
            await fixture.settle()
            #expect(context.presenter.error == nil)
            #expect(recorded.messages.count == 1)

            try await pushCommitFromAnotherClone(remote, path: "other.txt", contents: "other\n")
            await context.actions.performAndWait(.fetch)
            await fixture.settle()
            await context.actions.performAndWait(.pull)
            await fixture.settle()
            #expect(context.presenter.error == nil)
            #expect(recorded.messages.count == 3)

            // The remote gone: the push's error shows, and nothing is said.
            try await fixture.git(["remote", "set-url", "origin", POSIXPath.join(remote.path, "missing")])
            try fixture.write("newer.txt", "newer\n")
            try await fixture.git(["add", "newer.txt"])
            try await fixture.git(["commit", "-m", "Another commit"])
            await fixture.refresh()
            await context.actions.performAndWait(.push)
            await fixture.settle()
            #expect(context.presenter.error != nil)
            #expect(recorded.messages.count == 3)
        }
    }

    // MARK: Loading

    @Test("while the repository's state loads, the last fetch and the button keep the width they last had, and draw nothing")
    func loadingKeepsWidth() {
        let lastFetched = Date().addingTimeInterval(-5 * 60)
        let fetch = SyncButtonState(kind: .fetch(remote: "origin"), lastFetched: lastFetched)
        let push = SyncButtonState(kind: .push(remote: "origin", aheadBehind: AheadBehind(ahead: 2, behind: 0), tagsToPush: 1), lastFetched: lastFetched)
        let loading = SyncButtonState(kind: .loading)

        let host = NSHostingView(rootView: Snapshot.deterministic(SyncButtonGroup(loading)))
        // A window wider than the group, which keeps its size whatever the
        // group's: the group lays out at its ideal width.
        host.sizingOptions = [.intrinsicContentSize]
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        /// Shows `state` in the window; its width.
        func show(_ state: SyncButtonState) -> CGFloat {
            host.rootView = Snapshot.deterministic(SyncButtonGroup(state))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        /// Whether nothing is drawn in the window.
        func isBlank() -> Bool {
            let image = Snapshot.image(of: host)
            for x in 0..<image.pixelsWide {
                for y in 0..<image.pixelsHigh where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                    return false
                }
            }
            return true
        }

        // Before anything has shown: nothing, in no space.
        #expect(show(loading) == 0)

        let fetchWidth = show(fetch)
        #expect(fetchWidth > 0)
        #expect(!isBlank())
        #expect(show(loading) == fetchWidth)
        #expect(isBlank())

        let pushWidth = show(push)
        #expect(pushWidth != fetchWidth)
        #expect(show(loading) == pushWidth)
        #expect(isBlank())
    }

    // MARK: Progress

    @Test("while a push, pull, or fetch runs, the button and the last fetch stay as they were, and the group doesn't narrow")
    func progressKeepsWidth() {
        let justNow = Date()
        let fetch = SyncButtonState(kind: .fetch(remote: "origin"), lastFetched: justNow)
        let push = SyncButtonState(kind: .push(remote: "origin", aheadBehind: AheadBehind(ahead: 2, behind: 0), tagsToPush: 0), lastFetched: justNow)
        let pull = SyncButtonState(kind: .pull(remote: "origin", withRebase: true, aheadBehind: AheadBehind(ahead: 2, behind: 3), tagsToPush: 0, canForcePush: true), lastFetched: justNow)
        let publish = SyncButtonState(kind: .publishBranch(isGitHubRepository: false, remote: "origin"), lastFetched: justNow)
        let nothing = AheadBehind(ahead: 0, behind: 0)
        /// The progress `make` gives while an operation runs, half way, with
        /// a last fetch longer ago than the one shown before it started.
        func progress(_ title: String, _ shown: SyncButtonState.Kind?) -> SyncButtonState {
            SyncButtonState(kind: .progress(title: title, description: "Hang on…", value: 0.5, shown: shown), lastFetched: Date().addingTimeInterval(-45 * 60))
        }
        let fetching = progress("Fetching origin", .fetch(remote: "origin"))
        let pushing = progress("Pushing to origin", .push(remote: "origin", aheadBehind: nothing, tagsToPush: 0))
        let pulling = progress("Pulling origin", .pull(remote: "origin", withRebase: true, aheadBehind: nothing, tagsToPush: 0, canForcePush: false))
        let publishing = progress("Pushing to origin", .publishBranch(isGitHubRepository: false, remote: "origin"))
        let refreshing = progress("Refreshing Repository", nil)
        /// The state a running push, pull, or fetch shows.
        func shown(_ state: SyncButtonState) -> SyncButtonState.Kind? {
            guard case .progress(_, _, _, let shown) = state.kind else {
                return nil
            }
            return shown
        }

        // The button shows the state from before the operation when that
        // offered it, or when it isn't one of the button's; otherwise the
        // operation's.
        #expect(shown(pushing.keeping(push)) == push.kind)
        #expect(shown(pulling.keeping(pull)) == pull.kind)
        #expect(shown(refreshing.keeping(push)) == push.kind)
        #expect(fetching.keeping(push) == fetching)
        #expect(pushing.keeping(fetch) == pushing)

        /// The ideal width of `view`.
        func idealWidth(_ view: some View) -> CGFloat {
            NSHostingView(rootView: Snapshot.deterministic(view)).fittingSize.width
        }
        /// The width of the button alone, as the group sizes it.
        func buttonWidth(_ state: SyncButtonState) -> CGFloat {
            idealWidth(SyncButtonView(state).controlSize(.large))
        }

        // The arc takes the symbol's place: the button keeps its width,
        // plain or split, quiet or blue.
        for (running, before) in [(fetching, fetch), (pushing, push), (pulling, pull), (publishing, publish)] {
            #expect(buttonWidth(running.keeping(before)) == buttonWidth(before))
        }

        let host = NSHostingView(rootView: Snapshot.deterministic(SyncButtonGroup(fetch)))
        // A window wider than the group, which keeps its size whatever the
        // group's: the group lays out at its ideal width.
        host.sizingOptions = [.intrinsicContentSize]
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        /// Shows `state` in the window; its width.
        func show(_ state: SyncButtonState) -> CGFloat {
            host.rootView = Snapshot.deterministic(SyncButtonGroup(state))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }

        // A fetch: the group keeps its width from start to end, the last
        // fetch showing as it did before.
        let fetchWidth = show(fetch)
        #expect(show(fetching) == fetchWidth)
        #expect(show(fetch) == fetchWidth)

        // A fetch while the button offers a push: the fetch, narrower, in
        // the width the group had.
        let pushWidth = show(push)
        #expect(buttonWidth(fetching) < buttonWidth(push) - 1)
        #expect(show(fetching) == pushWidth)

        // Publishing a branch: the last fetch, which didn't show, stays
        // hidden.
        let publishWidth = show(publish)
        #expect(show(publishing) == publishWidth)
    }
}
