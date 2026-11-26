// The watched folders against real repositories: the setting, adding and
// removing a folder, what a scan adds and what it leaves alone (the
// repositories in the list, the ones the user removed, a folder being cloned
// into), the accounts found repositories get, and when scans start.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

/// A new, empty folder to watch.
private func makeFolder() throws -> String {
    try createTempDirectory(prefix: "espalier-watched-")
}

/// Puts an empty repository at `name` in `folder` and returns its path.
@discardableResult
private func makeRepository(_ name: String, in folder: String) throws -> String {
    let path = POSIXPath.join(folder, name)
    try FileManager.default.createDirectory(atPath: POSIXPath.dirname(path), withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: try setupEmptyRepository().path, toPath: path)
    return path
}

extension AppModel {
    /// Where the repositories in the list are, in order.
    fileprivate var repositoryPaths: [String] {
        repositories.map(\.path)
    }

    /// Becomes active again, as when the user comes back to Espalier.
    fileprivate func reactivate() {
        setActive(false)
        setActive(true)
    }
}

@Suite("Watched folders", .offline, .hangGuard(minutes: 5)) @MainActor
struct WatchedFoldersTests {
    // MARK: The setting

    @Test("the setting keeps absolute paths, standardized, each once, in the order added, and is stored")
    func setting() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let preferences = Preferences(store: PreferenceStore(temporary.defaults))
        #expect(preferences.watchedFolders.isEmpty)

        preferences.watchedFolders = [
            "/Users/me/src/",
            "/Users/me/./Developer/work/..",
            "relative/folder",
            "/Users/me/src",
            // Two folders to the file system, whatever `String` says.
            "/Volumes/" + Cafe.precomposed,
            "/Volumes/" + Cafe.decomposed,
        ]
        let expected = [
            "/Users/me/src",
            "/Users/me/Developer",
            "/Volumes/" + Cafe.precomposed,
            "/Volumes/" + Cafe.decomposed,
        ].map(ExactString.init)
        #expect(preferences.watchedFolders.map(ExactString.init) == expected)

        let reloaded = Preferences(store: PreferenceStore(temporary.defaults))
        #expect(reloaded.watchedFolders.map(ExactString.init) == expected)
    }

    nonisolated static let containingCases: [NamedCase<(path: String, folder: String?)>] = [
        NamedCase("a repository in a watched folder", (path: "/Users/me/Developer/app", folder: "/Users/me/Developer")),
        NamedCase("the deepest of the watched folders it's in", (path: "/Users/me/Developer/work/api", folder: "/Users/me/Developer/work")),
        NamedCase("the watched folder itself", (path: "/Users/me/Developer/work", folder: "/Users/me/Developer/work")),
        NamedCase("a folder whose name only starts like a watched folder's", (path: "/Users/me/Developer/workshop/app", folder: "/Users/me/Developer")),
        NamedCase("a path that isn't standardized", (path: "/Volumes/Code/a/../b/c/", folder: "/Volumes/Code")),
        NamedCase("a path that leaves the watched folder", (path: "/Users/me/Developer/../Documents/app", folder: nil)),
        NamedCase("a folder above a watched folder", (path: "/Users/me", folder: nil)),
    ]

    @Test("finds the watched folder a path is in", arguments: containingCases)
    func containing(_ testCase: NamedCase<(path: String, folder: String?)>) throws {
        let app = try AppHarness().makeApp()
        app.preferences.watchedFolders = ["/Users/me/Developer", "/Volumes/Code", "/Users/me/Developer/work"]

        #expect(app.watchedFolder(containing: testCase.value.path) == testCase.value.folder)
    }

    // MARK: Adding and removing a folder

    @Test("adding a folder watches it and adds the repositories in it, in the order found, without selecting any")
    func addFolder() async throws {
        let folder = try makeFolder()
        let first = try makeRepository("first", in: folder)
        let second = try makeRepository("group/second", in: folder)
        let harness = try AppHarness()
        let app = await harness.loadedApp()

        let added = await app.addWatchedFolder(folder)
        #expect(app.preferences.watchedFolders == [folder])
        #expect(app.repositoryPaths == [first, second])
        #expect(added == app.repositories.map(\.id))
        #expect(app.selection == nil)
        #expect(!app.isScanningFolders)
        #expect(app.watchedFolder(containing: second) == folder)

        // Nor does a scan take the selection from the selected repository.
        let selected = try #require(app.repositories.first?.id)
        app.select(.repository(selected))
        let third = try makeRepository("third", in: folder)
        let rescanned = await app.rescanWatchedFolders()
        #expect(app.repositoryPaths == [first, second, third])
        #expect(rescanned == [app.repositories[2].id])
        #expect(app.selection == .repository(selected))
        await app.idle()
    }

    @Test("a folder added by a path through a symbolic link is watched where it really is, once")
    func addFolderThroughLink() async throws {
        let folder = try makeFolder()
        let repository = try makeRepository("repository", in: folder)
        let link = POSIXPath.join(try createTempDirectory(), "link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: folder)
        let harness = try AppHarness()
        let app = await harness.loadedApp()

        await app.addWatchedFolder(link + "/")
        await app.addWatchedFolder(folder)
        #expect(app.preferences.watchedFolders == [folder])
        #expect(app.repositoryPaths == [repository])
        await app.idle()
    }

    @Test("removing a watched folder keeps its repositories, and stops scanning it")
    func removeFolder() async throws {
        let folder = try makeFolder()
        let first = try makeRepository("first", in: folder)
        let second = try makeRepository("second", in: folder)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        await app.addWatchedFolder(folder)

        app.removeWatchedFolder(folder + "/")
        #expect(app.preferences.watchedFolders.isEmpty)
        #expect(app.repositoryPaths == [first, second])

        try makeRepository("third", in: folder)
        #expect(await app.rescanWatchedFolders().isEmpty)
        #expect(app.repositoryPaths == [first, second])
        await app.idle()
    }

    // MARK: What a scan adds

    @Test("never asks which account: a found repository gets the only one that can see it, and none when several might")
    func accounts() async throws {
        let first = dotComAccount(login: "first", id: 11, token: "gho_first")
        let second = dotComAccount(login: "second", id: 12, token: "gho_second")
        // Any question fails the test.
        let harness = try AppHarness()
        try await harness.store(first, second)
        harness.mockUsers([first, second])
        harness.gitHub.on("GET", "/repos/octocat/shared", respond: .json(encoding: apiFullRepository(name: "shared")))
        harness.gitHub.on("GET", "/repos/octocat/private") { request in
            request.header("Authorization") == "Bearer \(second.token)"
                ? .json(encoding: apiFullRepository(name: "private", isPrivate: true))
                : .json(["message": "Not Found"], status: 404)
        }
        let folder = try makeFolder()
        for name in ["private", "shared"] {
            let repository = Repository(path: try makeRepository(name, in: folder))
            try await runGit(["remote", "add", "origin", "https://github.com/octocat/\(name).git"], repository)
        }
        let app = await harness.loadedAppWithAccounts()

        let added = await app.addWatchedFolder(folder)
        try #require(added.count == 2)
        #expect(harness.prompts.history.isEmpty)
        let onlySecondSees = try #require(app.record(added[0]))
        #expect(onlySecondSees.gitHubRepository?.fullName == "octocat/private")
        #expect(onlySecondSees.accountLogin == "second")
        let bothSee = try #require(app.record(added[1]))
        #expect(bothSee.gitHubRepository?.fullName == "octocat/shared")
        #expect(bothSee.accountLogin == nil)
        await settle(app, harness)
    }

    @Test("a repository already in the list isn't added again, by whichever path it was added")
    func nothingTwice() async throws {
        let folder = try makeFolder()
        let byHand = try makeRepository("by-hand", in: folder)
        try makeRepository("through-link", in: folder)
        let found = try makeRepository("found", in: folder)
        let link = POSIXPath.join(try createTempDirectory(), "link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: folder)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let linkedPath = POSIXPath.join(link, "through-link")
        _ = try await app.addRepositories([byHand, linkedPath])

        let added = await app.addWatchedFolder(folder)
        #expect(app.repositoryPaths == [byHand, linkedPath, found])
        #expect(added == [app.repositories[2].id])

        #expect(await app.rescanWatchedFolders().isEmpty)
        #expect(await app.addWatchedFolder(folder).isEmpty)
        #expect(app.repositoryPaths == [byHand, linkedPath, found])

        // Nor when the setting itself names the folder through a link.
        app.preferences.watchedFolders = [link]
        #expect(await app.rescanWatchedFolders().isEmpty)
        #expect(app.repositoryPaths == [byHand, linkedPath, found])
        await app.idle()
    }

    @Test("a repository switched to a linked worktree outside the folder is still in the list, and in its watched folder")
    func switchedToWorktree() async throws {
        let folder = try makeFolder()
        let main = Repository(path: POSIXPath.join(folder, "main"))
        try FileManager.default.moveItem(atPath: try await setupTwoCommitRepo().path, toPath: main.path)
        let worktree = POSIXPath.join(try createTempDirectory(), "feature")
        try await runGit(["worktree", "add", "-b", "feature", worktree], main)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.confirmRepositoryRemoval = false
        let id = try #require(await app.addWatchedFolder(folder).first)
        app.select(.repository(id))
        await app.idle()
        let model = try #require(app.repository(id))
        let entry = try #require(model.worktrees.entries.first { $0.path == worktree })

        try await model.worktrees.switchToWorktree(entry)
        await app.idle()
        #expect(app.repositoryPaths == [worktree])
        #expect(await app.rescanWatchedFolders().isEmpty)
        #expect(app.repositoryPaths == [worktree])
        let record = try #require(app.record(id))
        #expect(app.watchedFolder(containing: record.path) == nil)
        #expect(app.watchedFolder(of: record) == folder)

        // Removed there, its main worktree in the folder doesn't come back.
        try await app.removeRepository(id, moveToTrash: false)
        #expect(await app.rescanWatchedFolders().isEmpty)
        #expect(app.repositories.isEmpty)
        await app.idle()
    }

    @Test("a folder being cloned into is left to its clone")
    func cloneDestination() async throws {
        let folder = try makeFolder()
        let cloning = try makeRepository("cloning", in: folder)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let clone = CloneTask(url: "https://github.com/octocat/cloning.git", path: cloning)
        app.clones.clones.append(clone)

        #expect(await app.addWatchedFolder(folder).isEmpty)
        #expect(app.repositories.isEmpty)

        app.clones.clones.removeAll { $0.id == clone.id }
        #expect(await app.rescanWatchedFolders().count == 1)
        #expect(app.repositoryPaths == [cloning])
        await app.idle()
    }

    @Test("a found repository git considers unsafe is added once, as missing, to be trusted")
    func unsafe() async throws {
        let folder = try makeFolder()
        let repository = try makeRepository("theirs", in: folder)
        try await withOwnershipCheck { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()

            let added = await app.addWatchedFolder(folder)
            let id = try #require(added.first)
            #expect(app.repositoryPaths == [repository])
            #expect(app.record(id)?.isMissing == true)
            #expect(app.repository(id)?.availability == .unsafe(path: repository))

            #expect(await app.rescanWatchedFolders().isEmpty)
            #expect(app.repositories.count == 1)
            await app.idle()
        }
    }

    // MARK: Repositories the user removed

    @Test("a repository the user removed from the list doesn't come back until they add it again")
    func removedStaysOut() async throws {
        let folder = try makeFolder()
        let first = try makeRepository("first", in: folder)
        let second = try makeRepository("second", in: folder)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.confirmRepositoryRemoval = false
        let ids = await app.addWatchedFolder(folder)
        try #require(ids.count == 2)

        try await app.removeRepository(ids[0], moveToTrash: false)
        #expect(await app.rescanWatchedFolders().isEmpty)
        #expect(await app.addWatchedFolder(folder).isEmpty)
        #expect(app.repositoryPaths == [second])

        // Added by hand, it's back.
        let byHand = try #require(try await app.addRepositories([first]).added.first)
        #expect(app.repositoryPaths == [second, first])

        // And it's found like any other from then on: gone from the list
        // while its folder wasn't watched, it's added by the next scan of
        // the folder.
        app.removeWatchedFolder(folder)
        try await app.removeRepository(byHand, moveToTrash: false)
        #expect(app.repositoryPaths == [second])
        #expect(await app.addWatchedFolder(folder).count == 1)
        #expect(app.repositoryPaths == [second, first])
        await app.idle()
    }

    @Test("a repository removed from the list that isn't in a watched folder is found once its folder is watched")
    func removedOutsideWatchedFolders() async throws {
        let folder = try makeFolder()
        let repository = try makeRepository("repository", in: folder)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.confirmRepositoryRemoval = false
        let id = try #require(try await app.addRepositories([repository]).added.first)

        try await app.removeRepository(id, moveToTrash: false)
        #expect(await app.addWatchedFolder(folder).count == 1)
        #expect(app.repositoryPaths == [repository])
        await app.idle()
    }

    // MARK: When scans start

    @Test("a relaunch keeps the watched folders and the removed repositories, and scans in the background once the list has loaded")
    func relaunch() async throws {
        let folder = try makeFolder()
        try makeRepository("first", in: folder)
        let second = try makeRepository("second", in: folder)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.confirmRepositoryRemoval = false
        let ids = await app.addWatchedFolder(folder)
        try #require(ids.count == 2)
        try await app.removeRepository(ids[0], moveToTrash: false)
        await app.idle()
        let third = try makeRepository("third", in: folder)

        let relaunched = harness.makeApp()
        await relaunched.load()
        // The list is there before the scan ends.
        #expect(relaunched.loadState == .ready)
        #expect(relaunched.repositoryPaths == [second])
        #expect(relaunched.isScanningFolders)
        #expect(relaunched.preferences.watchedFolders == [folder])

        await waitUntilObserved { !relaunched.isScanningFolders }
        #expect(relaunched.repositoryPaths == [second, third])
        #expect(relaunched.selection == .repository(ids[1]))
        await relaunched.idle()
    }

    @Test("becoming active scans again only when the last scan was more than five minutes ago")
    func activation() async throws {
        let folder = try makeFolder()
        let first = try makeRepository("first", in: folder)
        let harness = try AppHarness()
        harness.defaults.defaults.set([folder], forKey: PreferenceKey.watchedFolders)
        let app = await harness.loadedApp()
        await app.idle()
        #expect(app.repositoryPaths == [first])
        let second = try makeRepository("second", in: folder)

        app.reactivate()
        await app.idle()
        #expect(app.repositoryPaths == [first])

        await harness.scheduler.advance(by: .seconds(5 * 60))
        app.reactivate()
        await app.idle()
        #expect(app.repositoryPaths == [first])

        await harness.scheduler.advance(by: .seconds(1))
        app.reactivate()
        #expect(app.isScanningFolders)
        await app.idle()
        #expect(app.repositoryPaths == [first, second])

        // That scan counts from when it started.
        try makeRepository("third", in: folder)
        app.reactivate()
        await app.idle()
        #expect(app.repositoryPaths == [first, second])
    }
}
