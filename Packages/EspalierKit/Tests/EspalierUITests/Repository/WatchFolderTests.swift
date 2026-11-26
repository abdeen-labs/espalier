// Watch Folder… wherever a repository is added (the File menu, the
// repository popover's Add menu, Home's More menu), what it says it did,
// Stop Watching in Settings ▸ Home, how the watched folders are named, and
// Push All's confirmation listing its branches.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

/// A new, empty folder to watch.
private func makeFolder() throws -> String {
    realPath(try createTempDirectory(prefix: "espalier-watched-"))
}

/// Puts an empty repository at `name` in `folder` and returns its path.
@discardableResult
private func makeRepository(_ name: String, in folder: String) throws -> String {
    let path = POSIXPath.join(folder, name)
    try FileManager.default.createDirectory(atPath: POSIXPath.dirname(path), withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: try setupEmptyRepository().path, toPath: path)
    return path
}

extension MenuContent {
    /// Chooses every item that runs something, submenus' too.
    fileprivate func chooseEveryItem() {
        for entry in entries {
            guard case .item(let item) = entry else {
                continue
            }
            switch item.action {
            case .run(let run): run()
            case .submenu(let content): content.chooseEveryItem()
            }
        }
    }
}

@Suite("Watch Folder", .offline, .hangGuard(minutes: 5)) @MainActor
struct WatchFolderTests {
    /// A loaded app with Home on and one committed repository, selected, and
    /// a window on Home.
    private func makeWindow() async throws -> (AppHarness, AppModel, WindowContext, RepositoryModel) {
        let harness = try AppHarness(showsHome: true)
        let app = await harness.loadedApp()
        app.preferences.hasShownWelcomeFlow = true
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "README.md", contents: "# README\n")]))
        let model = try await harness.addAndSelect(repository, to: app)
        return (harness, app, WindowContext(app: app), model)
    }

    // MARK: Where it's offered

    @Test("Watch Folder is offered beside Add in the File menu, the popover's Add menu, and Home's More menu")
    func offered() async throws {
        let (_, app, context, _) = try await makeWindow()
        let actions = context.actions
        #expect(context.isOnHome)
        #expect(actions.canPerform(.watchFolder))
        #expect(MenuCatalog.file.actions.map(\.kind).contains(.watchFolder))

        var chosen: [ActionKind] = []
        for kind in ActionKind.allCases {
            actions.register(kind) { action in
                chosen.append(action.kind)
            }
        }
        RepositoryAddMenu.content(actions).chooseEveryItem()
        await actions.idle()
        #expect(chosen.contains(.watchFolder))
        #expect(chosen.contains(.addLocalRepository))

        chosen = []
        OverflowMenu.content(ToolbarOffer.make(context).overflow, actions: actions).chooseEveryItem()
        await actions.idle()
        #expect(chosen.contains(.watchFolder))

        // In a repository, the More menu is the repository's.
        context.leaveHome()
        chosen = []
        OverflowMenu.content(ToolbarOffer.make(context).overflow, actions: actions).chooseEveryItem()
        await actions.idle()
        #expect(!chosen.contains(.watchFolder))
        await app.idle()
    }

    @Test("Watch Folder waits while a confirmation shows, as Add does")
    func availability() async throws {
        let (_, app, context, model) = try await makeWindow()
        let id = model.id
        app.preferences.confirmRepositoryRemoval = true
        context.actions.perform(.removeRepository(id))
        await waitUntil { context.presenter.confirmation != nil }
        #expect(!context.actions.canPerform(.watchFolder))
        #expect(!context.actions.canPerform(.addLocalRepository))
        let pending = try #require(context.presenter.confirmation)
        context.presenter.respond(to: pending.id, with: .cancelled)
        await waitUntil { context.presenter.confirmation == nil }
        #expect(context.actions.canPerform(.watchFolder))
        await context.actions.idle()
        await app.idle()
    }

    // MARK: Watching

    @Test("watching one folder and several says how many were added, from the folders that had any")
    func watchSeveral() async throws {
        let (_, app, _, _) = try await makeWindow()
        let first = try makeFolder()
        try makeRepository("one", in: first)
        try makeRepository("two", in: first)
        let second = try makeFolder()
        try makeRepository("three", in: second)
        let empty = try makeFolder()

        let one = await app.watchFolders([first])
        #expect(one.map(\.added.count) == [2])
        #expect(WatchFolderReport(one, folders: app.preferences.watchedFolders, format: app.preferences.numberFormat)?.outcome == .added(2, from: [first]))

        let several = await app.watchFolders([second, empty])
        let report = try #require(WatchFolderReport(several, folders: app.preferences.watchedFolders, format: app.preferences.numberFormat))
        #expect(report.outcome == .added(1, from: [second]))
        #expect(report.tone == .success)
        #expect(app.preferences.watchedFolders == [first, second, empty])
        await app.idle()
    }

    @Test("a folder already watched, one inside a watched folder, and one with no repositories each add nothing, and say so")
    func watchNothingNew() async throws {
        let (_, app, _, _) = try await makeWindow()
        let folder = try makeFolder()
        try makeRepository("group/one", in: folder)
        await app.watchFolders([folder])
        let listed = app.repositories.count

        let again = await app.watchFolders([folder])
        #expect(again == [WatchedFolderResult(folder: folder, wasWatched: true, added: [])])
        #expect(WatchFolderReport(again, folders: app.preferences.watchedFolders, format: app.preferences.numberFormat)?.outcome == .alreadyWatched([folder]))
        #expect(app.preferences.watchedFolders == [folder])

        // Inside a watched folder: watched as its own, its repository
        // already in the list.
        let inside = POSIXPath.join(folder, "group")
        let nested = await app.watchFolders([inside])
        #expect(nested == [WatchedFolderResult(folder: inside, wasWatched: false, added: [])])
        #expect(WatchFolderReport(nested, folders: app.preferences.watchedFolders, format: app.preferences.numberFormat)?.outcome == .noneNew([inside]))
        #expect(app.preferences.watchedFolders == [folder, inside])

        let empty = try makeFolder()
        let none = await app.watchFolders([empty])
        let report = try #require(WatchFolderReport(none, folders: app.preferences.watchedFolders, format: app.preferences.numberFormat))
        #expect(report.outcome == .noneNew([empty]))
        #expect(report.tone == .notice)
        #expect(app.repositories.count == listed)

        #expect(WatchFolderReport([], folders: app.preferences.watchedFolders, format: app.preferences.numberFormat) == nil)
        await app.idle()
    }

    @Test("Stop Watching in Settings ▸ Home stops scanning the folder and keeps its repositories")
    func stopWatching() async throws {
        let (_, app, _, _) = try await makeWindow()
        let folder = try makeFolder()
        try makeRepository("one", in: folder)
        await app.watchFolders([folder])
        let listed = app.repositories.map(\.id)

        let settings = SettingsWindowContext.make(app: app, navigation: SettingsNavigation())
        HomePaneActions(context: settings).stopWatching(folder)
        #expect(app.preferences.watchedFolders.isEmpty)
        #expect(app.repositories.map(\.id) == listed)

        try makeRepository("two", in: folder)
        #expect(await app.rescanWatchedFolders().isEmpty)
        await app.idle()
    }

    @Test("a watched folder goes by its name, or by where it is when another watched folder has that name")
    func names() {
        let folders = ["/Users/joe/Developer", "/Volumes/Work/Developer", "/Users/joe/Projects"]
        let names = WatchedFolderNames(folders)
        #expect(names.name(of: folders[2]) == POSIXPath.basename(folders[2]))
        #expect(names.name(of: folders[0]) != names.name(of: folders[1]))
        #expect(names.name(of: folders[1]) == folders[1])

        // Alone, each goes by its name again.
        #expect(WatchedFolderNames([folders[1], folders[2]]).name(of: folders[1]) == POSIXPath.basename(folders[1]))
    }

    // MARK: Push All

    @Test("Push All's confirmation lists the branches it pushes, the first ten and the rest counted")
    func pushAllList() {
        func pushes(_ count: Int) -> [BranchPush] {
            (1...count).map { index in
                BranchPush(
                    worktree: WorktreeKey(repositoryID: UIFixtures.repositoryID, path: "/Users/joe/Developer/app-\(index)"),
                    repository: "app-\(index)",
                    branch: "feature-\(index)",
                    commits: index
                )
            }
        }
        let few = pushes(3)
        let fewMessage = EspalierCore.Confirmation.pushAll(few).alertContent(defaultNumberFormat).message
        for push in few {
            #expect(fewMessage.contains(push.listLine))
        }

        let many = pushes(12)
        let manyMessage = EspalierCore.Confirmation.pushAll(many).alertContent(defaultNumberFormat).message
        for push in many.prefix(AlertList.maximumItems) {
            #expect(manyMessage.contains(push.listLine))
        }
        for push in many.dropFirst(AlertList.maximumItems) {
            #expect(!manyMessage.contains(push.listLine))
        }
    }
}
