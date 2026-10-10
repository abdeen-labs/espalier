// History's simple list with every commit of a large repository loaded.
// Opt-in, because the numbers only mean something in a release build on a
// quiet machine:
//
//     ESPALIER_PERF_REPO=/path/to/repository swift test -c release \
//         --filter SimpleListPerformanceTests
//
// It clones the repository the variable names (locally, into a temporary
// directory), loads its whole first-parent line in the simple style, and
// scrolls the list a screen at a time, laying out and drawing each screen:
// a screen must take well under a frame (16 ms).

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

private let perfRepository = ProcessInfo.processInfo.environment["ESPALIER_PERF_REPO"]

@Suite("Simple list performance", .serialized, .enabled(if: perfRepository != nil)) @MainActor
struct SimpleListPerformanceTests {
    @Test("every commit loaded: scrolling a screen at a time")
    func scrolling() async throws {
        let source = try #require(perfRepository)
        try await withIsolatedGitConfig { _ in
            let directory = try createTempDirectory(prefix: "simple-list-perf-")
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let clonePath = POSIXPath.join(directory, "repository")
            let clone = try await Dugite.exec(["clone", "--quiet", "--local", source, clonePath], directory)
            #expect(clone.exitCode == 0)
            let harness = try AppHarness(historyStyle: nil)
            let app = await harness.loadedApp()
            let repository = try await harness.addAndSelect(Repository(path: clonePath), to: app)
            let context = WindowContext(app: app)
            context.avatarLoader = MonogramAvatarLoader()
            let fixture = SimpleListFixture(harness: harness, app: app, repository: repository, context: context, shas: [:])
            repository.history.activate()
            await fixture.settle()
            await repository.history.loadRemainingPages()
            await fixture.settle()
            #expect(repository.history.isComplete)

            let (controller, window) = fixture.table(size: CGSize(width: 400, height: 1_000))
            defer { window.contentView = nil }
            let clip = controller.scrollView.contentView
            let screen = clip.bounds.height
            let clock = ContinuousClock()
            var samples: [Double] = []
            var y: CGFloat = 0
            let start = clock.now
            while y < controller.tableView.frame.height {
                let screenStart = clock.now
                clip.setBoundsOrigin(NSPoint(x: 0, y: y))
                controller.scrollView.reflectScrolledClipView(clip)
                controller.scrollView.layoutSubtreeIfNeeded()
                controller.scrollView.displayIfNeeded()
                let duration = clock.now - screenStart
                samples.append(Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
                y += screen
            }
            let whole = clock.now - start
            samples.sort()
            let median = samples[samples.count / 2]
            let p95 = samples[min(samples.count - 1, samples.count * 95 / 100)]
            print(String(
                format: "PERF simple list: %d commits, %d rows; a screen median %.2f ms, p95 %.2f ms, max %.2f ms; the whole list %.0f ms",
                repository.history.commitSHAs.count,
                controller.tableView.numberOfRows,
                median,
                p95,
                samples.last ?? 0,
                Double(whole.components.seconds) * 1_000 + Double(whole.components.attoseconds) / 1e15
            ))
            #expect(median < 16)
            await fixture.settle()
        }
    }
}
