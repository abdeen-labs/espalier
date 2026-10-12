// The repository list's methods (adding, removing, aliases, relocating,
// checking again, trusting, and the welcome state)
// against real repositories: linked worktrees and
// submodules, Git LFS, the association, unsafe repositories, the Trash,
// removal's cleanup, and relocation.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("Repository list", .offline) @MainActor
struct RepositoryListTests {
    // MARK: Adding

    @Test("adds a linked worktree with its git directory and its main worktree, apart from the main one")
    func addsLinkedWorktree() async throws {
        let main = try await setupTwoCommitRepo()
        let worktree = POSIXPath.join(try createTempDirectory(), "feature")
        try await runGit(["worktree", "add", "-b", "feature", worktree], main)

        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let result = try await app.addRepositories([worktree, main.path])
        #expect(result.added.count == 2)
        let worktreeRecord = try #require(app.record(result.added[0]))
        #expect(worktreeRecord.path == worktree)
        #expect(worktreeRecord.gitDir == POSIXPath.join(main.path, ".git", "worktrees", "feature"))
        #expect(worktreeRecord.mainWorktreePath == main.path)
        let mainRecord = try #require(app.record(result.added[1]))
        #expect(mainRecord.path == main.path)
        #expect(mainRecord.mainWorktreePath == main.path)
        await app.idle()
    }

    @Test("adds a submodule as a repository of its own")
    func addsSubmodule() async throws {
        let parent = try await setupTwoCommitRepo()
        let module = try await setupTwoCommitRepo()
        try await runGit(["-c", "protocol.file.allow=always", "submodule", "add", module.path, "lib"], parent)
        let submodule = POSIXPath.join(parent.path, "lib")

        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let result = try await app.addRepositories([POSIXPath.join(submodule, ".")])
        let record = try #require(result.added.first.flatMap(app.record))
        #expect(record.path == submodule)
        #expect(record.gitDir == POSIXPath.join(parent.path, ".git", "modules", "lib"))
        await app.idle()
    }

    @Test("loads an added repository's remotes, associates it with GitHub, and tells whether it uses Git LFS")
    func addLoadsRemotesAssociationAndLFS() async throws {
        let repository = try await setupTwoCommitRepo()
        try await runGit(["remote", "add", "origin", "https://github.com/octocat/app.git"], repository)
        let plain = try setupEmptyRepository()
        _ = try await Dugite.exec(["lfs", "track", "*.psd"], repository.path)

        let harness = try AppHarness()
        let app = await harness.loadedApp()
        try await harness.signIn([testAccount], to: app)
        harness.gitHub.on("GET", "/repos/octocat/app", respond: .json(encoding: APIFullRepository(
            repository: createMockAPIRepository(
                cloneURL: "https://github.com/octocat/app.git",
                htmlURL: "https://github.com/octocat/app",
                name: "app",
                owner: createMockAPIIdentity(login: "octocat")
            ),
            permissions: APIRepositoryPermissions(admin: false, push: true, pull: true)
        )))

        let result = try await app.addRepositories([repository.path, plain.path])
        let id = try #require(result.added.first)
        #expect(result.repositories == result.added)
        #expect(result.usingLFS == [id])
        #expect(app.record(id)?.gitHubRepository?.fullName == "octocat/app")
        #expect(app.record(id)?.gitHubRepository?.permissions == .write)
        #expect(app.repository(id)?.gitState.remotes.all.map(\.name) == ["origin"])
        #expect(app.record(result.added[1])?.gitHubRepository == nil)
        await app.idle()
    }

    @Test("reports bare repositories among the invalid paths")
    func bare() async throws {
        let bare = try await makeBareRemote(from: try await setupTwoCommitRepo())
        let harness = try AppHarness()
        let app = await harness.loadedApp()

        let result = try await app.addRepositories([bare.path])
        #expect(result.invalidPaths == [bare.path])
        #expect(result.barePaths == [bare.path])
        #expect(app.repositories.isEmpty)
    }

    @Test("adding the same repository twice at once adds it once")
    func concurrentAdds() async throws {
        let repository = try setupEmptyRepository()
        let harness = try AppHarness()
        let app = await harness.loadedApp()

        async let first = app.addRepositories([repository.path])
        async let second = app.addRepositories([repository.path])
        let results = try await [first, second]
        #expect(app.repositories.count == 1)
        #expect(results.flatMap(\.added).count == 1)
        #expect(results.flatMap(\.existing) == results.flatMap(\.added))
        await app.idle()
    }

    @Test("adds a repository git considers unsafe as missing, with its unsafe folder")
    func addsUnsafe() async throws {
        let repository = try setupEmptyRepository()
        try await withOwnershipCheck { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let result = try await app.addRepositories([repository.path])
            let id = try #require(result.unsafe.first)
            #expect(result.added.isEmpty)
            #expect(result.repositories == [id])
            #expect(app.record(id)?.isMissing == true)
            #expect(app.repository(id)?.availability == .unsafe(path: realPath(repository.path)))

            // An alias change keeps what's known about it.
            app.setAlias("Theirs", for: id)
            #expect(app.repository(id)?.availability == .unsafe(path: realPath(repository.path)))

            // Selecting it keeps it unsafe; nothing runs in it.
            app.select(.repository(id))
            await settle(until: { app.repository(id)?.availability == .unsafe(path: realPath(repository.path)) })
            #expect(app.repository(id)?.refreshScheduler.passCount == 0)

            let again = try await app.addRepositories([repository.path])
            #expect(again.existing == [id])
            await app.idle()
        }
    }

    // MARK: Trusting

    @Test("trusts an unsafe repository's folder in the global configuration, then finds it", .hangGuard(minutes: 5))
    func trusts() async throws {
        let repository = try setupEmptyRepository()
        try await withOwnershipCheck { configPath in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let id = try #require(try await app.addRepositories([repository.path]).unsafe.first)
            app.select(.repository(id))

            try await app.trustRepositoryDirectory(id)
            let model = try #require(app.repository(id))
            await waitUntilObserved { model.availability == .available }
            #expect(app.record(id)?.isMissing == false)
            #expect(app.record(id)?.gitDir == POSIXPath.join(repository.path, ".git"))
            let config = try String(contentsOfFile: configPath, encoding: .utf8)
            #expect(config.contains("directory = \(realPath(repository.path))"))
            await app.idle()
            #expect(model.gitState.tip == .unborn(ref: "master"))
            #expect(harness.fileWatcher.activeSubscriptions.count == 1)
        }
    }

    @Test("a repository added as unsafe from a folder inside it is recorded at its top level once trusted")
    func trustRecordsTopLevel() async throws {
        let repository = try setupEmptyRepository()
        let folder = POSIXPath.join(repository.path, "docs")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        try await withOwnershipCheck { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let id = try #require(try await app.addRepositories([folder]).unsafe.first)
            #expect(app.record(id)?.path == folder)

            try await app.trustRepositoryDirectory(id)
            #expect(app.record(id)?.path == repository.path)
            #expect(app.record(id)?.isMissing == false)
            await app.idle()
        }
    }

    // MARK: Removing

    @Test("asks before removing unless the setting is off, and never for a missing repository")
    func removalConfirmation() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try setupEmptyRepository()
        let id = try #require(try await app.addRepositories([repository.path]).added.first)

        let error = await #expect(throws: OperationError.self) {
            try await app.removeRepository(id, moveToTrash: false)
        }
        guard case .confirmationRequired(let confirmation)? = error?.reason else {
            Issue.record("Expected a confirmation, got \(String(describing: error))")
            return
        }
        #expect(confirmation.kind == .removeRepository)
        #expect(app.record(id) != nil)

        app.preferences.confirmRepositoryRemoval = false
        try await app.removeRepository(id, moveToTrash: false)
        #expect(app.record(id) == nil)
        #expect(FileManager.default.fileExists(atPath: repository.path))

        app.preferences.confirmRepositoryRemoval = true
        let missing = try #require(try await app.addRepositories([try setupEmptyRepository().path]).added.first)
        app.setMissing(true, for: missing)
        try await app.removeRepository(missing, moveToTrash: true)
        #expect(app.record(missing) == nil)
        #expect(harness.trash.trashedPaths.isEmpty)
        await app.idle()
    }

    @Test("moves the folder to the Trash, asking first even with confirmations off")
    func trash() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        app.preferences.confirmRepositoryRemoval = false
        let repository = try setupEmptyRepository()
        let model = try await harness.addAndSelect(repository, to: app)

        await #expect(throws: OperationError.self) {
            try await app.removeRepository(model.id, moveToTrash: true)
        }
        #expect(harness.trash.trashedPaths.isEmpty)

        try await app.removeRepository(model.id, moveToTrash: true, confirmed: [.removeRepository])
        #expect(harness.trash.trashedPaths == [repository.path])
        #expect(!FileManager.default.fileExists(atPath: repository.path))
        #expect(app.repositories.isEmpty)
        #expect(app.selection == nil)
        await app.idle()
    }

    @Test("keeps the repository when the Trash fails")
    func trashFails() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
        harness.trash.setFailing(true)

        let error = await #expect(throws: OperationError.self) {
            try await app.removeRepository(model.id, moveToTrash: true, confirmed: [.removeRepository])
        }
        #expect(error?.operation == .removeRepository)
        #expect(app.record(model.id) != nil)
        #expect(app.selection == .repository(model.id))
        #expect(app.repository(model.id) === model)
        #expect(harness.fileWatcher.activeSubscriptions.count == 1)
        await app.idle()
    }

    @Test("refuses to remove a repository while an operation the user started runs in it", .hangGuard(minutes: 5))
    func busy() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        let gate = try await BlockingFetchGate(clone: local)
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(local, to: app)

        let fetch = Task { try await model.sync.fetch() }
        await waitUntilObserved { model.networkOperation?.kind == .fetch }
        let error = await #expect(throws: OperationError.self) {
            try await app.removeRepository(model.id, moveToTrash: false, confirmed: [.removeRepository])
        }
        #expect(error?.reason == .busy(.fetch))
        #expect(app.record(model.id) != nil)
        let relocation = await #expect(throws: OperationError.self) {
            try await app.relocateRepository(model.id, to: local.path)
        }
        #expect(relocation?.reason == .busy(.fetch))

        try gate.open()
        try await fetch.value
        try await app.removeRepository(model.id, moveToTrash: false, confirmed: [.removeRepository])
        #expect(app.repositories.isEmpty)
        await app.idle()
    }

    @Test("removal drops the model, its watcher and indicator, and passes the selection to the most recent repository")
    func removalCleanup() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let ids = try await app.addRepositories([
            try setupEmptyRepository().path,
            try setupEmptyRepository().path,
            try setupEmptyRepository().path,
        ]).added
        app.select(.repository(ids[1]))
        app.select(.repository(ids[0]))
        app.select(.repository(ids[2]))
        await app.idle()
        #expect(app.recentRepositoryIDs == [ids[0], ids[1]])
        let removed = try #require(app.repository(ids[2]))
        #expect(app.indicators[ids[2]] != nil)
        app.updateRecord(ids[2]) { $0.tagsToPush = ["v1"] }

        try await app.removeRepository(ids[2], moveToTrash: false, confirmed: [.removeRepository])
        #expect(app.repository(ids[2]) == nil)
        #expect(app.models[ids[2]] == nil)
        #expect(removed.app == nil)
        #expect(app.indicators[ids[2]] == nil)
        // The most recent repository, not the first in the list.
        #expect(app.selection == .repository(ids[0]))
        #expect(app.recentRepositoryIDs == [ids[1]])
        await app.idle()
        #expect(harness.fileWatcher.activeSubscriptions.count == 1)

        // Its refreshes no longer reach the list.
        removed.requestRefresh(.full, reason: .user)
        await removed.idle()
        #expect(app.indicators[ids[2]] == nil)
        #expect(harness.repositoryListContents()?.contains(ids[2].description) == false)

        // Removing it again does nothing.
        try await app.removeRepository(ids[2], moveToTrash: false)
        await app.idle()
    }

    // MARK: Alias

    @Test("an alias changes only the name shown; an empty one removes it")
    func alias() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
        model.commit.draft.summary = "Work in progress"
        let passes = model.refreshScheduler.passCount

        app.setAlias("Work", for: model.id)
        #expect(app.repository(model.id) === model)
        #expect(model.record.alias == "Work")
        #expect(model.record.displayName == "Work")
        #expect(model.commit.draft.summary == "Work in progress")
        #expect(model.refreshScheduler.passCount == passes)
        await app.idle()

        // The alias is saved with the list.
        let relaunched = await harness.loadedApp()
        #expect(relaunched.record(model.id)?.alias == "Work")
        await relaunched.idle()

        app.setAlias("", for: model.id)
        #expect(model.record.alias == nil)
        await app.idle()
    }

    // MARK: Relocating

    @Test("relocating a missing repository to where it moved finds it again, keeping its drafts", .hangGuard(minutes: 5))
    func relocate() async throws {
        let repository = try await setupTwoCommitRepo()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(repository, to: app)
        model.commit.draft.summary = "Draft"
        let moved = POSIXPath.join(try createTempDirectory(), "moved")
        try FileManager.default.moveItem(atPath: repository.path, toPath: moved)
        await model.refresh(.full, reason: .user)
        #expect(model.record.isMissing)

        try await app.relocateRepository(model.id, to: POSIXPath.join(moved, "."))
        #expect(model.record.path == moved)
        #expect(model.record.gitDir == POSIXPath.join(moved, ".git"))
        #expect(model.record.mainWorktreePath == moved)
        #expect(!model.record.isMissing)
        await waitUntilObserved { model.availability == .available }
        await app.idle()
        #expect(model.gitState.tip.branch?.name == "master")
        #expect(model.commit.draft.summary == "Draft")
        #expect(harness.fileWatcher.activeSubscriptions.count == 1)
    }

    @Test("relocating refuses a folder that isn't a repository, and one already in the list")
    func relocateRefusals() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let ids = try await app.addRepositories([try setupEmptyRepository().path, try setupEmptyRepository().path]).added
        let folder = try createTempDirectory()

        await #expect(throws: OperationError.self) {
            try await app.relocateRepository(ids[0], to: folder)
        }

        let otherPath = try #require(app.record(ids[1])?.path)
        await #expect(throws: OperationError.self) {
            try await app.relocateRepository(ids[0], to: otherPath)
        }
        #expect(app.record(ids[0])?.path != otherPath)
        await app.idle()
    }

    @Test("relocating to an unsafe folder keeps the repository missing, to be trusted")
    func relocateUnsafe() async throws {
        let target = try setupEmptyRepository()
        try await withOwnershipCheck { _ in
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let record = RepositoryRecord(
                path: "/gone/repository",
                gitDir: "/gone/repository/.git",
                mainWorktreePath: "/gone/repository",
                isMissing: true
            )
            app.insertRecord(record)

            try await app.relocateRepository(record.id, to: target.path)
            let relocated = try #require(app.record(record.id))
            #expect(relocated.path == target.path)
            #expect(relocated.isMissing)
            #expect(relocated.gitDir == nil)
            #expect(relocated.mainWorktreePath == nil)
            #expect(app.repository(record.id)?.availability == .unsafe(path: realPath(target.path)))
            await app.idle()
        }
    }

    // MARK: Checking again

    @Test("checking a missing repository again finds it once its folder is back, and activates it when selected", .hangGuard(minutes: 5))
    func checkAgain() async throws {
        let repository = try setupEmptyRepository()
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let model = try await harness.addAndSelect(repository, to: app)
        let aside = POSIXPath.join(try createTempDirectory(), "aside")
        try FileManager.default.moveItem(atPath: repository.path, toPath: aside)
        await model.refresh(.full, reason: .user)
        #expect(model.record.isMissing)
        #expect(harness.fileWatcher.activeSubscriptions.isEmpty)

        await app.checkRepositoryAgain(model.id)
        #expect(model.record.isMissing)
        #expect(model.availability == .missing)

        try FileManager.default.moveItem(atPath: aside, toPath: repository.path)
        await app.checkRepositoryAgain(model.id)
        #expect(!model.record.isMissing)
        await waitUntilObserved { model.availability == .available }
        await app.idle()
        #expect(harness.fileWatcher.activeSubscriptions.count == 1)

        // An available repository is refreshed.
        let passes = model.refreshScheduler.passCount
        await app.checkRepositoryAgain(model.id)
        #expect(model.refreshScheduler.passCount == passes + 1)
        await app.idle()
    }

    // MARK: Selection and the welcome state

    @Test("a clone's selection never enters the recent repositories")
    func cloneSelectionAndRecents() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let ids = try await app.addRepositories([try setupEmptyRepository().path, try setupEmptyRepository().path]).added
        app.select(.repository(ids[0]))
        app.select(.clone(CloneID()))
        app.select(.repository(ids[1]))
        #expect(app.recentRepositoryIDs.isEmpty)
        app.select(.repository(ids[0]))
        #expect(app.recentRepositoryIDs == [ids[1]])
        await app.idle()
    }

    @Test("the welcome flow shows until it ends, for good")
    func welcome() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        #expect(app.isShowingWelcomeFlow)
        #expect(app.repositories.isEmpty)

        app.endWelcomeFlow()
        #expect(!app.isShowingWelcomeFlow)
        #expect(harness.defaults.defaults.bool(forKey: PreferenceKey.hasShownWelcomeFlow))
        let relaunched = await harness.loadedApp()
        #expect(!relaunched.isShowingWelcomeFlow)
    }
}
