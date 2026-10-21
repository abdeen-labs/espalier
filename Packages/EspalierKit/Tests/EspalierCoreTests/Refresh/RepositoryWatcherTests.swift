// The watcher's debounce, its ignore check, its suspensions and watermark,
// and when the selected repository is watched.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

/// An ignore check that fails.
private struct CheckFailure: Error {}

/// What git ignores in a case, the batch the watcher sees, and what that
/// batch calls for.
struct IgnoreCase: Sendable {
    /// Whether git ignores a path (relative to the working directory, as
    /// spelled).
    var isIgnored: @Sendable (String) -> Bool
    /// The file git reads `core.excludesFile` rules from.
    var excludesFile: String? = nil
    var batch: [String]
    /// Nil for nothing.
    var expected: RefreshScope?

    /// Rules that ignore what `isIgnored` picks.
    var rules: IgnoreRules {
        let isIgnored = isIgnored
        let excludesFile = excludesFile
        return IgnoreRules(
            ignoredPaths: { _, paths in Set(paths.filter(isIgnored).map(ExactString.init)) },
            excludesFile: { _ in excludesFile }
        )
    }
}

/// A repository's files, the paths the watcher then reports, and what
/// they call for, against git's own ignore rules.
struct GitIgnoreCase: Sendable {
    /// Written after the repository's first commit, relative to it.
    var written: [String] = []
    /// Relative to the repository.
    var emitted: [String]
    /// Nil for nothing.
    var expected: RefreshScope?
}

@Suite("Repository watcher", .hangGuard(minutes: 5)) @MainActor
struct RepositoryWatcherTests {
    let paths = WatchedPaths(workingDirectory: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git")
    let fileWatcher = ManualFileWatcher(currentEventID: 100)
    let scheduler = ManualScheduler()
    let refreshes = RefreshLog()

    private func makeWatcher(paths: WatchedPaths? = nil, ignoreRules: IgnoreRules? = nil) -> RepositoryWatcher {
        let refreshes = refreshes
        let watcher = RepositoryWatcher(watcher: fileWatcher, scheduler: scheduler, ignoreRules: ignoreRules) { scope in
            refreshes.scopes.append(scope)
        }
        watcher.start(paths ?? self.paths)
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

    @Test("drops events while a local operation runs, requests its working directory's when it ends, and drops its late events")
    func localSuspension() async {
        let watcher = makeWatcher()
        let token = watcher.suspend(.everything)
        await emit("/repo/README.md")
        await emit("/repo/.git/refs/heads/main")
        await scheduler.advance(by: .seconds(1))
        #expect(refreshes.scopes.isEmpty)

        // The operation ends at event 200: the edit made meanwhile is
        // requested at once (its ref write is its own), and its own writes
        // may still arrive.
        fileWatcher.setCurrentEventID(200)
        watcher.resume(token)
        #expect(refreshes.scopes == [.status])
        await emit("/repo/.git/index", id: 150)
        await emit("/repo/README.md", id: 200)
        await scheduler.advance(by: .seconds(1))
        #expect(refreshes.scopes == [.status])

        // Anything newer counts.
        await emit("/repo/README.md", id: 201)
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [.status, .status])
    }

    @Test("requests what a late working-directory delivery calls for beyond its operation's refresh", arguments: [
        NamedCase("after an operation that refreshes nothing", (covered: RefreshScope(), expected: [RefreshScope.status])),
        NamedCase("after an operation that refreshes the refs", (covered: RefreshScope.refs, expected: [RefreshScope.status])),
        NamedCase("after an operation that refreshes everything", (covered: RefreshScope.full, expected: [RefreshScope]())),
    ])
    func lateDeliveries(_ testCase: NamedCase<(covered: RefreshScope, expected: [RefreshScope])>) async {
        let watcher = makeWatcher()
        let token = watcher.suspend(.everything)
        fileWatcher.setCurrentEventID(200)
        watcher.resume(token, covering: testCase.value.covered)
        // The operation's own ref write and an edit, both from before it
        // ended.
        await emit("/repo/.git/refs/heads/main", id: 150)
        await emit("/repo/README.md", id: 160)
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == testCase.value.expected)
        withExtendedLifetime(watcher) {}
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

    @Test("drops a git directory event under a suspension, whichever Unicode form its path is in", arguments: [
        NamedCase("precomposed watched paths, decomposed events", (watched: "/Users/me/caf\u{E9}", events: "/Users/me/cafe\u{301}")),
        NamedCase("decomposed watched paths, precomposed events", (watched: "/Users/me/cafe\u{301}", events: "/Users/me/caf\u{E9}")),
    ])
    func suspensionNormalization(_ testCase: NamedCase<(watched: String, events: String)>) async {
        let root = testCase.value.watched
        let watcher = makeWatcher(paths: WatchedPaths(workingDirectory: root, gitDirectory: root + "/.git", commonDirectory: root + "/.git"))
        let token = watcher.suspend(.gitDirectory)
        await emit(testCase.value.events + "/.git/refs/heads/main")
        await scheduler.advance(by: .seconds(1))
        #expect(refreshes.scopes.isEmpty)

        await emit(testCase.value.events + "/notes.txt")
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [.status])
        watcher.resume(token)
    }

    // MARK: Ignore rules

    @Test("drops the working directory's paths git ignores", arguments: [
        NamedCase("paths in an ignored folder call for nothing", IgnoreCase(
            isIgnored: { $0.hasPrefix(".build/") },
            batch: ["/repo/.build/debug/main.o", "/repo/.build/debug"],
            expected: nil
        )),
        NamedCase("an ignored path and another call for the status", IgnoreCase(
            isIgnored: { $0.hasPrefix(".build/") },
            batch: ["/repo/.build/main.o", "/repo/Sources/main.swift"],
            expected: .status
        )),
        NamedCase("an ignored .gitignore calls for the status", IgnoreCase(
            isIgnored: { _ in true },
            batch: ["/repo/.build/.gitignore"],
            expected: .status
        )),
        NamedCase("the ignored excludes file calls for the status", IgnoreCase(
            isIgnored: { _ in true },
            excludesFile: "/repo/.config/git/ignore",
            batch: ["/repo/.config/git/ignore"],
            expected: .status
        )),
        NamedCase("the working directory itself calls for the status", IgnoreCase(
            isIgnored: { _ in true },
            batch: ["/repo"],
            expected: .status
        )),
        NamedCase("a path ignored in both Unicode forms calls for nothing", IgnoreCase(
            isIgnored: { ["build/caf\u{E9}.txt", "build/cafe\u{301}.txt"].exactSet.contains(ExactString($0)) },
            batch: ["/repo/build/caf\u{E9}.txt"],
            expected: nil
        )),
        NamedCase("a path ignored only precomposed calls for the status", IgnoreCase(
            isIgnored: { ExactString($0) == ExactString("build/caf\u{E9}.txt") },
            batch: ["/repo/build/caf\u{E9}.txt"],
            expected: .status
        )),
        NamedCase("a path ignored only decomposed calls for the status", IgnoreCase(
            isIgnored: { ExactString($0) == ExactString("build/cafe\u{301}.txt") },
            batch: ["/repo/build/caf\u{E9}.txt"],
            expected: .status
        )),
    ])
    func ignoreRules(_ testCase: NamedCase<IgnoreCase>) async {
        let watcher = makeWatcher(ignoreRules: testCase.value.rules)
        fileWatcher.emit(batch: testCase.value.batch)
        // A later batch waits behind the check, so one refresh shows what
        // both call for.
        fileWatcher.emit("/repo/.git/FETCH_HEAD")
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [(testCase.value.expected ?? []).union(.metadata)])
        withExtendedLifetime(watcher) {}
    }

    @Test("refreshes the status when the ignore check fails")
    func failedIgnoreCheck() async {
        let rules = IgnoreRules(ignoredPaths: { _, _ in throw CheckFailure() }, excludesFile: { _ in nil })
        let watcher = makeWatcher(ignoreRules: rules)
        await emit("/repo/.build/main.o")
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [.status])
        withExtendedLifetime(watcher) {}
    }

    @Test("batches that come while an ignore check runs wait for it, merged")
    func batchesWaitForTheCheck() async {
        let gate = AsyncGate()
        let rules = IgnoreRules(
            ignoredPaths: { _, _ in
                await gate.wait()
                return []
            },
            excludesFile: { _ in nil }
        )
        let watcher = makeWatcher(ignoreRules: rules)
        await emit("/repo/notes.txt")
        await emit("/repo/.git/FETCH_HEAD")
        await scheduler.advance(by: .seconds(2))
        #expect(refreshes.scopes.isEmpty)
        #expect(scheduler.sleeperCount == 0)

        gate.open()
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(300))
        #expect(refreshes.scopes == [[.status, .metadata]])
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

    @Test("drops what git ignores, by the repository's own rules", arguments: [
        NamedCase("files in an ignored folder, existing or deleted, call for nothing", GitIgnoreCase(
            written: ["node_modules/pkg/index.js"],
            emitted: ["node_modules/pkg/index.js", "node_modules/pkg", "node_modules/gone.js"],
            expected: nil
        )),
        NamedCase("a tracked file that an ignore rule matches calls for the status", GitIgnoreCase(
            emitted: ["kept.log"],
            expected: .status
        )),
        NamedCase("the excludes file, which its own rule ignores, calls for the status", GitIgnoreCase(
            emitted: ["my-excludes"],
            expected: .status
        )),
    ])
    func gitIgnoreRules(_ testCase: NamedCase<GitIgnoreCase>) async throws {
        try await withIsolatedGitConfig { _ in
            let repository = try setupEmptyRepository()
            let harness = try AppHarness()
            try harness.write(".gitignore", "node_modules/\n*.log\n", in: repository)
            try harness.write("kept.log", "kept\n", in: repository)
            try harness.write("my-excludes", "my-excludes\n", in: repository)
            try await runGit(["config", "core.excludesFile", POSIXPath.join(repository.path, "my-excludes")], repository)
            try await runGit(["add", ".gitignore"], repository)
            try await runGit(["add", "-f", "kept.log"], repository)
            try await runGit(["commit", "-m", "Initial"], repository)
            for path in testCase.value.written {
                try harness.write(path, "\(path)\n", in: repository)
            }
            let app = await harness.loadedApp()
            let model = try await harness.addAndSelect(repository, to: app)
            let passes = model.refreshScheduler.passCount

            let root = realPath(repository.path)
            harness.fileWatcher.emit(batch: testCase.value.emitted.map { root + "/" + $0 })
            // A later batch waits behind the check, so one refresh shows what
            // both call for.
            harness.fileWatcher.emit(root + "/.git/FETCH_HEAD")
            await harness.scheduler.waitForSleepers(1)
            await harness.scheduler.advance(by: .milliseconds(300))
            await model.idle()

            #expect(model.refreshScheduler.passCount == passes + 1)
            #expect(model.refreshScheduler.lastPassScope == (testCase.value.expected ?? []).union(.metadata))
            #expect(model.refreshScheduler.lastPassReasons == [.fileSystem])
            await app.idle()
        }
    }

    // MARK: Operations (through the model)

    @Test("refreshes the working directory's changes made during a local operation with the operation's own refresh", arguments: [
        NamedCase("an operation that refreshes nothing", (
            refreshAfter: RefreshScope(),
            scope: RefreshScope.status,
            reasons: [RefreshReason.fileSystem]
        )),
        NamedCase("an operation that refreshes everything", (
            refreshAfter: RefreshScope.full,
            scope: RefreshScope.full,
            reasons: [RefreshReason.operation(.installLFSHooks)]
        )),
    ])
    func changesDuringOperation(
        _ testCase: NamedCase<(refreshAfter: RefreshScope, scope: RefreshScope, reasons: [RefreshReason])>
    ) async throws {
        try await withIsolatedGitConfig { _ in
            let (local, _) = try await setupRepositoryWithRemote()
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let model = try await harness.addAndSelect(local, to: app)
            let passes = model.refreshScheduler.passCount

            let descriptor = OperationDescriptor(kind: .installLFSHooks, refreshAfter: testCase.value.refreshAfter)
            try await model.perform(descriptor) { _ in
                try harness.write("edit.txt", "edit\n", in: local)
                harness.fileWatcher.emit(realPath(local.path) + "/edit.txt")
                // The watcher takes the event while the operation runs.
                await harness.scheduler.advance()
            }
            await model.idle()

            #expect(model.refreshScheduler.passCount == passes + 1)
            #expect(model.refreshScheduler.lastPassScope == testCase.value.scope)
            #expect(model.refreshScheduler.lastPassReasons == testCase.value.reasons)
            #expect(model.changes.workingDirectory.files.map(\.path) == ["edit.txt"])
            await app.idle()
        }
    }
}

/// The refreshes a watcher requested.
@MainActor
final class RefreshLog {
    var scopes: [RefreshScope] = []
}
