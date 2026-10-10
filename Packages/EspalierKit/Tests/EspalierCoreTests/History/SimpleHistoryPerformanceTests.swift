// Measurements of History's simple mode on a large repository.
// Opt-in, because the numbers only mean something in a release build on a
// quiet machine:
//
//     ESPALIER_PERF_REPO=/tmp/espalier-ref/desktop swift test -c release \
//         --filter SimpleHistoryPerformanceTests
//
// It reads the repository the variable names as it is (perhaps without a
// commit-graph file), then a temporary local clone of it with one, and
// prints the first page's git time (with and without the file counts), a
// larger page, the unpushed rows' and the base's counts for a recent and a
// years-old branch, and the outline of the whole first-parent line.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private let perfRepository = ProcessInfo.processInfo.environment["ESPALIER_PERF_REPO"]

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

/// The median of `runs` timings of `body`, after one warm-up run.
private func median(runs: Int = 7, _ body: () async throws -> Void) async rethrows -> Double {
    try await body()
    var samples: [Double] = []
    for _ in 0..<runs {
        let start = ContinuousClock.now
        try await body()
        samples.append(milliseconds(.now - start))
    }
    return samples.sorted()[runs / 2]
}

@Suite("Simple history performance", .serialized, .enabled(if: perfRepository != nil)) @MainActor
struct SimpleHistoryPerformanceTests {
    @Test("git calls and the outline on the reference repository")
    func reference() async throws {
        let source = try #require(perfRepository)
        let clone = try createTempDirectory(prefix: "simple-history-perf-")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let cloned = try await Dugite.exec(["clone", "--quiet", "--local", "--mirror", source, clone], clone)
        #expect(cloned.exitCode == 0)
        try await writeCommitGraph(Repository(path: clone))

        let harness = try AppHarness()
        for (label, path) in [("no commit-graph", source), ("commit-graph", clone)] {
            let repository = Repository(path: path)
            let context = HistoryLoadContext(repository: repository, environment: harness.environment, record: RepositoryRecord(path: path))
            let head = JSCompat.trim(try await git(["rev-parse", "HEAD"], path, "perf").stdout)

            let page = try await median {
                _ = try await getCommitsWithChangedFileCounts(repository, revisions: [head], limit: 100, additionalArgs: ["--first-parent"])
            }
            let plain = try await median {
                _ = try await getCommits(repository, revisions: [head], limit: 100, additionalArgs: ["--first-parent"])
            }
            let large = try await median(runs: 3) {
                _ = try await getCommitsWithChangedFileCounts(repository, revisions: [head], limit: 1_000, additionalArgs: ["--first-parent"])
            }
            let load = await median {
                _ = await loadSimpleHistory(context, SimpleHistorySource(head: head), count: 100, search: nil)
            }
            print(String(
                format: "PERF simple history (%@): first page of 100 with file counts %.1f ms (without %.1f ms); 1,000 %.1f ms; first load %.1f ms",
                label, page, plain, large, load
            ))

            for branch in ["fix/submodule-status-output", "bugfix/harden-protocol-args"] {
                let tip = JSCompat.trim(try await git(["rev-parse", "refs/remotes/origin/\(branch)"], path, "perf").stdout)
                let baseTip = JSCompat.trim(try await git(["rev-parse", "refs/remotes/origin/development"], path, "perf").stdout)
                let base = Branch(
                    name: "origin/development",
                    upstream: nil,
                    tip: BranchTip(sha: baseTip),
                    type: .remote,
                    ref: "refs/remotes/origin/development"
                )
                let frameSource = SimpleHistorySource(head: tip, base: base, unpushedReference: .remotes)
                var frame = SimpleHistoryFrame(source: frameSource)
                let time = await median(runs: 3) {
                    frame = await loadSimpleFrame(context, frameSource)
                }
                print(String(
                    format: "PERF simple history (%@): counts for %@ %.1f ms (behind %d, unpushed %d, shares history %@)",
                    label, branch, time, frame.behindCount, frame.unpushedCount, frame.sharesHistoryWithBase ? "yes" : "no"
                ))
            }

            // The whole first-parent line, and its outline.
            let all = try await getCommitsWithChangedFileCounts(repository, revisions: [head], additionalArgs: ["--first-parent"])
            var builder = simpleListBuilder(head: head)
            builder.append(simpleGraphCommits(all.map(\.commit)))
            builder.finish()
            let list = SimpleHistoryList(
                commits: CommitList(commits: all.map(\.commit), builder: builder, isComplete: true),
                details: all.map(SimpleCommitDetails.init)
            )
            var items = 0
            let outline = await median {
                items = makeSimpleHistoryOutline(list: list, expansions: [:]).items.count
            }
            print(String(format: "PERF simple history (%@): outline of %d commits (%d lines) %.1f ms", label, all.count, items, outline))
        }
    }
}
