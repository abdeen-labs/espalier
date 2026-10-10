// Ported from desktop/app/test/unit/repositories-store-test.ts
// Tests of the repository list document: the app model's record changes,
// and "reloading" as a relaunched app reading the document. Plus removal
// and a worktree switch onto a path already in the list.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport

@Suite("RepositoriesStore", .offline) @MainActor
struct RepositoriesStoreTests {
    /// A new app on the same list, after `app` wrote it.
    private func reloaded(_ harness: AppHarness, _ app: AppModel) async -> AppModel {
        await app.idle()
        return await harness.loadedApp()
    }

    /// Adds a record only: no model, no git.
    private func addRepository(_ app: AppModel, _ path: String, _ gitDir: String) -> RepositoryID {
        let record = RepositoryRecord(path: path, gitDir: gitDir)
        app.insertRecord(record)
        return record.id
    }

    @Test("adding a new repository: contains the added repository")
    func addingContains() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let repoPath = "/some/cool/path"
        _ = addRepository(app, repoPath, POSIXPath.join(repoPath, ".git"))

        let repositories = await reloaded(harness, app).repositories
        #expect(repositories[0].path == repoPath)
        #expect(repositories[0].gitDir == "/some/cool/path/.git")
    }

    private let apiRepo = APIFullRepository(
        repository: APIRepository(
            cloneURL: "https://github.com/my-user/my-repo",
            sshURL: "git@github.com:my-user/my-repo.git",
            htmlURL: "https://github.com/my-user/my-repo",
            name: "my-repo",
            owner: APIIdentity(
                id: 42,
                login: "my-user",
                avatarURL: "https://github.com/my-user.png",
                htmlURL: "https://github.com/my-user",
                type: .user
            ),
            private: true,
            fork: false,
            defaultBranch: "master",
            pushedAt: "1995-12-17T03:24:00",
            hasIssues: true,
            archived: false
        ),
        parent: nil,
        permissions: APIRepositoryPermissions(admin: false, push: true, pull: true)
    )
    private let endpoint = getDotComAPIEndpoint()

    @Test("updating a GitHub repository: adds a new GitHub repository")
    func addsGitHubRepository() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let id = addRepository(app, "/some/cool/path", "/some/cool/path/.git")
        app.setGitHubRepository(app.upsertGitHubRepository(endpoint, apiRepo), for: id)

        let repositories = await reloaded(harness, app).repositories
        let repo = try #require(repositories[0].gitHubRepository)
        #expect(repo.isPrivate == true)
        #expect(!repo.fork)
        #expect(repo.htmlURL == "https://github.com/my-user/my-repo")
        #expect(repo.permissions == .write)
    }

    @Test("updating a GitHub repository: reuses an existing GitHub repository")
    func reusesGitHubRepository() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let first = addRepository(app, "/some/cool/path", "/some/cool/path/.git")
        app.setGitHubRepository(app.upsertGitHubRepository(endpoint, apiRepo), for: first)
        let second = addRepository(app, "/some/other/path", "/some/other/path/.git")
        app.setGitHubRepository(app.upsertGitHubRepository(endpoint, apiRepo), for: second)

        let firstRepo = try #require(app.record(first)?.gitHubRepository)
        let secondRepo = try #require(app.record(second)?.gitHubRepository)
        #expect(firstRepo.dbID == secondRepo.dbID)

        let relaunched = await reloaded(harness, app)
        #expect(relaunched.repositories.compactMap(\.gitHubRepository?.dbID) == [firstRepo.dbID, firstRepo.dbID])
    }

    private let mainPath = "/some/cool/path"
    private let worktreePath = "/some/cool/path-wt-a"
    private var worktreeGitDir: String {
        POSIXPath.join(mainPath, ".git/worktrees/path-wt-a")
    }

    @Test("switching worktrees: persists the main worktree path")
    func switchPersistsMainWorktree() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let id = addRepository(app, mainPath, POSIXPath.join(mainPath, ".git"))

        app.switchWorktree(id, to: worktreePath, missing: false, gitDir: worktreeGitDir, mainWorktreePath: mainPath)

        let reloaded = try #require(await reloaded(harness, app).repositories.first)
        #expect(reloaded.id == id)
        #expect(reloaded.path == worktreePath)
        #expect(reloaded.mainWorktreePath == mainPath)
        #expect(reloaded.gitDir == worktreeGitDir)
    }

    @Test("switching worktrees: keeps the main worktree path when switching between worktrees")
    func switchKeepsMainWorktree() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let id = addRepository(app, mainPath, POSIXPath.join(mainPath, ".git"))

        app.switchWorktree(id, to: worktreePath, missing: false, gitDir: worktreeGitDir, mainWorktreePath: mainPath)

        // Switching on to a second worktree doesn't re-resolve the main
        // worktree, so it has to survive without being passed again.
        app.switchWorktree(id, to: "/some/cool/path-wt-b", missing: false, gitDir: POSIXPath.join(mainPath, ".git/worktrees/path-wt-b"))

        let reloaded = try #require(await reloaded(harness, app).repositories.first)
        #expect(reloaded.mainWorktreePath == mainPath)
    }

    @Test("switching worktrees: onto a path another repository has changes nothing and names it")
    func switchOntoExisting() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let id = addRepository(app, mainPath, POSIXPath.join(mainPath, ".git"))
        let other = addRepository(app, worktreePath, worktreeGitDir)

        let result = app.switchWorktree(id, to: "/some/cool/./path-wt-a", gitDir: worktreeGitDir, mainWorktreePath: mainPath)
        #expect(result.id == other)
        #expect(result.existingRepository)
        #expect(app.record(id)?.path == mainPath)
        #expect(app.record(id)?.mainWorktreePath == nil)
    }

    /// The repository on its first worktree, as after a switch.
    private func onWorktree(_ app: AppModel) -> RepositoryID {
        let id = addRepository(app, mainPath, POSIXPath.join(mainPath, ".git"))
        app.switchWorktree(id, to: worktreePath, missing: false, gitDir: worktreeGitDir, mainWorktreePath: mainPath)
        return id
    }

    @Test("relocating a repository: updates the main worktree path")
    func relocateUpdatesMainWorktree() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        // Relocating moves the whole repository, so the previously recorded
        // main worktree no longer exists where it used to.
        let movedMain = "/moved/path"
        let movedWorktree = "/moved/path-wt-a"

        app.updateRepositoryPath(
            onWorktree(app),
            path: movedWorktree,
            gitDir: POSIXPath.join(movedMain, ".git/worktrees/path-wt-a"),
            mainWorktreePath: movedMain,
            missing: false
        )

        let reloaded = try #require(await reloaded(harness, app).repositories.first)
        #expect(reloaded.path == movedWorktree)
        #expect(reloaded.mainWorktreePath == movedMain)
    }

    @Test("relocating a repository: clears the main worktree path when it cannot be resolved")
    func relocateClearsMainWorktree() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        // Better to fall back to the git dir lookup than to keep pointing at
        // a location the repository has moved away from.
        app.updateRepositoryPath(onWorktree(app), path: "/moved/path-wt-a", gitDir: nil, mainWorktreePath: nil, missing: true)

        let reloaded = try #require(await reloaded(harness, app).repositories.first)
        #expect(reloaded.mainWorktreePath == nil)
        #expect(reloaded.gitDir == nil)
        #expect(reloaded.isMissing)
    }

    @Test("removing a repository drops its row, recent entry, selection, and the GitHub rows only it referenced")
    func removing() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let parent = APIRepository(
            cloneURL: "https://github.com/upstream/my-repo.git",
            sshURL: "",
            htmlURL: "https://github.com/upstream/my-repo",
            name: "my-repo",
            owner: APIIdentity(id: 7, login: "upstream", avatarURL: "", htmlURL: "", type: .organization),
            private: false,
            fork: false,
            defaultBranch: "main",
            pushedAt: nil,
            hasIssues: true,
            archived: false
        )
        let fork = APIFullRepository(repository: apiRepo.repository, parent: parent, permissions: apiRepo.permissions)
        let keptRepository = try setupEmptyRepository()
        let removedRepository = try setupEmptyRepository()
        let kept = addRepository(app, keptRepository.path, POSIXPath.join(keptRepository.path, ".git"))
        let removed = addRepository(app, removedRepository.path, POSIXPath.join(removedRepository.path, ".git"))
        app.setGitHubRepository(app.upsertGitHubRepository(endpoint, fork), for: removed)
        app.select(.repository(removed))
        app.select(.repository(kept))
        app.select(.repository(removed))
        #expect(app.recentRepositoryIDs == [kept])
        #expect(app.gitHubRepositories.rows.count == 2)

        await app.idle()
        try await app.removeRepository(removed, moveToTrash: false, confirmed: [.removeRepository])
        #expect(app.repositories.map(\.id) == [kept])
        #expect(app.recentRepositoryIDs.isEmpty)
        #expect(app.selection == .repository(kept))
        #expect(app.gitHubRepositories.rows.isEmpty)

        let relaunched = await reloaded(harness, app)
        #expect(relaunched.repositories.map(\.id) == [kept])
        #expect(relaunched.selection == .repository(kept))
        let contents = try #require(harness.repositoryListContents())
        #expect(!contents.contains(removed.description))
        #expect(!contents.contains("my-repo"))
        await relaunched.idle()
    }

    @Test("removing a repository keeps the GitHub rows another repository refers to, and those it didn't")
    func removingKeepsOtherRows() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let first = addRepository(app, "/first", "/first/.git")
        let second = addRepository(app, "/second", "/second/.git")
        let shared = app.upsertGitHubRepository(endpoint, apiRepo)
        app.setGitHubRepository(shared, for: first)
        app.setGitHubRepository(shared, for: second)
        // A row nothing refers to yet, as a pull request's repository is.
        let unrelated = app.upsertGitHubRepositoryLight(endpoint, createMockAPIRepository(name: "unrelated"))

        app.forgetRepository(first)
        #expect(app.gitHubRepositories[shared.dbID] != nil)
        #expect(app.gitHubRepositories[unrelated.dbID] != nil)

        app.forgetRepository(second)
        #expect(app.gitHubRepositories[shared.dbID] == nil)
        #expect(app.gitHubRepositories[unrelated.dbID] != nil)
        await app.idle()
    }
}
