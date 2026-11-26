// What a launch shows before its own statuses load: each worktree as the
// launch before left it (its status, its changed files' names, its commits
// to push, the repository's linked worktrees), replaced by this launch's
// status whatever it tells; when it's saved; and how what's remembered
// joins what's known (`factsRemembering`).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private let told = RepositoryIndicator(head: .branch(name: "main"), aheadBehind: nil, changedFilesCount: 0)
private let remembered = RepositoryIndicator(head: .branch(name: "topic"), aheadBehind: AheadBehind(ahead: 2, behind: 0), changedFilesCount: 3)
private let entry = WorktreeEntry(path: "/work/topic", head: "listed", branch: "refs/heads/topic", isDetached: false, type: .linked, isLocked: false, isPrunable: false)

private let joinCases: [NamedCase<(remembered: [WorktreeFacts], live: [WorktreeFacts], expected: [WorktreeFacts])>] = [
    NamedCase("nothing remembered: what's known, as it is", (
        remembered: [],
        live: [WorktreeFacts(path: "/work/app", isCurrent: true)],
        expected: [WorktreeFacts(path: "/work/app", isCurrent: true)]
    )),
    NamedCase("a worktree no status has told of takes its remembered indicator, tip, and entry", (
        remembered: [WorktreeFacts(path: "/work/app", entry: entry, isCurrent: true, indicator: remembered, tip: "abc")],
        live: [WorktreeFacts(path: "/work/app/", isCurrent: true)],
        expected: [WorktreeFacts(path: "/work/app/", entry: entry, isCurrent: true, indicator: remembered, tip: "abc")]
    )),
    NamedCase("a worktree this launch has listed keeps its entry and its tip", (
        remembered: [WorktreeFacts(path: "/work/topic", isCurrent: false, indicator: remembered, tip: "abc")],
        live: [
            WorktreeFacts(path: "/work/app", isCurrent: true, indicator: told),
            WorktreeFacts(path: "/work/topic", entry: entry, isCurrent: false, tip: "listed"),
        ],
        expected: [
            WorktreeFacts(path: "/work/app", isCurrent: true, indicator: told),
            WorktreeFacts(path: "/work/topic", entry: entry, isCurrent: false, indicator: remembered, tip: "listed"),
        ]
    )),
    NamedCase("a worktree a status has told of keeps what it told", (
        remembered: [WorktreeFacts(path: "/work/app", isCurrent: true, indicator: remembered, tip: "abc")],
        live: [WorktreeFacts(path: "/work/app", isCurrent: true, indicator: told, tip: "def")],
        expected: [WorktreeFacts(path: "/work/app", isCurrent: true, indicator: told, tip: "def")]
    )),
    NamedCase("remembered worktrees that aren't listed yet come after, as linked ones", (
        remembered: [
            WorktreeFacts(path: "/work/topic", entry: entry, isCurrent: false, indicator: remembered, tip: "abc"),
            // The record pointed at this one when it was saved.
            WorktreeFacts(path: "/work/old", isCurrent: true, indicator: remembered),
        ],
        live: [WorktreeFacts(path: "/work/app", isCurrent: true, indicator: told)],
        expected: [
            WorktreeFacts(path: "/work/app", isCurrent: true, indicator: told),
            WorktreeFacts(path: "/work/topic", entry: entry, isCurrent: false, indicator: remembered, tip: "abc"),
            WorktreeFacts(path: "/work/old", isCurrent: false, indicator: remembered),
        ]
    )),
]

@Suite("Remembered work", .offline, .hangGuard(minutes: 5)) @MainActor
struct RememberedWorkTests {
    /// Adds `repository` without selecting it.
    private func add(_ repository: Repository, to app: AppModel) async throws -> RepositoryModel {
        let id = try #require(try await app.addRepositories([repository.path]).added.first)
        return try #require(app.repository(id))
    }

    /// A repository with `README.md` committed.
    private func committedRepository() async throws -> Repository {
        let repository = try setupEmptyRepository()
        try await makeCommit(repository, Tree(entries: [TreeEntry(path: "README.md", contents: "# README\n")]))
        return repository
    }

    /// A loaded app with a selected repository, so the ones a test adds
    /// after it get no status but the ones the test runs or waits for.
    private func launch(_ harness: AppHarness) async throws -> AppModel {
        let app = await harness.loadedApp()
        let selected = try await add(try await committedRepository(), to: app)
        app.select(.repository(selected.id))
        return app
    }

    /// Runs a status pass in the repository and waits for what follows it.
    private func status(_ model: RepositoryModel) async {
        await model.refresh(.status, reason: .fileSystem)
        await model.idle()
    }

    /// The repository's pieces of work.
    private func pieces(_ id: RepositoryID, in app: AppModel) -> [PieceOfWork] {
        app.piecesOfWork.filter { $0.record.id == id }
    }

    /// The piece of work of the worktree the repository's record points at.
    private func piece(_ id: RepositoryID, in app: AppModel) throws -> PieceOfWork {
        let current = pieces(id, in: app).first { $0.isCurrent }
        return try #require(current)
    }

    // MARK: At launch

    @Test("a launch shows each worktree as the launch before left it, with its changed files' names, before any status of its own")
    func shownAtLaunch() async throws {
        let harness = try AppHarness()
        let first = try await launch(harness)
        let repository = try await committedRepository()
        try harness.write("notes.txt", "notes\n", in: repository)
        let model = try await add(repository, to: first)
        await status(model)
        await first.idle()
        let before = try piece(model.id, in: first)
        #expect(before.changedFilesCount == 1)
        #expect(before.changedFilesSample.map(\.path) == ["notes.txt"])
        await first.prepareForTermination()

        let app = await harness.loadedApp()

        // Nothing has told the repository's status in this launch.
        #expect(app.indicators[model.id] == nil)
        let shown = try piece(model.id, in: app)
        #expect(shown.hasStatus)
        #expect(shown.head == before.head)
        #expect(shown.tip == before.tip)
        #expect(shown.changedFilesCount == 1)
        #expect(shown.changedFilesSample == before.changedFilesSample)
        #expect(shown.headline == before.headline)
        #expect(app.board.checkingRepositories.isEmpty)
        await app.idle()
    }

    @Test("the commits to push show at launch too")
    func commitsToPush() async throws {
        let harness = try AppHarness()
        let first = try await launch(harness)
        let (local, _) = try await setupRepositoryWithRemote()
        try await makeCommit(local, Tree(entries: [TreeEntry(path: "new.txt", contents: "new\n")]))
        let model = try await add(local, to: first)
        await status(model)
        await first.idle()
        let before = try piece(model.id, in: first)
        #expect(before.aheadBehind == AheadBehind(ahead: 1, behind: 0))
        #expect(before.unpushedCommitSubjects.count == 1)
        await first.prepareForTermination()

        let app = await harness.loadedApp()

        let shown = try piece(model.id, in: app)
        #expect(shown.aheadBehind == before.aheadBehind)
        #expect(shown.unpushedCommitSubjects == before.unpushedCommitSubjects)
        await app.idle()
    }

    @Test("this launch's status replaces what was remembered, whatever it tells: a change made while quit, and a folder that's gone")
    func replacedByStatus() async throws {
        let harness = try AppHarness()
        let first = try await launch(harness)
        let changedRepository = try await committedRepository()
        let goneRepository = try await committedRepository()
        for repository in [changedRepository, goneRepository] {
            try harness.write("notes.txt", "notes\n", in: repository)
        }
        let changed = try await add(changedRepository, to: first)
        let gone = try await add(goneRepository, to: first)
        await status(changed)
        await status(gone)
        await first.idle()
        await first.prepareForTermination()

        try FileManager.default.removeItem(atPath: POSIXPath.join(changedRepository.path, "notes.txt"))
        try FileManager.default.removeItem(atPath: goneRepository.path)

        let app = await harness.loadedApp()
        #expect(try piece(changed.id, in: app).changedFilesCount == 1)
        #expect(try piece(gone.id, in: app).changedFilesCount == 1)

        // The pass over the repositories that aren't selected.
        await app.background.indicators.refreshNow()
        await app.idle()

        #expect(try piece(changed.id, in: app).hasStatus)
        #expect(try piece(changed.id, in: app).changedFilesCount == 0)
        let gonePiece = try piece(gone.id, in: app)
        #expect(!gonePiece.hasStatus)
        #expect(app.worktreeActivity.rememberedFacts[changed.id] == nil)
        #expect(app.worktreeActivity.rememberedFacts[gone.id] == nil)
    }

    @Test("a repository's linked worktrees show at launch before they're listed, and one removed while quit goes once they are")
    func linkedWorktrees() async throws {
        // With the status icons on, the watchers list each repository's
        // worktrees and run their statuses.
        let harness = try AppHarness(repositoryIndicators: true)
        let first = try await launch(harness)
        let repository = try await committedRepository()
        let directory = try createTempDirectory(prefix: "espalier-worktrees-")
        let (topic, fix) = (POSIXPath.join(realPath(directory), "topic"), POSIXPath.join(realPath(directory), "fix"))
        try await runGit(["worktree", "add", "-b", "topic", topic], repository)
        try await runGit(["worktree", "add", "-b", "fix", fix], repository)
        try harness.write("new.txt", "new\n", in: Repository(path: topic))
        let model = try await add(repository, to: first)
        await harness.scheduler.advance()
        await first.idle()
        let before = pieces(model.id, in: first)
        #expect(before.count == 3)
        #expect(before.allSatisfy { $0.hasStatus })
        #expect(before.first { $0.path == topic }?.changedFilesCount == 1)
        await first.prepareForTermination()

        try await runGit(["worktree", "remove", "--force", fix], repository)

        let app = await harness.loadedApp()

        // Not listed yet in this launch.
        #expect(app.worktreeStatuses[model.id] == nil)
        let shown = pieces(model.id, in: app)
        #expect(Set(shown.map(\.path)) == Set(before.map(\.path)))
        #expect(shown.allSatisfy { $0.hasStatus })
        let currentPaths = shown.filter { $0.isCurrent }.map { $0.path }
        #expect(currentPaths == [model.record.path])
        let shownTopic = try #require(shown.first { $0.path == topic })
        #expect(shownTopic.changedFilesCount == 1)
        #expect(shownTopic.head == .branch(name: "topic"))
        #expect(shownTopic.entry?.branch == "refs/heads/topic")

        await harness.scheduler.advance()
        await app.idle()

        #expect(app.worktreeStatuses[model.id] != nil)
        #expect(Set(pieces(model.id, in: app).map(\.path)) == [model.record.path, topic])
        #expect(app.worktreeActivity.rememberedFacts[model.id] == nil)
    }

    @Test("a repository that went missing shows nothing of what was remembered")
    func missing() async throws {
        let harness = try AppHarness()
        let first = try await launch(harness)
        let repository = try await committedRepository()
        try harness.write("notes.txt", "notes\n", in: repository)
        let model = try await add(repository, to: first)
        await status(model)
        await first.idle()
        first.setMissing(true, for: model.id)
        await first.idle()
        await first.prepareForTermination()

        let app = await harness.loadedApp()

        let shown = try piece(model.id, in: app)
        #expect(!shown.hasStatus)
        #expect(app.worktreeActivity.rememberedFacts[model.id] == nil)
        await app.idle()
    }

    // MARK: Saving

    @Test("a change to what a piece of work is made of is saved a while after it, with nothing else changing")
    func savedOnItsOwn() async throws {
        let harness = try AppHarness(backgroundServices: [.worktreeActivityAutosave])
        let app = try await launch(harness)
        let model = try await add(try await committedRepository(), to: app)
        await status(model)
        await app.idle()
        #expect(harness.scheduler.sleeperCount == 0)

        // A pull request's status changes no snapshot, activity, or pin.
        app.branchPullRequests[RepositoryBranch(repositoryID: model.id, name: "master")] = .noPullRequest
        await harness.scheduler.waitForSleep(of: WorktreeActivityModel.saveDelay)
        await harness.scheduler.advance(by: WorktreeActivityModel.saveDelay)
        await waitUntilObserved { app.worktreeActivity.isFlushed }

        let saved = try JSONDecoder().decode(
            WorktreeActivityDocument.self,
            from: Data(contentsOf: harness.environment.directories.worktreeActivity)
        )
        let work = try #require(saved.work?.first { $0.repositoryID == model.id })
        #expect(work.worktrees.map(\.pullRequest) == [.noPullRequest])
        await app.prepareForTermination()
    }

    // MARK: Joining what's remembered with what's known

    @Test("what's remembered joins what's known", arguments: joinCases)
    func joins(_ testCase: NamedCase<(remembered: [WorktreeFacts], live: [WorktreeFacts], expected: [WorktreeFacts])>) {
        let (remembered, live, expected) = testCase.value
        #expect(factsRemembering(remembered, in: live, currentPath: "/work/app") == expected)
    }
}
