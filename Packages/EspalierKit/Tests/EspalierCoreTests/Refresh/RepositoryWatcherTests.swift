// The watcher's debounce, its watermark, and when the selected repository
// is watched.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Repository watcher") @MainActor
struct RepositoryWatcherTests {
    let paths = WatchedPaths(workingDirectory: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git")
    let fileWatcher = ManualFileWatcher(currentEventID: 100)
    let scheduler = ManualScheduler()
    let refreshes = RefreshLog()

    private func makeWatcher() -> RepositoryWatcher {
        let refreshes = refreshes
        let watcher = RepositoryWatcher(watcher: fileWatcher, scheduler: scheduler) { scope in
            refreshes.scopes.append(scope)
        }
        watcher.start(paths)
        return watcher
    }

    /// Emits events and lets the watcher take them.
    private func emit(_ path: String, id: UInt64? = nil, flags: FileWatchEvent.Flags = [.itemModified, .itemIsFile]) async {
        fileWatcher.emit(path, id: id, flags: flags)
        await scheduler.advance()
    }

    @Test("refreshes the status a quiet period after the last event")
    func quietPeriod() async {
        let watcher = makeWatcher()
        await emit("/repo/greeting.txt")
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(299))
        #expect(refreshes.scopes.isEmpty)
        await scheduler.advance(by: .milliseconds(1))
        #expect(refreshes.scopes == [.status])
        withExtendedLifetime(watcher) {}
    }

    @Test("each event restarts the quiet period, up to the maximum delay after the first")
    func maximumDelay() async {
        let watcher = makeWatcher()
        await emit("/repo/a.txt")
        for _ in 0..<4 {
            await scheduler.advance(by: .milliseconds(200))
            await emit("/repo/b.txt")
        }
        // t = 800 ms: the last event is 0 ms old, but the burst started at 0.
        #expect(refreshes.scopes.isEmpty)
        await scheduler.advance(by: .milliseconds(100))
        #expect(refreshes.scopes.isEmpty)
        await scheduler.advance(by: .milliseconds(100))
        #expect(refreshes.scopes == [.status])
        withExtendedLifetime(watcher) {}
    }

    @Test("merges the scopes a burst calls for")
    func mergesScopes() async {
        let watcher = makeWatcher()
        fileWatcher.emit(batch: ["/repo/.git/HEAD", "/repo/README.md", "/repo/.git/FETCH_HEAD"])
        await scheduler.advance()
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [[.status, .refs, .metadata]])
        withExtendedLifetime(watcher) {}
    }

    @Test("ignores events that call for nothing")
    func ignoresIrrelevantEvents() async {
        let watcher = makeWatcher()
        await emit("/repo/.git/objects/ab/cdef")
        await emit("/repo/.git/index.lock")
        await scheduler.advance(by: .seconds(2))
        #expect(refreshes.scopes.isEmpty)
        #expect(scheduler.sleeperCount == 0)
        withExtendedLifetime(watcher) {}
    }

    @Test("a submodule's HEAD and refs refresh the status; its objects and logs, nothing")
    func submoduleGitDirectory() async {
        let watcher = makeWatcher()
        await emit("/repo/.git/modules/lib/objects/ab/cdef")
        await emit("/repo/.git/modules/lib/logs/HEAD")
        await emit("/repo/.git/modules/lib/logs/refs/heads/main")
        await scheduler.advance(by: .seconds(2))
        #expect(refreshes.scopes.isEmpty)
        #expect(scheduler.sleeperCount == 0)

        await emit("/repo/.git/modules/lib/refs/heads/main")
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [.status])

        await emit("/repo/.git/modules/lib/modules/inner/HEAD")
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [.status, .status])
        withExtendedLifetime(watcher) {}
    }

    @Test("drops events while a local operation runs, and its late events after")
    func localSuspension() async {
        let watcher = makeWatcher()
        let token = watcher.suspend(.everything)
        await emit("/repo/README.md")
        await emit("/repo/.git/index")
        await scheduler.advance(by: .seconds(1))
        #expect(refreshes.scopes.isEmpty)

        // The operation ends at event 200; its own writes may still arrive.
        fileWatcher.setCurrentEventID(200)
        watcher.resume(token)
        await emit("/repo/.git/index", id: 150)
        await emit("/repo/README.md", id: 200)
        await scheduler.advance(by: .seconds(1))
        #expect(refreshes.scopes.isEmpty)

        // Anything newer counts.
        await emit("/repo/README.md", id: 201)
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [.status])
    }

    @Test("network operations suspend only events in the git directory")
    func networkSuspension() async {
        let watcher = makeWatcher()
        let token = watcher.suspend(.gitDirectory)
        await emit("/repo/.git/refs/remotes/origin/main")
        await emit("/repo/.git/FETCH_HEAD")
        await scheduler.advance(by: .seconds(1))
        #expect(refreshes.scopes.isEmpty)

        await emit("/repo/notes.txt")
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [.status])

        fileWatcher.setCurrentEventID(500)
        watcher.resume(token)
        await emit("/repo/.git/refs/remotes/origin/main", id: 450)
        await emit("/repo/working.txt", id: 460)
        await scheduler.advance(by: .milliseconds(300))
        // The late ref event is dropped; working-tree events never were.
        #expect(refreshes.scopes == [.status, .status])
    }

    @Test("never drops a watched directory moving, mounts, or unmounts, which have event ID 0")
    func rootChangesAreNeverDropped() async {
        let watcher = makeWatcher()
        let token = watcher.suspend(.everything)
        await emit("/repo", id: 0, flags: [.rootChanged])
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [.full])

        fileWatcher.setCurrentEventID(900)
        watcher.resume(token)
        await emit("/repo", id: 0, flags: [.rootChanged])
        await scheduler.advance(by: .milliseconds(300))
        await emit("/", id: 0, flags: [.unmount])
        await scheduler.advance(by: .milliseconds(300))
        await emit("/repo/README.md", id: 800)
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [.full, .full, .full])
        withExtendedLifetime(watcher) {}
    }

    @Test("stopping drops a refresh waiting for its quiet period")
    func stopDropsPending() async {
        let watcher = makeWatcher()
        await emit("/repo/README.md")
        watcher.stop()
        await scheduler.advance(by: .seconds(1))
        #expect(refreshes.scopes.isEmpty)
        #expect(!watcher.isWatching)
    }

    // MARK: Visibility (through the model)

    @Test("watches the selected repository's real paths while the window is visible")
    func visibility() async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithRemote()
            // Add the repository through a symbolic link: FSEvents reports
            // real paths, so the watcher must watch the real ones.
            let linkDirectory = try createTempDirectory()
            let link = POSIXPath.join(linkDirectory, "link")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: local.path)

            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let repository = try await harness.addAndSelect(Repository(path: link), to: app)
            #expect(repository.record.path == link)
            #expect(harness.fileWatcher.activeSubscriptions.map(\.paths) == [[realPath(local.path)]])
            #expect(repository.watchedPaths?.gitDirectory == realPath(local.path) + "/.git")

            // Hidden: no watching. Visible again: watching and a status refresh.
            app.setMainWindowVisible(false)
            #expect(harness.fileWatcher.activeSubscriptions.isEmpty)
            let passes = repository.refreshScheduler.passCount
            app.setMainWindowVisible(true)
            #expect(harness.fileWatcher.activeSubscriptions.count == 1)
            #expect(repository.refreshScheduler.passCount == passes + 1)
            #expect(repository.refreshScheduler.lastPassScope == .status)
            #expect(repository.refreshScheduler.lastPassReasons == [.windowBecameVisible])
            await app.idle()

            // A change made while visible refreshes the status.
            try harness.write("new.txt", "new\n", in: local)
            harness.fileWatcher.emit(realPath(local.path) + "/new.txt")
            await harness.scheduler.waitForSleepers(1)
            await harness.scheduler.advance(by: .milliseconds(300))
            await repository.idle()
            #expect(repository.changes.workingDirectory.files.map(\.path) == ["new.txt"])

            // Deselecting stops watching.
            app.select(nil)
            #expect(harness.fileWatcher.activeSubscriptions.isEmpty)
            await app.idle()
        }
    }
}

/// The refreshes a watcher requested.
@MainActor
final class RefreshLog {
    var scopes: [RefreshScope] = []
}
