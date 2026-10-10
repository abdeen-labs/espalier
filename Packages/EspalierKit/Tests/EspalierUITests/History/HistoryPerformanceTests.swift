// The history graph's performance budgets. Opt-in, because the numbers only
// mean something in a release build on a quiet machine:
//
//     ESPALIER_PERF_REPO=/path/to/repository swift test -c release \
//         --filter HistoryPerformanceTests
//
// The synthetic test feeds the engine's generated 100,000-commit history to
// the graph table, page by page, and scrolls the whole table offscreen:
// applying a 1,000-commit page ≤ 2 ms, configuring a row ≤ 0.3 ms, drawing
// a graph cell ≤ 0.15 ms. The repository test clones the repository the
// variable names (locally, into a temporary directory) and measures the
// first page from History appearing to painted: ≤ 150 ms, warm.

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

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

/// The median, the 95th percentile, and the maximum of `samples`.
private func summary(_ samples: [Double]) -> (median: Double, p95: Double, max: Double) {
    guard !samples.isEmpty else {
        return (0, 0, 0)
    }
    let sorted = samples.sorted()
    return (sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 95 / 100)], sorted[sorted.count - 1])
}

@Suite("History performance", .serialized, .enabled(if: perfRepository != nil)) @MainActor
struct HistoryPerformanceTests {
    @Test("the synthetic 100,000-commit history: page applies, row configuration, cell drawing")
    func synthetic() {
        let generated = generateHistory(seed: 42, commits: 100_000, maxBranches: 10)
        let history = SyntheticHistory(generated.commits, options: CommitGraphOptions(
            trunkTip: generated.trunkTip,
            includesUncommittedWork: true,
            headSHA: generated.commits.first?.sha
        ))
        history.publishFirstPage(100)
        let harness = GraphTableHarness(history, size: CGSize(width: 900, height: 1_000))
        let measurements = GraphTableMeasurements()
        harness.controller.measurements = measurements

        // Pages of 1,000: the layout is the model's work off the main
        // actor; the table's apply is timed.
        while !history.isGraphComplete {
            history.prepareNextPage(1_000)()
            harness.controller.update(source: history, presentation: harness.presentation, selection: harness.selection, reorderInsertionRow: nil)
        }
        let applies = summary(measurements.pageApplies.map(milliseconds))

        // Scroll the whole table a screen at a time, laying out each
        // screen: every row is configured once as it appears.
        let table = harness.table
        let screen = harness.controller.scrollView.contentView.bounds.height
        var y: CGFloat = 0
        let start = ContinuousClock.now
        while y < table.frame.height {
            harness.controller.scroll(toY: y, animated: false)
            harness.layout()
            y += screen
        }
        let scrollTime = milliseconds(.now - start)
        let configurations = summary(measurements.rowConfigurations.map(milliseconds))

        // Drawing every row's graph into a 2x bitmap.
        let geometry = harness.controller.style.geometry
        let colors = harness.controller.style.colors
        let context = CGContext(
            data: nil,
            width: Int(geometry.columnWidth * 2),
            height: Int(geometry.rowHeight * 2),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: 2, y: 2)
        var draws: [Double] = []
        draws.reserveCapacity(history.graph.count)
        for row in 0..<history.graph.count {
            let drawing = harness.controller.drawing(forRow: row, in: history)
            let emphasis = harness.controller.emphasis(forRow: row)
            let drawStart = ContinuousClock.now
            GraphRenderer.draw(drawing, emphasis: emphasis, geometry: geometry, colors: colors, in: context)
            draws.append(milliseconds(.now - drawStart))
        }
        let drawing = summary(draws)

        print(String(
            format: "PERF graph table, %d rows: page apply median %.3f ms, p95 %.3f, max %.3f (%d pages); "
                + "row configuration median %.4f ms, p95 %.4f, max %.3f (%d rows, %.0f ms scrolling); "
                + "cell drawing median %.4f ms, p95 %.4f, max %.3f",
            history.graph.count, applies.median, applies.p95, applies.max, measurements.pageApplies.count,
            configurations.median, configurations.p95, configurations.max, measurements.rowConfigurations.count, scrollTime,
            drawing.median, drawing.p95, drawing.max
        ))
        #expect(applies.p95 <= 2)
        #expect(configurations.p95 <= 0.3)
        #expect(drawing.p95 <= 0.15)
    }

    @Test("the first page of a real repository paints within 150 ms")
    func firstPage() async throws {
        let source = try #require(perfRepository)
        try await withIsolatedGitConfig { _ in
            let directory = try createTempDirectory()
            let clonePath = POSIXPath.join(directory, "repository")
            let clone = try await Dugite.exec(["clone", "--quiet", "--local", "--no-hardlinks", source, clonePath], directory)
            #expect(clone.exitCode == 0)
            let local = Repository(path: clonePath)
            // The commit-graph file Espalier writes when History first opens.
            _ = try await Dugite.exec(["commit-graph", "write", "--reachable", "--split"], clonePath)
            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let repository = try await harness.addAndSelect(local, to: app)
            let context = WindowContext(app: app)
            context.avatarLoader = MonogramAvatarLoader()
            let fixture = HistoryScreenFixture(harness: harness, app: app, repository: repository, context: context, local: local, shas: [:])

            var samples: [Double] = []
            for run in 0..<6 {
                // Warm: the second and later runs reload the history.
                if run > 0 {
                    repository.history.setScope(run.isMultiple(of: 2) ? .localBranches : .currentBranch)
                }
                let start = ContinuousClock.now
                repository.history.activate()
                await repository.history.idle()
                let table = GraphTableHarnessForModel(fixture: fixture)
                table.update()
                samples.append(milliseconds(.now - start))
                repository.history.deactivate()
            }
            let warm = summary(Array(samples.dropFirst()))
            print(String(format: "PERF first page: cold %.1f ms; warm median %.1f ms, max %.1f ms", samples[0], warm.median, warm.max))
            #expect(warm.median <= 150)
            await app.idle()
        }
    }
}
