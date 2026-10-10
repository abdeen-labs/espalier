// Measurements of the commit graph layout.
//
// Opt-in, because the numbers only mean something in a release build on a
// quiet machine:
//
//     ESPALIER_PERF_GRAPH_REPO=/tmp/espalier-ref/desktop swift test -c release \
//         --filter CommitGraphPerformanceTests

@testable import EspalierCore
import Foundation
import GitKit
import Testing

private let perfRepository = ProcessInfo.processInfo.environment["ESPALIER_PERF_GRAPH_REPO"]

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

/// How wide a layout is: per row, the highest lane drawn plus one.
private func widths(_ layout: CommitGraphLayout) -> (average: Double, p90: Int, max: Int) {
    var widths = layout.map { row in
        row.edges.reduce(row.lane + 1) { max($0, $1.lane + 1) }
    }
    widths.sort()
    let total = widths.reduce(0, +)
    return (Double(total) / Double(max(widths.count, 1)), widths[widths.count * 9 / 10], widths.last ?? 0)
}

/// Lays out `commits` page by page and finishes; returns the time. With
/// `holdingSnapshots`, a snapshot of the layout is held across every
/// append, as a model showing the graph does.
private func pagedLayout(
    _ commits: [CommitGraphCommit],
    _ options: CommitGraphOptions,
    pageSize: Int,
    holdingSnapshots: Bool
) -> (layout: CommitGraphLayout, milliseconds: Double) {
    let start = ContinuousClock.now
    var builder = CommitGraphBuilder(options: options)
    var snapshot = builder.layout
    var index = 0
    while index < commits.count {
        builder.append(commits[index..<min(commits.count, index + pageSize)])
        if holdingSnapshots {
            snapshot = builder.layout
        }
        index += pageSize
    }
    builder.finish()
    let time = milliseconds(ContinuousClock.now - start)
    withExtendedLifetime(snapshot) {}
    return (builder.layout, time)
}

/// Lays out `commits` once to warm up, then `runs` times; prints the
/// layout's width with stubs and as lines, its stubs and storage, and the
/// minimum and median times, whole and in pages of 100.
private func measureLayout(_ name: String, _ commits: [CommitGraphCommit], _ options: CommitGraphOptions, runs: Int = 9) {
    var layout = graphLayout(commits, options)
    var samples: [Double] = []
    for _ in 0..<runs {
        let start = ContinuousClock.now
        layout = graphLayout(commits, options)
        samples.append(milliseconds(ContinuousClock.now - start))
    }
    samples.sort()
    var linesOptions = options
    linesOptions.longEdgeThreshold = .max
    let asLines = widths(graphLayout(commits, linesOptions))
    let width = widths(layout)
    var stubs = 0, segments = 0, bytes = 0
    for row in layout {
        segments += row.edges.count
        stubs += row.edges.count { $0.kind == .outgoingStub }
    }
    for chunk in layout.chunks {
        bytes += chunk.rows.count * MemoryLayout<PackedGraphRow>.stride
            + chunk.edges.count * MemoryLayout<PackedGraphEdge>.stride
    }
    let paged = pagedLayout(commits, options, pageSize: 100, holdingSnapshots: false)
    let held = pagedLayout(commits, options, pageSize: 100, holdingSnapshots: true)
    print(String(
        format: "PERF %@: %d rows; lanes per row %.2f average, %d p90, %d max (as lines %.2f, %d, %d); "
            + "%d stubs (%.1f per 100 rows); %d tracks; %.1f segments per row, %.1f MB; "
            + "whole min %.1f ms, median %.1f ms; in pages of 100: %.1f ms, holding snapshots %.1f ms",
        name, layout.count, width.average, width.p90, width.max, asLines.average, asLines.p90, asLines.max,
        stubs, Double(stubs) * 100 / Double(max(layout.count, 1)), layout.trackCount,
        Double(segments) / Double(max(layout.count, 1)), Double(bytes) / 1e6,
        samples[0], samples[samples.count / 2], paged.milliseconds, held.milliseconds
    ))
    #expect(paged.layout == layout)
    #expect(held.layout == layout)
}

@Suite("commit graph performance", .serialized, .enabled(if: perfRepository != nil))
struct CommitGraphPerformanceTests {
    @Test("synthetic 100,000-commit history with many concurrent branches")
    func synthetic() {
        for branches in [10, 40] {
            let history = generateHistory(seed: 42, commits: 100_000, maxBranches: branches)
            measureLayout("synthetic, up to \(branches) open branches", history.commits,
                          CommitGraphOptions(trunkTip: history.trunkTip))
        }
    }

    @Test("the reference repository's history")
    func reference() async throws {
        let path = try #require(perfRepository)
        let start = ContinuousClock.now
        let output = try await git(["log", "--topo-order", "--format=%H %P", "HEAD"], path, "perf").stdout
        let commits = output.split(separator: "\n").map { line in
            let words = line.split(separator: " ").map(String.init)
            return CommitGraphCommit(sha: words[0], parentSHAs: Array(words.dropFirst()))
        }
        print(String(format: "PERF git log and parsing: %.1f ms", milliseconds(ContinuousClock.now - start)))
        let tip = try #require(commits.first?.sha)
        measureLayout("reference HEAD", commits, CommitGraphOptions(trunkTip: tip))
    }
}
