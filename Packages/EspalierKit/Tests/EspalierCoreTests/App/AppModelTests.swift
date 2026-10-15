// The app model's basics: loading, selection and recents, adding
// repositories, missing repositories, indicators, persistence issues, and
// quitting.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("App model", .offline) @MainActor
struct AppModelTests {
    /// Adds `repositories` to `app` without selecting them.
    private func add(_ repositories: [Repository], to app: AppModel) async throws -> [RepositoryID] {
        let result = try await app.addRepositories(repositories.map(\.path))
        try #require(result.added.count == repositories.count)
        return result.added
    }

    @Test("selecting keeps up to three recent repositories, without the current one")
    func recents() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let ids = try await add(try (0..<5).map { _ in try setupEmptyRepository() }, to: app)

        for id in ids {
            app.select(.repository(id))
        }
        #expect(app.selection == .repository(ids[4]))
        #expect(app.recentRepositoryIDs == [ids[3], ids[2], ids[1]])

        // Reselecting changes nothing; selecting a recent one moves it out.
        app.select(.repository(ids[4]))
        #expect(app.recentRepositoryIDs == [ids[3], ids[2], ids[1]])
        app.select(.repository(ids[2]))
        #expect(app.recentRepositoryIDs == [ids[4], ids[3], ids[1]])
        await app.idle()

        let relaunched = await harness.loadedApp()
        #expect(relaunched.recentRepositoryIDs == [ids[4], ids[3], ids[1]])
        #expect(relaunched.selection == .repository(ids[2]))
        await relaunched.idle()
    }

    @Test("selects the stored repository at launch, else the first")
    func restoresSelection() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let ids = try await add([try setupEmptyRepository(), try setupEmptyRepository()], to: app)
        #expect(app.selection == nil)
        await app.idle()

        let first = await harness.loadedApp()
        #expect(first.selection == .repository(ids[0]))
        first.select(.repository(ids[1]))
        await first.idle()

        let second = await harness.loadedApp()
        #expect(second.selection == .repository(ids[1]))
        #expect(second.selectedRepository?.id == ids[1])
        await second.idle()
    }

    @Test("adding reports invalid paths, existing repositories, and top levels")
    func adding() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let notRepository = try createTempDirectory()

        let one = try await app.addRepositories([notRepository])
        #expect(one.added.isEmpty)
        #expect(one.invalidPaths == [notRepository])

        // A folder inside a repository adds the repository.
        let repository = try setupEmptyRepository()
        let folder = POSIXPath.join(repository.path, "folder")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        let inside = try await app.addRepositories([folder])
        let id = try #require(inside.added.first)
        #expect(app.record(id)?.path == repository.path)
        #expect(app.record(id)?.gitDir == POSIXPath.join(repository.path, ".git"))

        let again = try await app.addRepositories([repository.path])
        #expect(again.added.isEmpty)
        #expect(again.existing == [id])

        // Bare repositories aren't working trees.
        let bare = try await makeBareRemote(from: try await setupTwoCommitRepo())
        let bareResult = try await app.addRepositories([bare.path])
        #expect(bareResult.invalidPaths == [bare.path])
        #expect(app.repositories.map(\.id) == [id])
        await app.idle()
    }

    @Test("a repository whose folder disappeared is marked missing")
    func missing() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let local = try setupEmptyRepository()
        let repository = try await harness.addAndSelect(local, to: app)
        #expect(repository.availability == .available)
        #expect(app.indicators[repository.id] != nil)

        try FileManager.default.removeItem(atPath: local.path)
        await repository.refresh(.full, reason: .user)
        #expect(repository.record.isMissing)
        #expect(repository.availability == .missing)
        #expect(app.indicators[repository.id] == nil)
        // A missing repository isn't refreshed or watched.
        let passes = repository.refreshScheduler.passCount
        app.setActive(false)
        app.setActive(true)
        await app.idle()
        #expect(repository.refreshScheduler.passCount == passes)

        let relaunched = await harness.loadedApp()
        #expect(relaunched.record(repository.id)?.isMissing == true)
        await relaunched.idle()
    }

    @Test("indicators come from the status")
    func indicators() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try Data("a\n".utf8).write(to: URL(filePath: local.path + "/a.txt"))
        try await runGit(["add", "a.txt"], local)
        try await runGit(["commit", "-m", "Ahead"], local)
        try Data("b\n".utf8).write(to: URL(filePath: local.path + "/b.txt"))

        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await harness.addAndSelect(local, to: app)
        #expect(app.indicators[repository.id] == RepositoryIndicator(aheadBehind: AheadBehind(ahead: 1, behind: 0), changedFilesCount: 1))
        #expect(repository.gitState.aheadBehind == AheadBehind(ahead: 1, behind: 0))
        #expect(repository.gitState.localCommitSHAs.count == 1)
        await app.idle()
    }

    @Test("a status refresh loads the local commits again when they were loaded for another tip")
    func localCommitsFollowTheTip() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try Data("a\n".utf8).write(to: URL(filePath: local.path + "/a.txt"))
        try await runGit(["add", "a.txt"], local)
        try await runGit(["commit", "-m", "Ahead"], local)

        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await harness.addAndSelect(local, to: app)
        #expect(repository.gitState.localCommitSHAs.count == 1)

        // As after a pass that applied this tip's status, then was
        // superseded before its refs loaded: the local commits are another
        // tip's, and the status shows no change of tip.
        repository.gitState.localCommitSHAs = []
        repository.gitState.refsTip = RefsTip(.unknown)
        await repository.refresh(.status, reason: .user)
        // The refresh returns once the status lands; its refs follow.
        await app.idle()
        #expect(repository.gitState.localCommitSHAs.count == 1)
    }

    @Test("the refresh loads branches, remotes, tags, stashes, worktrees, the author, and when it last fetched")
    func refreshLoadsEverything() async throws {
        let (local, _) = try await setupRepositoryWithRemote()
        try await runGit(["tag", "v1.0"], local)
        try await runGit(["branch", "topic"], local)
        try await runGit(["checkout", "topic"], local)
        try await runGit(["checkout", "main"], local)
        try await runGit(["fetch", "origin"], local)

        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await harness.addAndSelect(local, to: app)
        let state = repository.gitState
        let head = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], local))

        #expect(state.tip.branch?.name == "main")
        #expect(state.tip.branch?.upstream == "origin/main")
        #expect(state.branches.all.map(\.name) == ["main", "topic"])
        #expect(state.branches.defaultBranch?.name == "main")
        #expect(state.branches.recent.map(\.name) == ["topic"])
        #expect(state.remotes.all.map(\.name) == ["origin"])
        #expect(state.remotes.currentRemote?.name == "origin")
        #expect(state.tags == ["v1.0": head])
        #expect(state.worktrees.count == 1)
        #expect(state.commitAuthor?.name == "Joe Bloggs")
        #expect(state.lastFetched != nil)
        #expect(state.generation > 0)
        #expect(repository.watchedPaths?.workingDirectory == realPath(local.path))
        await app.idle()
    }

    @Test("pull.rebase accepts git's spellings")
    func pullRebase() {
        #expect(parsePullRebase(nil) == nil)
        #expect(parsePullRebase("") == nil)
        for value in ["true", "yes", "on", "1", "TRUE", "merges", "interactive", "i", "m"] {
            #expect(parsePullRebase(value) == true, "\(value)")
        }
        for value in ["false", "no", "off", "0", "False"] {
            #expect(parsePullRebase(value) == false, "\(value)")
        }
        #expect(parsePullRebase("preserve") == nil)
    }

    @Test("a list from a newer version is left alone")
    func newerVersion() async throws {
        let harness = try AppHarness()
        let file = harness.environment.directories.repositoryList
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = #"{"version": 2, "repositories": []}"#
        try Data(contents.utf8).write(to: file)

        let app = await harness.loadedApp()
        #expect(app.persistenceIssue == .repositoryListFromNewerVersion(2))
        _ = try await app.addRepositories([try setupEmptyRepository().path])
        await app.idle()
        #expect(harness.repositoryListContents() == contents)

        app.dismissPersistenceIssue()
        #expect(app.persistenceIssue == nil)
    }

    @Test("an unreadable list is moved aside")
    func unreadable() async throws {
        let harness = try AppHarness()
        let file = harness.environment.directories.repositoryList
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)

        let app = await harness.loadedApp()
        guard case .repositoryListUnreadable(let movedTo)? = app.persistenceIssue else {
            Issue.record("Unexpected issue \(String(describing: app.persistenceIssue))")
            return
        }
        #expect(FileManager.default.fileExists(atPath: movedTo.path(percentEncoded: false)))
        #expect(app.repositories.isEmpty)
    }

    @Test("quitting stops watching and the services, and writes the list")
    func termination() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repository = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
        #expect(harness.fileWatcher.activeSubscriptions.count == 1)

        await app.prepareForTermination()
        #expect(harness.fileWatcher.activeSubscriptions.isEmpty)
        #expect(!app.background.indicators.isRunning)
        #expect(harness.repositoryListContents()?.contains(repository.id.description) == true)
    }
}
