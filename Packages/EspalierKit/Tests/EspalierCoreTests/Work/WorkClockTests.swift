// The clock that moves a piece of work out of In Progress when its 10
// minutes run out with nothing else happening, so what views observe
// changes then: on the app model, with a manual clock.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Observation
import Testing
import TestSupport

/// Counts the changes an observation saw.
@MainActor
private final class ChangeCounter {
    private(set) var count = 0

    /// Counts the next change to what `read` reads.
    func observeNext(_ read: @escaping @MainActor () -> Void) {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.count += 1
            }
        }
    }
}

@Suite("Work clock", .hangGuard(minutes: 5)) @MainActor
struct WorkClockTests {
    /// A loaded app with the clock running and a repository with changed
    /// files, which last changed `ago` before now.
    private func makeApp(lastChangedAgo ago: TimeInterval) async throws -> (AppHarness, AppModel, WorktreeKey) {
        let harness = try AppHarness(backgroundServices: [.workClock])
        let app = await harness.loadedApp()
        let record = RepositoryRecord(path: "/repositories/harbor")
        app.insertRecord(record)
        app.setIndicator(RepositoryIndicator(head: .branch(name: "main"), aheadBehind: nil, changedFilesCount: 2), for: record.id)
        app.worktreeActivity.recordStatus(
            WorktreeStatusSnapshot(tip: "abc", branch: "main", changedFiles: "files", lastChanged: harness.scheduler.now.addingTimeInterval(-ago)),
            forWorktreeAt: record.path,
            of: record.id
        )
        return (harness, app, WorktreeKey(repositoryID: record.id, path: record.path))
    }

    @Test("work changing now leaves In Progress for Needs You when its 10 minutes run out, and the board's observers hear of it then")
    func expires() async throws {
        let (harness, app, key) = try await makeApp(lastChangedAgo: 4 * 60)
        #expect(app.board.inProgress.map(\.id) == [key])
        await harness.scheduler.waitForSleepers(1)
        let counter = ChangeCounter()
        counter.observeNext { _ = app.board }

        await harness.scheduler.advance(by: .seconds(6 * 60 - 1))
        #expect(counter.count == 0)
        #expect(app.board.inProgress.map(\.id) == [key])

        await harness.scheduler.advance(by: .seconds(1))
        #expect(counter.count == 1)
        #expect(app.board.inProgress.isEmpty)
        #expect(app.board.needsYou.map(\.id) == [key])
        // Nothing is left to wake for.
        #expect(harness.scheduler.sleeperCount == 0)
        await app.prepareForTermination()
    }

    @Test("a new change starts the 10 minutes again, and work that changed longer ago has nothing to wake for")
    func newChange() async throws {
        let (harness, app, key) = try await makeApp(lastChangedAgo: 20 * 60)
        await app.idle()
        #expect(harness.scheduler.sleeperCount == 0)
        #expect(app.board.needsYou.map(\.id) == [key])

        app.worktreeActivity.recordStatus(
            WorktreeStatusSnapshot(tip: "abc", branch: "main", changedFiles: "more files", lastChanged: harness.scheduler.now),
            forWorktreeAt: key.path,
            of: key.repositoryID
        )
        #expect(app.board.inProgress.map(\.id) == [key])
        await harness.scheduler.waitForSleepers(1)
        await harness.scheduler.advance(by: .seconds(10 * 60))
        #expect(app.board.needsYou.map(\.id) == [key])
        await app.prepareForTermination()
    }
}
