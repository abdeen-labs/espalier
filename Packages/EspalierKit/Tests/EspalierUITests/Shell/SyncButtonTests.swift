// The sync button's nine states, their copy, menus, and counts, derived
// from real repositories, and their snapshots; nothing, in the width it
// last had, while the repository's state loads; the button, the last
// fetch, and the width held while a push, pull, or fetch runs; what
// VoiceOver hears when a push, fetch, or pull finishes.

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
    // MARK: Copy and menus

    @Test("each state has desktop's title, description, symbol, and menu")
    func copy() {
        let now = UIFixtures.now
        let fetched = UIFixtures.minutesAgo(5)
        let ahead = AheadBehind(ahead: 2, behind: 0)
        let diverged = AheadBehind(ahead: 2, behind: 3)

        // A fetch shows the fetch button, its arc in the symbol's place; what
        // runs is in the tooltip and what VoiceOver hears.
        let progress = SyncButtonState(kind: .progress(title: "Fetching origin", description: "Hang on…", value: nil, shown: .fetch(remote: "origin")))
        #expect(progress.title == "Fetch origin")
        #expect(progress.accessibilityTitle == "Fetching origin")
        #expect(progress.detail(now: now) == "Fetching origin\nHang on…")
        #expect(progress.systemImage == "arrow.trianglehead.2.clockwise.rotate.90")
        #expect(!progress.isEnabled)
        // A push stays blue, with its counts and chevron.
        let pushing = SyncButtonState(kind: .progress(
            title: "Pushing to origin",
            description: "Hang on…",
            value: 0.5,
            shown: .push(remote: "origin", aheadBehind: AheadBehind(ahead: 2, behind: 0), tagsToPush: 0)
        ))
        #expect(pushing.label == "Push origin ↑2")
        #expect(pushing.isProminent)
        #expect(pushing.hasMenu)
        // Another operation: its title, and the arc alone.
        let other = SyncButtonState(kind: .progress(title: "Refreshing Repository", description: "Hang on…", value: nil, shown: nil))
        #expect(other.title == "Refreshing Repository")
        #expect(other.systemImage == nil)
        #expect(!other.isProminent)
        #expect(!other.hasMenu)

        let publishRepository = SyncButtonState(kind: .publishRepository)
        #expect(publishRepository.title == "Publish repository")
        #expect(publishRepository.detail(now: now) == "Publish this repository to GitHub")
        #expect(publishRepository.isProminent)

        let unborn = SyncButtonState(kind: .fetchUnborn(remote: "origin"))
        #expect(unborn.title == "Fetch origin")
        #expect(unborn.detail(now: now) == "Never fetched")

        let detached = SyncButtonState(kind: .detachedHead(rebaseInProgress: false))
        #expect(detached.title == "Publish branch")
        #expect(detached.detail(now: now) == "Can't publish a detached HEAD")
        #expect(SyncButtonState(kind: .detachedHead(rebaseInProgress: true)).detail(now: now) == "Rebase in progress")
        #expect(!detached.isEnabled)

        let publishBranch = SyncButtonState(kind: .publishBranch(isGitHubRepository: false, remote: "origin"))
        #expect(publishBranch.detail(now: now) == "Publish this branch to the remote")
        #expect(publishBranch.menuItems == [.fetch(remote: "origin")])

        let forcePush = SyncButtonState(kind: .forcePush(remote: "origin", aheadBehind: diverged, tagsToPush: 0), lastFetched: fetched)
        #expect(forcePush.title == "Force push origin")
        #expect(forcePush.detail(now: now, timeZone: UIFixtures.timeZone) == "Last fetched 5 minutes ago")
        #expect(forcePush.aheadCount == "2")
        #expect(forcePush.behindCount == "3")

        let pull = SyncButtonState(kind: .pull(remote: "origin", withRebase: true, aheadBehind: diverged, tagsToPush: 0, canForcePush: true), asksBeforeForcePush: false)
        #expect(pull.title == "Pull origin with rebase")
        #expect(pull.systemImage == "arrow.down")
        #expect(pull.menuItems == [.fetch(remote: "origin"), .forcePush(remote: "origin", showsWarning: true)])
        #expect(SyncMenuItem.forcePush(remote: "origin", showsWarning: true).description.contains("Warning: Force pushing rewrites the branch's history on the remote."))
        // A force push that asks first ends in an ellipsis, as the
        // Repository menu's Force Push does.
        #expect(SyncMenuItem.forcePush(remote: "origin", showsWarning: true).title == "Force push origin")
        #expect(SyncMenuItem.forcePush(remote: "origin", showsWarning: false).title == "Force push origin…")
        #expect(SyncMenuItem.forcePush(remote: "origin", showsWarning: false).description == "Overwrite any changes on origin with your local changes")

        let push = SyncButtonState(kind: .push(remote: "upstream", aheadBehind: ahead, tagsToPush: 3))
        #expect(push.title == "Push upstream")
        #expect(push.aheadCount == "5")
        #expect(push.behindCount == nil)
        #expect(push.label == "Push upstream ↑5")
        #expect(pull.label == "Pull origin with rebase ↓3 ↑2")
        #expect(forcePush.label == "Force push origin ↑2 ↓3")
        #expect(SyncButtonState(kind: .push(remote: "origin", aheadBehind: AheadBehind(ahead: 1_200, behind: 0), tagsToPush: 0)).label == "Push origin ↑1.2k")

        let fetch = SyncButtonState(kind: .fetch(remote: "origin"), lastFetched: now.addingTimeInterval(-20))
        #expect(fetch.detail(now: now) == "Last fetched just now")
        #expect(fetch.menuItems.isEmpty)
        #expect(!fetch.isProminent)
    }

    // MARK: Derived from repositories

    @Test("states come from the repository, in desktop's order", .offline)
    func derived() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()

            /// The button's state, whose copy must be the sync action's.
            @MainActor func kindOf(_ repository: RepositoryModel) -> SyncButtonState.Kind {
                let state = SyncButtonState.make(repository, preferences: app.preferences)
                let action = repository.sync.action
                #expect(state.title == action.title)
                #expect(state.isEnabled == action.isEnabled)
                if let description = action.description {
                    #expect(state.detail(now: Date()) == description)
                }
                #expect(state.menuItems.map { $0.title.replacing("…", with: "") } == action.alternatives.map(\.title))
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
            #expect(recorded.messages == ["Push complete"])

            try await pushCommitFromAnotherClone(remote, path: "other.txt", contents: "other\n")
            await context.actions.performAndWait(.fetch)
            await fixture.settle()
            await context.actions.performAndWait(.pull)
            await fixture.settle()
            #expect(context.presenter.error == nil)
            #expect(recorded.messages == ["Push complete", "Fetch complete", "Pull complete"])

            // The remote gone: the push's error shows, and nothing is said.
            try await fixture.git(["remote", "set-url", "origin", POSIXPath.join(remote.path, "missing")])
            try fixture.write("newer.txt", "newer\n")
            try await fixture.git(["add", "newer.txt"])
            try await fixture.git(["commit", "-m", "Another commit"])
            await fixture.refresh()
            await context.actions.performAndWait(.push)
            await fixture.settle()
            #expect(context.presenter.error != nil)
            #expect(recorded.messages == ["Push complete", "Fetch complete", "Pull complete"])
        }
    }

    // MARK: Loading

    @Test("while the repository's state loads, the last fetch and the button keep the width they last had, and draw nothing")
    func loadingKeepsWidth() {
        let lastFetched = UIFixtures.minutesAgo(5)
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

    @Test("the toolbar while the selected repository loads: nothing where the last fetch and the button were")
    func loadingSnapshot() {
        let fetch = SyncButtonState(kind: .fetch(remote: "origin"), lastFetched: UIFixtures.minutesAgo(5))
        let fetchWidth = NSHostingView(rootView: Snapshot.deterministic(SyncButtonGroup(fetch))).fittingSize.width
        let rows: [(LocationControlState, SyncButtonGroup)] = [
            // The repository selected before, then the one selected now.
            (
                LocationControlState(repository: .repository(name: "meridian", path: "/Users/joe/Developer/meridian"), branch: .branch(name: "main")),
                SyncButtonGroup(fetch)
            ),
            (
                LocationControlState(repository: .repository(name: "forecast-kit", path: "/Users/joe/Developer/forecast-kit"), branch: .hidden),
                SyncButtonGroup(SyncButtonState(kind: .loading), shownWidth: fetchWidth)
            ),
        ]
        let view = VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    LocationControlView(rows[index].0)
                    Spacer(minLength: Metrics.insetMedium)
                    CapsuleSearchField("Filter Changed Files", text: .constant(""), keyCap: "⌥⌘F")
                        .controlSize(.large)
                        .frame(width: Metrics.Toolbar.searchWidth)
                    rows[index].1
                    Button {} label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .buttonStyle(.icon)
                }
                .padding(.leading, 16)
                .padding(.trailing, 14)
                .frame(height: Metrics.Toolbar.height - 1)
                Hairline()
            }
        }
        .frame(width: 900)
        .background(Color(espalier: Palette.background))
        assertSnapshot(view, named: "loading", area: "SyncButton")
    }

    // MARK: Progress

    @Test("while a push, pull, or fetch runs, the button and the last fetch stay as they were, and the group doesn't narrow")
    func progressKeepsWidth() {
        let justNow = UIFixtures.minutesAgo(0)
        let fetch = SyncButtonState(kind: .fetch(remote: "origin"), lastFetched: justNow)
        let push = SyncButtonState(kind: .push(remote: "origin", aheadBehind: AheadBehind(ahead: 2, behind: 0), tagsToPush: 0), lastFetched: justNow)
        let pull = SyncButtonState(kind: .pull(remote: "origin", withRebase: true, aheadBehind: AheadBehind(ahead: 2, behind: 3), tagsToPush: 0, canForcePush: true), lastFetched: justNow)
        let publish = SyncButtonState(kind: .publishBranch(isGitHubRepository: false, remote: "origin"), lastFetched: justNow)
        let nothing = AheadBehind(ahead: 0, behind: 0)
        /// The progress `make` gives while an operation runs, half way, with
        /// a last fetch longer ago than the one shown before it started.
        func progress(_ title: String, _ shown: SyncButtonState.Kind?) -> SyncButtonState {
            SyncButtonState(kind: .progress(title: title, description: "Hang on…", value: 0.5, shown: shown), lastFetched: UIFixtures.minutesAgo(45))
        }
        let fetching = progress("Fetching origin", .fetch(remote: "origin"))
        let pushing = progress("Pushing to origin", .push(remote: "origin", aheadBehind: nothing, tagsToPush: 0))
        let pulling = progress("Pulling origin", .pull(remote: "origin", withRebase: true, aheadBehind: nothing, tagsToPush: 0, canForcePush: false))
        let publishing = progress("Pushing to origin", .publishBranch(isGitHubRepository: false, remote: "origin"))
        let refreshing = progress("Refreshing Repository", nil)

        // The button shows the state from before the operation when that
        // offered it, or when it isn't one of the button's; otherwise the
        // operation's.
        #expect(pushing.keeping(push).label == "Push origin ↑2")
        #expect(pulling.keeping(pull).label == "Pull origin with rebase ↓3 ↑2")
        #expect(refreshing.keeping(push).label == "Push origin ↑2")
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

    // MARK: Snapshots

    /// One state per layout: a push's progress on its blue capsule and a
    /// fetch's before git reports a value (light and dark), a count, a
    /// diverged pull's two counts, and a background failure. The other
    /// states differ only in words and symbols (`copy` above).
    nonisolated static let snapshotStates: [String: [SnapshotAppearance]] = [
        "1-progress": SnapshotAppearance.allCases,
        "1-progress-starting": SnapshotAppearance.allCases,
        "8-push": [.light],
        "7-pull-diverged": [.light],
        "9-fetch-failure": [.light],
    ]

    @Test("each layout renders", arguments: SyncButtonTests.snapshotStates.keys.sorted())
    func snapshot(name: String) throws {
        let state = try #require(UIFixtures.syncStates.first { $0.name == name }?.state)
        let appearances = try #require(Self.snapshotStates[name])
        assertSnapshot(SyncButtonView(state).padding(Metrics.insetMedium), named: name, area: "SyncButton", appearances: appearances)
    }
}
