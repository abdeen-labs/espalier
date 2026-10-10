// Every sidebar place routes to its feature's screen, and the window-level
// states route to theirs; the window shows each.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

/// The URLs Clone was asked for.
private final class CloneRequests {
    var urls: [String] = []
}

@Suite("Routing", .offline) @MainActor
struct RoutingTests {
    @Test("every place routes to its screen, and the window renders it")
    func places() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            app.preferences.hasShownWelcomeFlow = true
            #expect(DetailDestination.make(app: app, place: nil) == .getStarted)

            let (local, _) = try await setupRepositoryWithRemote()
            let repository = try await harness.addAndSelect(local, to: app)
            let id = repository.id
            let current = try #require(repository.gitState.tip.branch)

            let expectations: [(SidebarPlace?, DetailDestination)] = [
                (nil, .changes(id)),
                (.changes, .changes(id)),
                (.history, .history(id, .history)),
                (.branch(ref: current.ref), .history(id, .branch(ref: current.ref))),
                (.branch(ref: "refs/remotes/origin/main"), .history(id, .branch(ref: "refs/remotes/origin/main"))),
                (.tag(name: "v1.0"), .history(id, .tag(name: "v1.0"))),
                (.pullRequest(number: 142), .pullRequest(id, number: 142)),
                (.stash(branch: "main"), .stash(id, branch: "main")),
            ]
            let context = WindowContext(app: app)
            context.avatarLoader = MonogramAvatarLoader()
            // The window shows each place's screen: History's places may
            // look alike, but no two screens do.
            var shown: [(screen: String, png: Data)] = []
            for (place, destination) in expectations {
                #expect(DetailDestination.make(app: app, place: place) == destination)
                context.state.select(place, in: id)
                let image = Snapshot.render(
                    MainWindow().windowEnvironment(context),
                    size: CGSize(width: Metrics.Window.minimumWidth, height: Metrics.Window.minimumHeight),
                    appearance: .light
                )
                let png = try #require(image.representation(using: .png, properties: [:]))
                let screen = Self.screen(of: destination)
                for earlier in shown where earlier.screen != screen {
                    #expect(earlier.png != png, "\(String(describing: place)) looks like \(earlier.screen)")
                }
                shown.append((screen, png))
            }

            // The kinds name the inner split's saved width.
            #expect(SidebarPlace.branch(ref: current.ref).kind(currentBranchRef: current.ref) == .history)
            #expect(SidebarPlace.branch(ref: "refs/heads/other").kind(currentBranchRef: current.ref) == .compare)
            #expect(Set(PlaceKind.allCases.map(\.splitAutosaveName)).count == PlaceKind.allCases.count)
            #expect(SidebarPlace.history.showsCommits && !SidebarPlace.changes.showsCommits)
            #expect(SidebarPlace.changes.searchPrompt == "Filter Changed Files")
            #expect(SidebarPlace.stash(branch: "main").searchPrompt == "Filter Stashed Files")

            // No repository selected; a missing repository.
            app.select(nil)
            #expect(DetailDestination.make(app: app, place: .changes) == .noRepositorySelected)
            app.select(.repository(id))
            try FileManager.default.removeItem(atPath: local.path)
            await repository.refresh(reason: .user)
            await app.idle()
            #expect(DetailDestination.make(app: app, place: .changes) == .missing(id))
            await app.idle()
        }
    }

    @Test("a window remembers each repository's place")
    func rememberedPlaces() {
        let state = WindowState()
        let first = RepositoryID()
        let second = RepositoryID()
        #expect(state.lastPlace(for: first) == .changes)
        state.searchText = "loader"
        state.select(.history, in: first)
        #expect(state.searchText.isEmpty)
        state.select(.stash(branch: "main"), in: second)
        #expect(state.lastPlace(for: first) == .history)
        #expect(state.lastPlace(for: second) == .stash(branch: "main"))
    }

    @Test("files and URLs opened from outside become actions")
    func externalActions() {
        let actions = ExternalAction.actions(for: [
            URL(string: "espalier://openRepo/https://github.com/joe/espalier")!,
            URL(filePath: "/Users/joe/Developer/espalier", directoryHint: .isDirectory),
            URL(filePath: "/Users/joe/Developer/desktop", directoryHint: .isDirectory),
        ])
        #expect(actions == [
            .url(URL(string: "espalier://openRepo/https://github.com/joe/espalier")!),
            .folders(["/Users/joe/Developer/espalier", "/Users/joe/Developer/desktop"]),
        ])
    }

    @Test("the open documents and get URL Apple events become actions")
    func appleEvents() {
        func event(_ eventClass: AEEventClass, _ eventID: AEEventID, _ directObject: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(
                eventClass: eventClass,
                eventID: eventID,
                targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            event.setParam(directObject, forKeyword: AEKeyword(keyDirectObject))
            return event
        }

        // Folders opened from the Finder or dropped on the Dock icon.
        let files = NSAppleEventDescriptor.list()
        files.insert(NSAppleEventDescriptor(fileURL: URL(filePath: "/Users/joe/Developer/espalier", directoryHint: .isDirectory)), at: 1)
        files.insert(NSAppleEventDescriptor(fileURL: URL(filePath: "/Users/joe/Developer/desktop", directoryHint: .isDirectory)), at: 2)
        #expect(ExternalAction.actions(forAppleEvent: event(AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments), files))
            == [.folders(["/Users/joe/Developer/espalier", "/Users/joe/Developer/desktop"])])
        let single = NSAppleEventDescriptor(fileURL: URL(filePath: "/Users/joe/Developer/espalier", directoryHint: .isDirectory))
        #expect(ExternalAction.actions(forAppleEvent: event(AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments), single)) == [.folders(["/Users/joe/Developer/espalier"])])

        // An espalier:// link.
        let link = NSAppleEventDescriptor(string: "espalier://openRepo/https://github.com/joe/espalier")
        #expect(ExternalAction.actions(forAppleEvent: event(AEEventClass(kInternetEventClass), AEEventID(kAEGetURL), link))
            == [.url(URL(string: "espalier://openRepo/https://github.com/joe/espalier")!)])

        // Anything else does nothing.
        #expect(ExternalAction.actions(forAppleEvent: event(AEEventClass(kCoreEventClass), AEEventID(kAEPrintDocuments), files)).isEmpty)
    }

    @Test("actions wait for the main window, then run through the app model's entry point")
    func queuedActions() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let context = WindowContext(app: app)
            let bridge = ExternalEventsBridge()

            // A folder opened before the window was up is added and
            // selected once it is.
            let local = try setupEmptyRepository()
            bridge.deliver(.folders([local.path]))
            await bridge.idle()
            #expect(app.repositories.isEmpty)
            bridge.attach(context)
            await bridge.idle()
            #expect(app.repositories.count == 1)
            #expect(app.selection == app.repositories.first.map { .repository($0.id) })

            // A link to a repository that isn't in the list asks Clone for
            // it; one that isn't an action is ignored. Neither is an error.
            let clones = CloneRequests()
            app.preferences.hasShownWelcomeFlow = true
            context.actions.register(.cloneRepository) { action in
                if case .cloneRepository(let url?) = action {
                    clones.urls.append(url)
                }
            }
            bridge.deliver(.url(URL(string: "espalier://openRepo/https://github.com/joe/espalier")!))
            bridge.deliver(.url(URL(string: "espalier://nothing")!))
            await bridge.idle()
            await context.actions.idle()
            #expect(clones.urls == ["https://github.com/joe/espalier"])
            #expect(context.presenter.error == nil)
            await app.idle()
        }
    }

    @Test("the quit guard asks for running operations and unfinished messages")
    func quitGuard() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            #expect(QuitGuard.reasons(app).isEmpty)
            #expect(QuitGuardReasons().alert == nil)

            // Unfinished commit messages, by the repository's name.
            let local = try setupEmptyRepository()
            let repository = try await harness.addAndSelect(local, to: app)
            repository.commit.draft.summary = "Wire the quit guard"
            #expect(QuitGuard.reasons(app).repositoriesWithUnfinishedMessages == [repository.record.displayName])
            repository.commit.draft.summary = ""
            #expect(QuitGuard.reasons(app).isEmpty)
            await app.idle()
        }

        let operation = try #require(QuitGuardReasons(runningOperation: .rebase).alert)
        #expect(operation.title == "Quit while a rebase is running?")
        #expect(operation.message == "Quitting now can leave the repository in an unfinished state.")
        #expect(operation.buttons.map(\.title) == ["Quit Anyway", "Cancel"])

        let drafts = try #require(QuitGuardReasons(repositoriesWithUnfinishedMessages: ["a", "b"]).alert)
        #expect(drafts.title == "Quit with an unfinished commit message?")
        #expect(drafts.message == "Your commit messages in 2 repositories will be lost.")

        let both = try #require(QuitGuardReasons(runningOperation: .pull, repositoriesWithUnfinishedMessages: ["espalier"]).alert)
        #expect(both.title == "Quit while a pull is running?")
        #expect(both.message.hasSuffix("Your commit message in espalier will be lost."))
        // Only operations that write to a repository stop a quit, and each
        // has its phrase.
        for kind in OperationKind.allCases where kind.writesToRepository {
            #expect(kind.runningPhrase != "an operation", "\(kind) has no phrase")
        }
    }

    @Test("the root view shows launching, failure, the welcome flow, and the window")
    func rootView() async throws {
        func png(_ view: some View) throws -> Data {
            let image = Snapshot.render(view, size: CGSize(width: 960, height: 600), appearance: .light)
            return try #require(image.representation(using: .png, properties: [:]))
        }
        // A failure shows its message, as the error's view does.
        let message = "Espalier's bundled Git is missing."
        let failure = try png(RootView(launchError: message))
        #expect(failure == (try png(LaunchErrorView(message: message).frame(minWidth: Metrics.Window.minimumWidth, minHeight: Metrics.Window.minimumHeight))))
        let launching = try png(RootView())
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        // The welcome flow fills the window until it's been shown, then the
        // main window does.
        let welcome = try png(RootView(model: app))
        app.preferences.hasShownWelcomeFlow = true
        let window = try png(RootView(model: app))
        #expect(Set([launching, failure, welcome, window]).count == 4)
        await app.idle()
    }

    /// The screen a destination shows.
    private static func screen(of destination: DetailDestination) -> String {
        switch destination {
        case .changes: "Changes"
        case .history: "History"
        case .pullRequest: "the pull request"
        case .stash: "the stash"
        default: String(describing: destination)
        }
    }
}
