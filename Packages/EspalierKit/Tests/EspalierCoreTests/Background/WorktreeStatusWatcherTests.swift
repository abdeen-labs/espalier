// Every repository's worktrees and their statuses, kept current: what's
// listed and which worktrees get a status of their own, what a change
// refreshes, worktrees that come and go, and what stops it, on a
// `ManualFileWatcher`, a `ManualScheduler`, and real repositories with
// worktrees git added.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// The statuses the app's hook was called with, in order.
@MainActor
private final class StatusLog {
    private(set) var updates: [WorktreeStatusUpdate] = []

    func record(_ update: WorktreeStatusUpdate) {
        updates.append(update)
    }

    /// The folders of the statuses after the first `count`.
    func paths(after count: Int) -> [String] {
        updates.dropFirst(count).map(\.worktreePath)
    }
}

@Suite("Worktree status watcher", .offline, .hangGuard(minutes: 5)) @MainActor
struct WorktreeStatusWatcherTests {
    /// How long after a burst's last event its status or list is refreshed.
    private let quiet = RepositoryIndicatorWatcher.configuration.quietPeriod

    /// A loaded app with indicators on and two repositories of two commits
    /// each: the selected one, with a linked worktree `aside`, and another,
    /// with linked worktrees `topic` and `fix`. Each worktree is on a new
    /// branch of its name, in a folder outside its repository.
    @MainActor
    private struct Fixture {
        let harness: AppHarness
        let app: AppModel
        let selected: RepositoryModel
        let other: RepositoryModel
        /// The other repository's main worktree.
        let main: String
        let aside: String
        let topic: String
        let fix: String
        /// Where the worktrees are.
        let directory: String
        let log: StatusLog

        var watcher: WorktreeStatusWatcher {
            app.background.indicatorWatcher.worktrees
        }

        var scheduler: ManualScheduler {
            harness.scheduler
        }

        /// The other repository's common directory.
        var commonDirectory: String {
            POSIXPath.join(realPath(main), ".git")
        }

        /// What's published of the worktree at `path`, one of the other
        /// repository's unless `repository` says otherwise.
        func worktree(at path: String, of repository: RepositoryID? = nil) throws -> WorktreeStatus {
            try #require(app.worktreeStatuses[repository ?? other.id]?.first { $0.entry.path == path }, "No worktree at \(path)")
        }

        /// The file system reports changes to `paths`, and the watches take
        /// the events.
        func emit(_ paths: [String], flags: FileWatchEvent.Flags = [.itemModified, .itemIsFile]) async {
            harness.fileWatcher.emit(batch: paths, flags: flags)
            await scheduler.advance()
        }

        /// Adds a worktree named `name` to the other repository with git,
        /// on a new branch of that name, and returns its folder.
        func addWorktree(_ name: String) async throws -> String {
            let path = POSIXPath.join(directory, name)
            try await runGit(["worktree", "add", "-b", name, path], Repository(path: main))
            return path
        }
    }

    /// - Parameter topicFiles: Files written in `topic` before the app
    ///   knows of it.
    private func makeFixture(topicFiles: [String] = []) async throws -> Fixture {
        let harness = try AppHarness(repositoryIndicators: true)
        let app = await harness.loadedApp()
        let log = StatusLog()
        app.onWorktreeStatus = { log.record($0) }

        let directory = try createTempDirectory(prefix: "espalier-worktrees-")
        let selectedRepository = try await setupTwoCommitRepo()
        let otherRepository = try await setupTwoCommitRepo()
        let (aside, topic, fix) = (POSIXPath.join(directory, "aside"), POSIXPath.join(directory, "topic"), POSIXPath.join(directory, "fix"))
        try await runGit(["worktree", "add", "-b", "aside", aside], selectedRepository)
        try await runGit(["worktree", "add", "-b", "topic", topic], otherRepository)
        try await runGit(["worktree", "add", "-b", "fix", fix], otherRepository)
        for file in topicFiles {
            try harness.write(file, "new\n", in: Repository(path: topic))
        }

        let selected = try await harness.addAndSelect(selectedRepository, to: app)
        let id = try #require(try await app.addRepositories([otherRepository.path]).added.first)
        let other = try #require(app.repository(id))
        // The watchers hear of the list's changes, list the worktrees, and
        // run their first statuses.
        await harness.scheduler.advance()
        await app.idle()
        return Fixture(
            harness: harness,
            app: app,
            selected: selected,
            other: other,
            main: otherRepository.path,
            aside: aside,
            topic: topic,
            fix: fix,
            directory: directory,
            log: log
        )
    }

    private func clean(on branch: String, changedFiles: Int = 0) -> RepositoryIndicator {
        RepositoryIndicator(head: .branch(name: branch), aheadBehind: nil, changedFilesCount: changedFiles)
    }

    // MARK: The list

    @Test("lists every repository's worktrees as git does, the selected repository's too, and tells the one its record points at")
    func lists() async throws {
        let fixture = try await makeFixture()
        let (app, selected, other) = (fixture.app, fixture.selected, fixture.other)

        let ofSelected = try #require(app.worktreeStatuses[selected.id])
        #expect(ofSelected.map(\.entry.path) == [selected.record.path, fixture.aside])
        #expect(ofSelected.map(\.isCurrent) == [true, false])

        let listed = try await listWorktrees(other.gitRepository)
        let ofOther = try #require(app.worktreeStatuses[other.id])
        #expect(ofOther.map(\.entry) == listed)
        #expect(ofOther.first?.entry.type == .main)
        #expect(ofOther.map(\.isCurrent) == [true, false, false])
        #expect(Set(ofOther.dropFirst().map(\.entry.path)) == [fixture.topic, fixture.fix])
        #expect(ofOther.allSatisfy { $0.repositoryID == nil })

        #expect(fixture.watcher.watchedRepositoryIDs == [selected.id, other.id])
        // No repository has a watch of its own for its worktrees: they're
        // on the watch every repository shares.
        #expect(fixture.harness.fileWatcher.activeSubscriptions.map(\.paths) == [[realPath(selected.record.path)]])
        #expect(fixture.harness.fileWatcher.activeWatches.count == 1)
        await app.prepareForTermination()
    }

    // MARK: The statuses

    @Test("a worktree no record points at gets its status from its own folder; the record's has its repository's")
    func statuses() async throws {
        let fixture = try await makeFixture(topicFiles: ["new.txt"])
        let (app, other) = (fixture.app, fixture.other)
        #expect(fixture.watcher.watchedWorktreePaths == [fixture.aside, fixture.topic, fixture.fix])

        let topic = try fixture.worktree(at: fixture.topic)
        #expect(topic.indicator == clean(on: "topic", changedFiles: 1))
        #expect(app.indicator(for: topic, of: other.id) == topic.indicator)
        #expect(try fixture.worktree(at: fixture.fix).indicator == clean(on: "fix"))
        #expect(try fixture.worktree(at: fixture.aside, of: fixture.selected.id).indicator == clean(on: "aside"))

        // The record's own worktree: no status of its own.
        let main = try fixture.worktree(at: fixture.main)
        #expect(main.isCurrent)
        #expect(main.indicator == nil)
        #expect(app.indicators[other.id] == clean(on: "master"))
        #expect(app.indicator(for: main, of: other.id) == clean(on: "master"))
        await app.prepareForTermination()
    }

    @Test("each status that loads is reported with its repository, its folder, the status, and its tip")
    func hook() async throws {
        let fixture = try await makeFixture(topicFiles: ["new.txt"])
        let updates = fixture.log.updates
        // The first status of each worktree that has one of its own.
        #expect(updates.map(\.worktreePath).sorted() == [fixture.aside, fixture.topic, fixture.fix].sorted())

        let topic = try #require(updates.first { $0.worktreePath == fixture.topic })
        #expect(topic.repositoryID == fixture.other.id)
        #expect(topic.status.workingDirectory.files.map(\.path) == ["new.txt"])
        #expect(topic.tip.branch?.name == "topic")
        #expect(topic.tip.branch?.tip.sha == topic.status.currentTip)
        #expect(updates.first { $0.worktreePath == fixture.aside }?.repositoryID == fixture.selected.id)
        await fixture.app.prepareForTermination()
    }

    @Test("a change in a worktree's folder refreshes its status, and no other's, a quiet period after the last event")
    func refreshesTheChangedWorktree() async throws {
        let fixture = try await makeFixture()
        let (app, scheduler) = (fixture.app, fixture.scheduler)
        let loaded = fixture.log.updates.count
        let passes = fixture.other.refreshScheduler.passCount

        try fixture.harness.write("new.txt", "new\n", in: Repository(path: fixture.fix))
        fixture.harness.fileWatcher.emit(POSIXPath.join(fixture.fix, "new.txt"))
        // Git says the file isn't ignored; then the quiet period starts.
        await scheduler.waitForSleep(of: quiet)
        await scheduler.advance(by: quiet - .milliseconds(1))
        #expect(try fixture.worktree(at: fixture.fix).indicator == clean(on: "fix"))

        await scheduler.advance(by: .milliseconds(1))
        await app.idle()
        #expect(try fixture.worktree(at: fixture.fix).indicator == clean(on: "fix", changedFiles: 1))
        #expect(fixture.log.paths(after: loaded) == [fixture.fix])
        #expect(try fixture.worktree(at: fixture.topic).indicator == clean(on: "topic"))
        #expect(fixture.other.refreshScheduler.passCount == passes)
        await app.prepareForTermination()
    }

    @Test("a bare repository's own entry is listed, with no status: it has no working tree")
    func bareRepository() async throws {
        let harness = try AppHarness(repositoryIndicators: true)
        let app = await harness.loadedApp()
        let source = try await setupTwoCommitRepo()
        let directory = try createTempDirectory(prefix: "espalier-worktrees-")
        let (bare, first, second) = (POSIXPath.join(directory, "bare.git"), POSIXPath.join(directory, "first"), POSIXPath.join(directory, "second"))
        try await runGit(["clone", "--bare", source.path, bare], source)
        try await runGit(["worktree", "add", "-b", "first", first], Repository(path: bare))
        try await runGit(["worktree", "add", "-b", "second", second], Repository(path: bare))

        let id = try #require(try await app.addRepositories([first]).added.first)
        await harness.scheduler.advance()
        await app.idle()

        let worktrees = try #require(app.worktreeStatuses[id])
        #expect(worktrees.first?.entry.path == bare)
        #expect(worktrees.first?.indicator == nil)
        #expect(worktrees.first { $0.entry.path == first }?.isCurrent == true)
        #expect(worktrees.first { $0.entry.path == second }?.indicator == clean(on: "second"))
        #expect(app.background.indicatorWatcher.worktrees.watchedWorktreePaths == [second])
        await app.prepareForTermination()
    }

    @Test("a worktree whose folder is gone has no indicator, and git's word for it in the list")
    func folderGone() async throws {
        let fixture = try await makeFixture()
        #expect(try fixture.worktree(at: fixture.fix).indicator != nil)

        try FileManager.default.removeItem(atPath: fixture.fix)
        await fixture.emit([fixture.fix], flags: [.rootChanged])
        await fixture.scheduler.advance(by: quiet)
        await fixture.app.idle()

        let fix = try fixture.worktree(at: fixture.fix)
        #expect(fix.indicator == nil)
        #expect(fix.entry.isPrunable)
        #expect(try fixture.worktree(at: fixture.topic).indicator == clean(on: "topic"))
        await fixture.app.prepareForTermination()
    }

    // MARK: Changes to the list

    @Test("a worktree added or removed outside the app joins or leaves the list a quiet period later, with its status")
    func addedAndRemoved() async throws {
        let fixture = try await makeFixture()
        let (app, scheduler) = (fixture.app, fixture.scheduler)
        let common = fixture.commonDirectory

        let late = try await fixture.addWorktree("late")
        await fixture.emit(
            ["worktrees/late", "worktrees/late/gitdir", "worktrees/late/HEAD", "refs/heads/late"].map { POSIXPath.join(common, $0) },
            flags: [.itemCreated, .itemIsFile]
        )
        #expect(app.worktreeStatuses[fixture.other.id]?.count == 3)
        await scheduler.advance(by: quiet)
        await app.idle()
        let listed = try await listWorktrees(fixture.other.gitRepository)
        #expect(listed.count == 4)
        #expect(app.worktreeStatuses[fixture.other.id]?.map(\.entry) == listed)
        #expect(try fixture.worktree(at: late).indicator == clean(on: "late"))
        #expect(fixture.watcher.watchedWorktreePaths.contains(late))

        try await runGit(["worktree", "remove", late], Repository(path: fixture.main))
        await fixture.emit([POSIXPath.join(common, "worktrees/late")], flags: [.itemRemoved, .itemIsDir])
        await scheduler.advance(by: quiet)
        await app.idle()
        #expect(Set(app.worktreeStatuses[fixture.other.id]?.map(\.entry.path) ?? []) == [fixture.main, fixture.topic, fixture.fix])
        #expect(!fixture.watcher.watchedWorktreePaths.contains(late))
        await app.prepareForTermination()
    }

    @Test("a worktree whose HEAD moves to another branch shows it in its entry and in its status")
    func headMoves() async throws {
        let fixture = try await makeFixture()
        let common = fixture.commonDirectory

        try await runGit(["checkout", "-b", "renamed"], Repository(path: fixture.topic))
        await fixture.emit(["worktrees/topic/HEAD", "refs/heads/renamed"].map { POSIXPath.join(common, $0) })
        await fixture.scheduler.advance(by: quiet)
        await fixture.app.idle()

        let topic = try fixture.worktree(at: fixture.topic)
        #expect(topic.entry.branch == "refs/heads/renamed")
        #expect(topic.indicator == clean(on: "renamed"))
        await fixture.app.prepareForTermination()
    }

    @Test("a worktree that's a repository in the list has that repository's indicator, and no status of its own")
    func listedWorktree() async throws {
        let fixture = try await makeFixture()
        let (app, scheduler, other) = (fixture.app, fixture.scheduler, fixture.other)
        let loaded = fixture.log.updates.count

        let id = try #require(try await app.addRepositories([fixture.topic]).added.first)
        await scheduler.advance()
        await app.idle()
        let topic = try fixture.worktree(at: fixture.topic)
        #expect(topic.repositoryID == id)
        #expect(!topic.isCurrent)
        #expect(topic.indicator == nil)
        #expect(app.indicators[id] == clean(on: "topic"))
        #expect(app.indicator(for: topic, of: other.id) == clean(on: "topic"))
        #expect(!fixture.watcher.watchedWorktreePaths.contains(fixture.topic))

        // The new repository has the same worktrees: it points at one, and
        // the main one is the other repository.
        #expect(try fixture.worktree(at: fixture.topic, of: id).isCurrent)
        #expect(try fixture.worktree(at: fixture.main, of: id).repositoryID == other.id)
        // The worktree both list is watched once, for both.
        #expect(try fixture.worktree(at: fixture.fix, of: id).indicator == clean(on: "fix"))
        #expect(fixture.watcher.watchedWorktreePaths == [fixture.aside, fixture.fix])
        #expect(fixture.log.paths(after: loaded).isEmpty)

        // Out of the list again, the worktree gets a status of its own.
        try await app.removeRepository(id, moveToTrash: false, confirmed: [.removeRepository])
        await scheduler.advance()
        await app.idle()
        let again = try fixture.worktree(at: fixture.topic)
        #expect(again.repositoryID == nil)
        #expect(again.indicator == clean(on: "topic"))
        #expect(fixture.log.paths(after: loaded) == [fixture.topic])
        await app.prepareForTermination()
    }

    @Test("a record switched to another worktree: that worktree is its own now, and the one it left gets a status")
    func switched() async throws {
        let fixture = try await makeFixture()
        let (app, other) = (fixture.app, fixture.other)
        let loaded = fixture.log.updates.count

        try await other.worktrees.switchToWorktree(try fixture.worktree(at: fixture.topic).entry)
        await fixture.scheduler.advance()
        await app.idle()

        #expect(other.record.path == fixture.topic)
        let topic = try fixture.worktree(at: fixture.topic)
        #expect(topic.isCurrent)
        #expect(topic.indicator == nil)
        #expect(app.indicator(for: topic, of: other.id) == clean(on: "topic"))
        let main = try fixture.worktree(at: fixture.main)
        #expect(!main.isCurrent)
        #expect(main.indicator == clean(on: "master"))
        #expect(fixture.log.paths(after: loaded) == [fixture.main])
        // The selected repository, which was `selected`, is `other` now.
        #expect(fixture.watcher.watchedWorktreePaths == [fixture.aside, fixture.main, fixture.fix])
        await app.prepareForTermination()
    }

    // MARK: Pausing and stopping

    @Test("runs nothing while the main window isn't visible, and what changed meanwhile once when it is again")
    func windowNotVisible() async throws {
        let fixture = try await makeFixture()
        let (app, scheduler) = (fixture.app, fixture.scheduler)
        let loaded = fixture.log.updates.count

        app.setMainWindowVisible(false)
        #expect(fixture.watcher.isPaused)
        try fixture.harness.write("new.txt", "new\n", in: Repository(path: fixture.fix))
        // Two bursts in the worktree, each past its quiet period, and one
        // that changes the list.
        for _ in 0..<2 {
            await fixture.emit([POSIXPath.join(fixture.commonDirectory, "worktrees/fix/index")])
            await scheduler.advance(by: quiet)
        }
        let late = try await fixture.addWorktree("late")
        await fixture.emit([POSIXPath.join(fixture.commonDirectory, "worktrees/late/HEAD")])
        await scheduler.advance(by: quiet)
        await app.idle()
        #expect(try fixture.worktree(at: fixture.fix).indicator == clean(on: "fix"))
        #expect(app.worktreeStatuses[fixture.other.id]?.count == 3)
        #expect(fixture.log.paths(after: loaded).isEmpty)

        app.setMainWindowVisible(true)
        #expect(!fixture.watcher.isPaused)
        await app.idle()
        #expect(try fixture.worktree(at: fixture.fix).indicator == clean(on: "fix", changedFiles: 1))
        #expect(try fixture.worktree(at: late).indicator == clean(on: "late"))
        #expect(fixture.log.paths(after: loaded) == [fixture.fix, late])
        await app.prepareForTermination()
    }

    @Test("follows the indicators setting: off, nothing is listed or watched; on again, everything is")
    func setting() async throws {
        let fixture = try await makeFixture()
        let (app, scheduler, watcher) = (fixture.app, fixture.scheduler, fixture.watcher)

        app.preferences.repositoryIndicatorsEnabled = false
        // The coordinator hears of the setting.
        await scheduler.advance()
        #expect(!watcher.isRunning)
        #expect(app.worktreeStatuses.isEmpty)
        #expect(watcher.watchedRepositoryIDs.isEmpty)
        #expect(watcher.watchedWorktreePaths.isEmpty)
        #expect(fixture.harness.fileWatcher.activeWatches.isEmpty)

        app.preferences.repositoryIndicatorsEnabled = true
        await scheduler.advance()
        await app.idle()
        #expect(watcher.isRunning)
        #expect(app.worktreeStatuses[fixture.other.id]?.count == 3)
        #expect(try fixture.worktree(at: fixture.topic).indicator == clean(on: "topic"))
        await app.prepareForTermination()
    }

    @Test("a repository that leaves the list takes its worktrees with it")
    func removed() async throws {
        let fixture = try await makeFixture()
        let (app, watcher) = (fixture.app, fixture.watcher)

        try await app.removeRepository(fixture.other.id, moveToTrash: false, confirmed: [.removeRepository])
        await fixture.scheduler.advance()
        await app.idle()
        #expect(app.worktreeStatuses[fixture.other.id] == nil)
        #expect(watcher.watchedRepositoryIDs == [fixture.selected.id])
        #expect(watcher.watchedWorktreePaths == [fixture.aside])
        await app.prepareForTermination()
    }

    @Test("stops at quit")
    func quit() async throws {
        let fixture = try await makeFixture()
        await fixture.app.prepareForTermination()
        #expect(!fixture.watcher.isRunning)
        #expect(fixture.watcher.watchedWorktreePaths.isEmpty)
        #expect(fixture.harness.fileWatcher.activeWatches.isEmpty)
        #expect(fixture.app.worktreeStatuses.isEmpty)
    }
}

@Suite("Worktree status watcher on FSEvents", .offline, .hangGuard(minutes: 5)) @MainActor
struct WorktreeStatusWatcherFSEventsTests {
    @Test("with the file system's own events and the clock running, a worktree git adds, changes, commits in, and removes shows in the list")
    func worktreeComesAndGoes() async throws {
        let harness = try AppHarness(repositoryIndicators: true)
        var environment = harness.environment
        environment.fileWatcher = FSEventsFileWatcher()
        environment.scheduler = SystemScheduler()
        let app = AppModel(environment: environment)
        await app.load()
        _ = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
        let repository = try await setupTwoCommitRepo()
        let id = try #require(try await app.addRepositories([repository.path]).added.first)
        await waitUntilObserved { app.worktreeStatuses[id]?.count == 1 }

        let path = POSIXPath.join(try createTempDirectory(prefix: "espalier-worktrees-"), "topic")
        let worktree = Repository(path: path)
        func listed() -> WorktreeStatus? {
            app.worktreeStatuses[id]?.first { $0.entry.path == path }
        }

        // Git adds a worktree: listed, with its first status.
        try await runGit(["worktree", "add", "-b", "topic", path], repository)
        await waitUntilObserved { listed()?.indicator != nil }
        #expect(listed()?.entry.branch == "refs/heads/topic")
        #expect(listed()?.indicator == RepositoryIndicator(head: .branch(name: "topic"), aheadBehind: nil, changedFilesCount: 0))

        // A file changes in it.
        try harness.write("new.txt", "new\n", in: worktree)
        await waitUntilObserved { listed()?.indicator?.changedFilesCount == 1 }

        // A commit in it: its entry is at the new commit, and it's clean.
        try await runGit(["add", "new.txt"], worktree)
        try await runGit(["commit", "-m", "Add a file"], worktree)
        let head = JSCompat.trim(try await runGit(["rev-parse", "HEAD"], worktree))
        await waitUntilObserved { listed()?.entry.head == head && listed()?.indicator?.changedFilesCount == 0 }
        #expect(listed()?.entry.head == head)

        // Git removes it.
        try await runGit(["worktree", "remove", path], repository)
        await waitUntilObserved { app.worktreeStatuses[id]?.count == 1 }
        #expect(listed() == nil)
        await app.prepareForTermination()
    }
}
