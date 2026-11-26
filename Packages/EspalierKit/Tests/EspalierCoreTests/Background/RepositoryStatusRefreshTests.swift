// Refreshing every repository's status at once, the selected one's
// included, without waiting for the indicators' next pass.

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import Testing
import TestSupport

@Suite("Refreshing every repository's status", .offline, .hangGuard(minutes: 5)) @MainActor
struct RepositoryStatusRefreshTests {
    @Test("refreshes the selected repository's status and every other repository's indicator")
    func refreshesEveryRepository() async throws {
        let harness = try AppHarness(scheduler: ManualScheduler(now: Date()))
        let app = await harness.loadedApp()
        let selected = try setupEmptyRepository()
        let other = try setupEmptyRepository()
        let selectedModel = try await harness.addAndSelect(selected, to: app)
        let otherID = try #require(try await app.addRepositories([other.path]).added.first)
        await app.idle()
        #expect(app.indicators[selectedModel.id]?.changedFilesCount == 0)
        #expect(app.background.indicators.passCount == 0)

        try harness.write("a.txt", "a\n", in: selected)
        try harness.write("b.txt", "b\n", in: other)
        try harness.write("c.txt", "c\n", in: other)
        await app.refreshRepositoryStatuses()

        #expect(app.indicators[selectedModel.id]?.changedFilesCount == 1)
        #expect(app.indicators[otherID]?.changedFilesCount == 2)
        #expect(app.background.indicators.passCount == 1)
        await app.idle()
    }
}
