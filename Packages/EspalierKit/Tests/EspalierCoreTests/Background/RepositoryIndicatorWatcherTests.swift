// The live indicators of the repositories that aren't selected: which
// repositories the app's own watcher watches, the one watch they share,
// when a change refreshes one, and what stops it, on a `ManualFileWatcher`,
// a `ManualScheduler`, and real repositories.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Observation
import Testing
import TestSupport

/// The most of some repositories refreshing at once, counted each time one
/// starts or ends a pass.
@MainActor
private final class RefreshOverlap {
    private(set) var most = 0
    private let models: [RepositoryModel]

    init(_ models: [RepositoryModel]) {
        self.models = models
        observe()
    }

    private func observe() {
        let count = withObservationTracking {
            models.count { $0.isRefreshing }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
        most = max(most, count)
    }
}

@Suite("Repository indicator watcher", .offline, .hangGuard(minutes: 5)) @MainActor
struct RepositoryIndicatorWatcherTests {
    /// How long after a burst's last event its repository is refreshed.
    private let quiet = RepositoryIndicatorWatcher.configuration.quietPeriod
    /// How long after a burst's first event, at most.
    private let longest = RepositoryIndicatorWatcher.configuration.maximumDelay
    /// The selected repository's own watcher's quiet period, which is
    /// shorter.
    private let ownQuiet = WatcherConfiguration.default.quietPeriod

    /// A loaded app with indicators on, a selected repository, and other
    /// repositories in its list.
    @MainActor
    private struct Fixture {
        let harness: AppHarness
        let app: AppModel
        let selected: RepositoryModel
        let others: [RepositoryModel]

        var watcher: RepositoryIndicatorWatcher {
            app.background.indicatorWatcher
        }

        var scheduler: ManualScheduler {
            harness.scheduler
        }

        /// The file system reports a change to `path` in `repository`, and
        /// its watcher takes the event.
        func emit(_ path: String, in repository: RepositoryModel, flags: FileWatchEvent.Flags = [.itemModified, .itemIsFile]) async {
            harness.fileWatcher.emit(POSIXPath.join(realPath(repository.record.path), path), flags: flags)
            await scheduler.advance()
        }
    }

    /// Selects a new repository in a new app, then adds `count` others,
    /// which nothing but the list tells the watcher about.
    private func makeFixture(others count: Int = 1) async throws -> Fixture {
        let harness = try AppHarness(repositoryIndicators: true)
        let app = await harness.loadedApp()
        let selected = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
        var others: [RepositoryModel] = []
        for _ in 0..<count {
            let id = try #require(try await app.addRepositories([try setupEmptyRepository().path]).added.first)
            others.append(try #require(app.repository(id)))
        }
        // The watcher hears of the list's changes, resolves the directories
        // to watch, and runs each repository's first status.
        await harness.scheduler.advance()
        await app.idle()
        return Fixture(harness: harness, app: app, selected: selected, others: others)
    }

    /// An empty repository's indicator, with `count` changed files.
    private func emptyRepository(changedFiles count: Int = 0) -> RepositoryIndicator {
        RepositoryIndicator(head: .unborn(branch: "master"), aheadBehind: nil, changedFilesCount: count)
    }

    @Test("a repository gets its first status as its watch starts; one that has an indicator gets none")
    func firstStatus() async throws {
        let harness = try AppHarness(repositoryIndicators: true)
        let app = await harness.loadedApp()
        _ = try await harness.addAndSelect(try setupEmptyRepository(), to: app)
        let changed = try setupEmptyRepository()
        try harness.write("new.txt", "new\n", in: changed)
        let id = try #require(try await app.addRepositories([changed.path]).added.first)
        let other = try #require(app.repository(id))

        await harness.scheduler.advance()
        await app.idle()
        let watcher = app.background.indicatorWatcher
        #expect(watcher.watchedRepositoryIDs == [id])
        #expect(app.indicators[id] == emptyRepository(changedFiles: 1))
        #expect(other.refreshScheduler.lastPassReasons == [.fileSystem])
        let passes = other.refreshScheduler.passCount

        // Its watch ends and starts again, with the indicator it has:
        // nothing runs.
        app.updateRecord(id) { $0.isMissing = true }
        await harness.scheduler.advance()
        #expect(watcher.watchedRepositoryIDs.isEmpty)
        app.updateRecord(id) { $0.isMissing = false }
        await harness.scheduler.advance()
        await app.idle()
        #expect(watcher.watchedRepositoryIDs == [id])
        #expect(app.indicators[id] == emptyRepository(changedFiles: 1))
        #expect(other.refreshScheduler.passCount == passes)
        await app.prepareForTermination()
    }

    @Test("a change refreshes its repository's status, and no other's, a quiet period after the last event")
    func refreshesTheChangedRepository() async throws {
        let fixture = try await makeFixture(others: 2)
        let (app, scheduler) = (fixture.app, fixture.scheduler)
        let (changed, untouched) = (fixture.others[0], fixture.others[1])
        #expect(fixture.watcher.watchedRepositoryIDs == [changed.id, untouched.id])
        #expect(app.indicators[changed.id] == emptyRepository())
        let changedPasses = changed.refreshScheduler.passCount
        let untouchedPasses = untouched.refreshScheduler.passCount
        let selectedPasses = fixture.selected.refreshScheduler.passCount

        try fixture.harness.write("new.txt", "new\n", in: changed.gitRepository)
        fixture.harness.fileWatcher.emit(POSIXPath.join(realPath(changed.record.path), "new.txt"))
        // Git says the file isn't ignored; then the quiet period starts.
        await scheduler.waitForSleep(of: quiet)
        await scheduler.advance(by: quiet - .milliseconds(1))
        #expect(changed.refreshScheduler.passCount == changedPasses)

        await scheduler.advance(by: .milliseconds(1))
        await app.idle()
        #expect(app.indicators[changed.id] == emptyRepository(changedFiles: 1))
        #expect(changed.refreshScheduler.passCount == changedPasses + 1)
        #expect(changed.refreshScheduler.lastPassScope == .status)
        #expect(changed.refreshScheduler.lastPassReasons == [.fileSystem])
        #expect(untouched.refreshScheduler.passCount == untouchedPasses)
        #expect(app.indicators[untouched.id] == emptyRepository())
        #expect(fixture.selected.refreshScheduler.passCount == selectedPasses)
        await app.prepareForTermination()
    }

    @Test("a burst of events means one status: a quiet period after the last, and no later than the longest delay after the first")
    func burst() async throws {
        let fixture = try await makeFixture()
        let (app, scheduler) = (fixture.app, fixture.scheduler)
        let other = fixture.others[0]
        let passes = other.refreshScheduler.passCount
        // Less than a quiet period apart.
        let gap = quiet * 4 / 5

        // Three writes: each starts the quiet period again.
        await fixture.emit(".git/index", in: other)
        for _ in 0..<2 {
            await scheduler.advance(by: gap)
            await fixture.emit(".git/index", in: other)
        }
        await scheduler.advance(by: quiet - .milliseconds(1))
        #expect(other.refreshScheduler.passCount == passes)
        await scheduler.advance(by: .milliseconds(1))
        await app.idle()
        #expect(other.refreshScheduler.passCount == passes + 1)

        // Writes that never leave a quiet period: the status comes the
        // longest delay after the first, whatever came since.
        await fixture.emit(".git/index", in: other)
        var elapsed = Duration.zero
        while elapsed + gap < longest {
            await scheduler.advance(by: gap)
            elapsed += gap
            await fixture.emit(".git/index", in: other)
        }
        await scheduler.advance(by: longest - elapsed - .milliseconds(1))
        #expect(other.refreshScheduler.passCount == passes + 1)
        await scheduler.advance(by: .milliseconds(1))
        await app.idle()
        #expect(other.refreshScheduler.passCount == passes + 2)

        // The burst is spent: nothing follows it.
        await scheduler.advance(by: longest)
        await app.idle()
        #expect(other.refreshScheduler.passCount == passes + 2)
        await app.prepareForTermination()
    }

    @Test("events that can't change the status refresh nothing", arguments: [
        NamedCase("an object git wrote", ".git/objects/ab/cdef"),
        NamedCase("a lock file", ".git/index.lock"),
        NamedCase("a reflog", ".git/logs/HEAD"),
        NamedCase("the configuration", ".git/config"),
        NamedCase("a fetch's FETCH_HEAD", ".git/FETCH_HEAD"),
    ])
    func filtered(_ testCase: NamedCase<String>) async throws {
        let fixture = try await makeFixture()
        let other = fixture.others[0]
        let passes = other.refreshScheduler.passCount

        await fixture.emit(testCase.value, in: other)
        await fixture.scheduler.advance(by: longest)
        await fixture.app.idle()

        #expect(fixture.watcher.changedRepositoryIDs.isEmpty)
        #expect(other.refreshScheduler.passCount == passes)
        await fixture.app.prepareForTermination()
    }

    @Test("a file git ignores refreshes nothing")
    func ignoredFile() async throws {
        let fixture = try await makeFixture()
        let other = fixture.others[0]
        try fixture.harness.write(".gitignore", "build/\n", in: other.gitRepository)
        try fixture.harness.write("build/output.o", "output\n", in: other.gitRepository)
        let passes = other.refreshScheduler.passCount

        // The ignored file calls for nothing. FETCH_HEAD, which waits behind
        // the check of it, starts a quiet period to wait on, and calls for
        // no status.
        let root = realPath(other.record.path)
        fixture.harness.fileWatcher.emit(POSIXPath.join(root, "build/output.o"))
        fixture.harness.fileWatcher.emit(POSIXPath.join(root, ".git/FETCH_HEAD"))
        await fixture.scheduler.waitForSleep(of: quiet)
        await fixture.scheduler.advance(by: longest)
        await fixture.app.idle()

        #expect(fixture.watcher.changedRepositoryIDs.isEmpty)
        #expect(other.refreshScheduler.passCount == passes)
        await fixture.app.prepareForTermination()
    }

    @Test("changed repositories are refreshed one at a time")
    func oneAtATime() async throws {
        let fixture = try await makeFixture(others: 3)
        let others = fixture.others
        let passes = others.map(\.refreshScheduler.passCount)
        let overlap = RefreshOverlap(others)

        // All three change at once.
        fixture.harness.fileWatcher.emit(batch: others.map { POSIXPath.join(realPath($0.record.path), ".git/index") })
        await fixture.scheduler.advance()
        await fixture.scheduler.advance(by: quiet)
        await fixture.app.idle()

        #expect(others.map(\.refreshScheduler.passCount) == passes.map { $0 + 1 })
        #expect(others.allSatisfy { fixture.app.indicators[$0.id] != nil })
        #expect(overlap.most == 1)
        await fixture.app.prepareForTermination()
    }

    @Test("a repository with an operation running is refreshed once the operation has ended")
    func waitsForOperations() async throws {
        let fixture = try await makeFixture()
        let other = fixture.others[0]
        let passes = other.refreshScheduler.passCount

        // A network operation: nothing holds the repository's refreshes.
        let gate = AsyncGate()
        let descriptor = OperationDescriptor(kind: .fetch, lanes: [.network], policy: .background, refreshAfter: [])
        let operation = Task {
            try await other.perform(descriptor) { _ in
                await gate.wait()
            }
        }
        try await gate.waitUntilWaiting()

        await fixture.emit(".git/index", in: other)
        await fixture.scheduler.advance(by: quiet)
        // The watcher has been through what changed, and left it alone.
        await fixture.watcher.refreshing?.value
        #expect(fixture.watcher.changedRepositoryIDs.isEmpty)
        #expect(other.refreshScheduler.passCount == passes)
        #expect(other.networkOperation != nil)

        gate.open()
        try await operation.value
        await fixture.app.idle()
        #expect(other.refreshScheduler.passCount == passes + 1)
        #expect(other.refreshScheduler.lastPassReasons == [.fileSystem])
        #expect(fixture.app.indicators[other.id] != nil)
        await fixture.app.prepareForTermination()
    }

    @Test("refreshes nothing while the main window isn't visible, and each repository that changed meanwhile once when it is again")
    func windowNotVisible() async throws {
        let fixture = try await makeFixture(others: 2)
        let (app, scheduler) = (fixture.app, fixture.scheduler)
        let (changed, untouched) = (fixture.others[0], fixture.others[1])
        let changedPasses = changed.refreshScheduler.passCount
        let untouchedPasses = untouched.refreshScheduler.passCount

        app.setMainWindowVisible(false)
        #expect(fixture.watcher.isPaused)
        try fixture.harness.write("new.txt", "new\n", in: changed.gitRepository)
        // Two bursts, each past its quiet period.
        await fixture.emit(".git/index", in: changed)
        await scheduler.advance(by: quiet)
        await fixture.emit(".git/HEAD", in: changed)
        await scheduler.advance(by: quiet)
        await app.idle()
        #expect(fixture.watcher.changedRepositoryIDs == [changed.id])
        #expect(changed.refreshScheduler.passCount == changedPasses)
        #expect(app.indicators[changed.id] == emptyRepository())

        app.setMainWindowVisible(true)
        #expect(!fixture.watcher.isPaused)
        await app.idle()
        #expect(fixture.watcher.changedRepositoryIDs.isEmpty)
        #expect(changed.refreshScheduler.passCount == changedPasses + 1)
        #expect(app.indicators[changed.id] == emptyRepository(changedFiles: 1))
        #expect(untouched.refreshScheduler.passCount == untouchedPasses)
        await app.prepareForTermination()
    }

    @Test("goes on refreshing while the app is inactive with its main window visible")
    func inactiveAndVisible() async throws {
        let fixture = try await makeFixture()
        let (app, scheduler) = (fixture.app, fixture.scheduler)
        let other = fixture.others[0]
        let passes = other.refreshScheduler.passCount

        app.setActive(false)
        #expect(!fixture.watcher.isPaused)
        try fixture.harness.write("new.txt", "new\n", in: other.gitRepository)
        await fixture.emit(".git/index", in: other)
        await scheduler.advance(by: quiet)
        await app.idle()
        #expect(other.refreshScheduler.passCount == passes + 1)
        #expect(app.indicators[other.id] == emptyRepository(changedFiles: 1))
        await app.prepareForTermination()
    }

    @Test("the selected repository has its model's watcher, not this one; a selection change hands both over")
    func selection() async throws {
        let fixture = try await makeFixture()
        let (app, scheduler, watcher) = (fixture.app, fixture.scheduler, fixture.watcher)
        let (first, second) = (fixture.selected, fixture.others[0])
        #expect(watcher.watchedRepositoryIDs == [second.id])
        #expect(first.watcher.isWatching)
        #expect(!second.watcher.isWatching)
        // The selected repository's own watch, and the one the others share.
        #expect(fixture.harness.fileWatcher.activeSubscriptions.map(\.paths) == [[realPath(first.record.path)]])
        #expect(fixture.harness.fileWatcher.activeWatches.count == 1)

        // The selected repository's change is refreshed by its own watcher,
        // after its own quiet period, and never again from here.
        let firstPasses = first.refreshScheduler.passCount
        await fixture.emit(".git/index", in: first)
        await scheduler.advance(by: ownQuiet)
        await app.idle()
        #expect(first.refreshScheduler.passCount == firstPasses + 1)
        await scheduler.advance(by: longest)
        await app.idle()
        #expect(first.refreshScheduler.passCount == firstPasses + 1)

        app.select(.repository(second.id))
        await app.idle()
        #expect(watcher.watchedRepositoryIDs == [first.id])
        #expect(second.watcher.isWatching)
        #expect(!first.watcher.isWatching)
        #expect(fixture.harness.fileWatcher.activeSubscriptions.map(\.paths) == [[realPath(second.record.path)]])
        #expect(fixture.harness.fileWatcher.activeWatches.count == 1)
        // The repository that left the selection gets a status as its watch
        // here starts.
        #expect(first.refreshScheduler.passCount == firstPasses + 2)
        #expect(first.refreshScheduler.lastPassScope == .status)
        #expect(first.refreshScheduler.lastPassReasons == [.fileSystem])

        // Its changes now come here, after the longer quiet period...
        await fixture.emit(".git/index", in: first)
        await scheduler.advance(by: ownQuiet)
        await app.idle()
        #expect(first.refreshScheduler.passCount == firstPasses + 2)
        await scheduler.advance(by: quiet - ownQuiet)
        await app.idle()
        #expect(first.refreshScheduler.passCount == firstPasses + 3)

        // ...and the newly selected repository's go to its own watcher.
        let secondPasses = second.refreshScheduler.passCount
        await fixture.emit(".git/index", in: second)
        await scheduler.advance(by: ownQuiet)
        await app.idle()
        #expect(second.refreshScheduler.passCount == secondPasses + 1)
        await scheduler.advance(by: longest)
        await app.idle()
        #expect(second.refreshScheduler.passCount == secondPasses + 1)
        await app.prepareForTermination()
    }

    @Test("follows the indicators setting: off, nothing is watched or refreshed; on again, everything is")
    func setting() async throws {
        let fixture = try await makeFixture()
        let (app, scheduler, watcher) = (fixture.app, fixture.scheduler, fixture.watcher)
        let other = fixture.others[0]
        let passes = other.refreshScheduler.passCount
        // A change waiting for its quiet period.
        await fixture.emit(".git/index", in: other)

        app.preferences.repositoryIndicatorsEnabled = false
        // The coordinator hears of the setting.
        await scheduler.advance()
        #expect(!watcher.isRunning)
        #expect(watcher.watchedRepositoryIDs.isEmpty)
        // The selected repository's own watch stays; the shared one ends.
        #expect(fixture.harness.fileWatcher.activeSubscriptions.count == 1)
        #expect(fixture.harness.fileWatcher.activeWatches.isEmpty)
        await fixture.emit(".git/index", in: other)
        await scheduler.advance(by: longest)
        await app.idle()
        #expect(other.refreshScheduler.passCount == passes)

        app.preferences.repositoryIndicatorsEnabled = true
        await scheduler.advance()
        await app.idle()
        #expect(watcher.isRunning)
        #expect(watcher.watchedRepositoryIDs == [other.id])
        await fixture.emit(".git/index", in: other)
        await scheduler.advance(by: quiet)
        await app.idle()
        #expect(other.refreshScheduler.passCount == passes + 1)
        await app.prepareForTermination()
    }

    @Test("a repository that leaves the list is no longer watched, and the changes it was waiting on are dropped")
    func removed() async throws {
        let fixture = try await makeFixture(others: 2)
        let (app, scheduler, watcher) = (fixture.app, fixture.scheduler, fixture.watcher)
        let (removed, kept) = (fixture.others[0], fixture.others[1])
        let passes = removed.refreshScheduler.passCount
        // While the app is inactive, one change of its waits for the app to
        // become active, and another for its quiet period.
        app.setMainWindowVisible(false)
        await fixture.emit(".git/index", in: removed)
        await scheduler.advance(by: quiet)
        await fixture.emit(".git/index", in: removed)
        await fixture.emit(".git/index", in: kept)
        #expect(watcher.changedRepositoryIDs == [removed.id])

        try await app.removeRepository(removed.id, moveToTrash: false, confirmed: [.removeRepository])
        #expect(watcher.watchedRepositoryIDs == [kept.id])
        #expect(watcher.changedRepositoryIDs.isEmpty)

        let keptPasses = kept.refreshScheduler.passCount
        await scheduler.advance(by: longest)
        app.setMainWindowVisible(true)
        await app.idle()
        #expect(removed.refreshScheduler.passCount == passes)
        #expect(app.indicators[removed.id] == nil)
        // The kept repository's change, from while the window was hidden.
        #expect(kept.refreshScheduler.passCount == keptPasses + 1)
        await app.prepareForTermination()
    }

    @Test("a missing repository isn't watched until it's found again")
    func missing() async throws {
        let fixture = try await makeFixture()
        let (app, scheduler, watcher) = (fixture.app, fixture.scheduler, fixture.watcher)
        let other = fixture.others[0]
        #expect(watcher.watchedRepositoryIDs == [other.id])

        app.updateRecord(other.id) { $0.isMissing = true }
        // The watcher hears of the list's change.
        await scheduler.advance()
        #expect(watcher.watchedRepositoryIDs.isEmpty)
        #expect(!fixture.harness.fileWatcher.activeWatches.flatMap(\.paths).contains(realPath(other.record.path)))

        app.updateRecord(other.id) { $0.isMissing = false }
        await scheduler.advance()
        await app.idle()
        #expect(watcher.watchedRepositoryIDs == [other.id])
        await app.prepareForTermination()
    }

    @Test("a repository whose folder is gone loses its indicator, without being marked missing")
    func folderGone() async throws {
        let fixture = try await makeFixture()
        let (app, scheduler) = (fixture.app, fixture.scheduler)
        let other = fixture.others[0]
        #expect(app.indicators[other.id] != nil)

        let root = realPath(other.record.path)
        try FileManager.default.removeItem(atPath: other.record.path)
        fixture.harness.fileWatcher.emit(root, flags: [.rootChanged])
        await scheduler.advance()
        await scheduler.advance(by: quiet)
        await app.idle()
        #expect(app.indicators[other.id] == nil)
        #expect(app.record(other.id)?.isMissing == false)
        await app.prepareForTermination()
    }

    @Test("every other repository is watched on one watch they share, whose folders follow the list")
    func sharedWatch() async throws {
        let fixture = try await makeFixture(others: 4)
        let (app, fileWatcher) = (fixture.app, fixture.harness.fileWatcher)
        let others = fixture.others
        #expect(fixture.watcher.watchedRepositoryIDs == Set(others.map(\.id)))
        // The selected repository has a subscription of its own; no other
        // repository does.
        #expect(fileWatcher.activeSubscriptions.map(\.paths) == [[realPath(fixture.selected.record.path)]])
        #expect(fileWatcher.activeWatches.count == 1)
        let watched = try #require(fileWatcher.activeWatches.first).paths
        for other in others {
            #expect(watched.contains(realPath(other.record.path)))
        }

        let removedPath = realPath(others[0].record.path)
        try await app.removeRepository(others[0].id, moveToTrash: false, confirmed: [.removeRepository])
        await fixture.scheduler.advance()
        await app.idle()
        #expect(fileWatcher.activeWatches.count == 1)
        let remaining = try #require(fileWatcher.activeWatches.first).paths
        #expect(!remaining.contains { $0.hasPrefix(removedPath) })
        #expect(remaining.contains(realPath(others[1].record.path)))
        await app.prepareForTermination()
    }

    @Test("stops at quit, and doesn't start again")
    func quit() async throws {
        let fixture = try await makeFixture()
        let (app, watcher) = (fixture.app, fixture.watcher)
        let other = fixture.others[0]
        let passes = other.refreshScheduler.passCount
        await fixture.emit(".git/index", in: other)

        await app.prepareForTermination()
        #expect(!watcher.isRunning)
        #expect(watcher.watchedRepositoryIDs.isEmpty)
        #expect(fixture.harness.fileWatcher.activeSubscriptions.isEmpty)
        #expect(fixture.harness.fileWatcher.activeWatches.isEmpty)

        app.background.update()
        #expect(!watcher.isRunning)
        await fixture.scheduler.advance(by: longest)
        await app.idle()
        #expect(other.refreshScheduler.passCount == passes)
    }
}
