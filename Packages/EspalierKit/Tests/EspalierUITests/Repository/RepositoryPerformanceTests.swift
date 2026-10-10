// The repository list's cost with many repositories. The sidebar's rows and
// the popover's groups are rebuilt whenever the list or its indicators
// change, so they're held to one frame at 120 Hz (8 ms) for 2,000
// repositories. Opt-in, like the other performance tests:
//
//     ESPALIER_PERF_REPO=/path/to/repository swift test -c release \
//         --filter RepositoryPerformanceTests

@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

private let perfRepository = ProcessInfo.processInfo.environment["ESPALIER_PERF_REPO"]

@Suite("Repository performance", .serialized, .enabled(if: perfRepository != nil)) @MainActor
struct RepositoryPerformanceTests {
    @Test("2,000 repositories: the sidebar's rows and the popover's groups each take under 8 ms")
    func repositoryList() async throws {
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        for index in 0..<2_000 {
            let owner = "owner-\(index % 40)"
            let gitHubRepository = index % 2 == 0 ? gitHubRepoFixture(owner: owner, name: "repository-\(index % 900)") : nil
            let record = RepositoryRecord(path: "/Users/joe/Developer/\(owner)/repository-\(index)", gitHubRepository: gitHubRepository)
            app.insertRecord(record)
            app.setIndicator(RepositoryIndicator(aheadBehind: AheadBehind(ahead: index % 3, behind: index % 5), changedFilesCount: index % 7), for: record.id)
        }
        app.recentRepositoryIDs = Array(app.repositories.prefix(3).map(\.id))
        app.preferences.repositoryIndicatorsEnabled = true

        let clock = ContinuousClock()
        var sidebar: [Double] = []
        var popover: [Double] = []
        for _ in 0..<20 {
            sidebar.append(milliseconds(clock.measure { _ = RepositoriesSection.rows(in: app, filter: "") }))
            popover.append(milliseconds(clock.measure { _ = RepositoryPopoverContent.make(app, filter: "rep") }))
        }
        let sidebarMedian = sidebar.sorted()[sidebar.count / 2]
        let popoverMedian = popover.sorted()[popover.count / 2]
        print("Repository list, 2,000 repositories: sidebar rows \(sidebarMedian) ms, popover groups (filtered) \(popoverMedian) ms (medians)")
        #expect(sidebarMedian < 8)
        #expect(popoverMedian < 8)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
