// The upstream states' budget on a large synthetic repository
// (BranchUpstreamStates.swift). Opt-in, because the numbers only mean
// something in a release build on a quiet machine:
//
//     ESPALIER_PERF=1 swift test -c release --filter UpstreamStatesPerformanceTests
//
// (`ESPALIER_PERF_REPO`, which the other performance tests take, turns it
// on too; this one builds its own repository.) The repository has about
// 60,000 commits and 5,000 local branches, each tracking a remote-tracking
// branch it has diverged from (SyntheticBranchesRepository.swift). The
// test measures, off the main actor and without and with a commit-graph:
// the single `for-each-ref` over every branch (reported, for comparison);
// the rows a sidebar shows, cold (10 and 50 rows, ≤ 250 ms) and after
// scrolling to 50 others; a refresh where nothing moved (no git, ≤ 8 ms on
// the main actor); a fetch that moved 50 upstreams, 5 of them on screen;
// and every branch watched at once (reported).

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import Testing
import TestSupport

private let isEnabled = ProcessInfo.processInfo.environment["ESPALIER_PERF"] == "1"
    || ProcessInfo.processInfo.environment["ESPALIER_PERF_REPO"] != nil

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

/// The median and the maximum of `samples`.
private func summary(_ samples: [Double]) -> (median: Double, max: Double) {
    let sorted = samples.sorted()
    return (sorted[sorted.count / 2], sorted[sorted.count - 1])
}

@Suite("Upstream states performance", .serialized, .enabled(if: isEnabled), .offline) @MainActor
struct UpstreamStatesPerformanceTests {
    @Test("the rows on screen get their upstream states quickly on a long history with 5,000 tracking branches")
    func upstreamStates() async throws {
        try await withIsolatedGitConfig { _ in
            var start = ContinuousClock.now
            let synthetic = try await SyntheticBranchesRepository.make()
            print(String(format: "PERF synthetic repository: %d commits, %d branches, built in %.0f ms",
                         synthetic.commitCount, synthetic.branchNames.count, milliseconds(.now - start)))
            let local = synthetic.repository

            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let model = try await harness.addAndSelect(local, to: app)
            let tracking = model.gitState.branches.all.filter { $0.type == .local && $0.upstream != nil }.map(\.ref)
            #expect(tracking.count == synthetic.branchNames.count + 1)
            #expect(model.gitState.branches.upstreams.count == tracking.count)

            /// A fresh loader for the model's branch list, recording what
            /// it publishes.
            @MainActor func makeLoader() -> (UpstreamStatesLoader, Recorder) {
                let loader = UpstreamStatesLoader()
                let recorder = Recorder(model.branches)
                loader.host = recorder
                loader.branchesDidChange(model.gitState.branches)
                return (loader, recorder)
            }
            /// Watches `refs` with a fresh loader `runs` times.
            @MainActor func cold(_ refs: [String], runs: Int) async -> [Double] {
                var samples: [Double] = []
                for _ in 0..<runs {
                    let (loader, recorder) = makeLoader()
                    let start = ContinuousClock.now
                    loader.beginWatching(refs)
                    await loader.idle()
                    samples.append(milliseconds(.now - start))
                    #expect(refs.allSatisfy { recorder.states[$0] != nil })
                }
                return samples
            }
            /// The single for-each-ref over every branch, for comparison.
            func before() async throws -> Double {
                let start = ContinuousClock.now
                let result = try await git(
                    ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:track,nobracket)", "refs/heads"],
                    local.path,
                    "perf"
                )
                let states = parseUpstreamTrackingLines(result.stdout).compactMapValues(upstreamState)
                #expect(states.count == tracking.count)
                return milliseconds(.now - start)
            }

            // Rows from the middle of the list, as an open folder shows them.
            let firstRows = Array(tracking[2_000..<2_050])
            let nextRows = Array(tracking[3_000..<3_050])
            let fewRows = Array(tracking[100..<110])
            var lines: [String] = []

            for graph in [false, true] {
                if graph {
                    start = .now
                    try await writeCommitGraph(local)
                    lines.append(String(format: "commit-graph written in %.0f ms", milliseconds(.now - start)))
                }
                let label = graph ? "with a commit-graph" : "without a commit-graph"
                let previous = summary([try await before(), try await before(), try await before()])
                let few = summary(await cold(fewRows, runs: 5))
                let rows = summary(await cold(firstRows, runs: 5))

                // Scrolling: the loader that loaded the first rows loads
                // the next ones.
                let (loader, recorder) = makeLoader()
                loader.beginWatching(firstRows)
                await loader.idle()
                loader.endWatching(firstRows)
                start = .now
                loader.beginWatching(nextRows)
                await loader.idle()
                let scrolled = milliseconds(.now - start)
                #expect(nextRows.allSatisfy { recorder.states[$0] != nil })

                // A refresh where nothing moved: the cache answers.
                var unchanged: [Double] = []
                for _ in 0..<10 {
                    start = .now
                    loader.branchesDidChange(model.gitState.branches)
                    await loader.idle()
                    unchanged.append(milliseconds(.now - start))
                }
                let unchangedSummary = summary(unchanged)

                // A fetch moved 50 upstreams, 5 of them on screen: each
                // gains a commit.
                let moved = Array(nextRows.prefix(5)) + Array(tracking[4_000..<4_045])
                var commands = ""
                for ref in moved {
                    let upstream = try #require(model.gitState.branches.upstreams[ExactString(ref)])
                    let commit = JSCompat.trim(try await runGit(["commit-tree", "\(upstream.tip.sha)^{tree}", "-p", upstream.tip.sha, "-m", "fetched \(graph)"], local))
                    commands += "update \(upstream.ref) \(commit)\n"
                }
                let update = try await Dugite.exec(["update-ref", "--stdin"], local.path, options: Dugite.ExecutionOptions(stdin: Data(commands.utf8)))
                #expect(update.exitCode == 0)
                await model.refresh(.refs, reason: .user)
                await model.idle()
                start = .now
                loader.branchesDidChange(model.gitState.branches)
                await loader.idle()
                let fetched = milliseconds(.now - start)
                #expect(recorder.calls.last?.count == 10)

                // Every branch on screen at once (scrolling through them all).
                let everyBranch = summary(await cold(tracking, runs: 1))

                lines.append(String(
                    format: "%@: before, every branch %.0f ms (max %.0f); now 10 rows %.1f ms (max %.1f), 50 rows %.1f ms (max %.1f), "
                        + "scrolled to 50 more %.1f ms, refresh with nothing moved %.2f ms (max %.2f), fetch moved 50 (5 on screen) %.1f ms, "
                        + "every branch watched %.0f ms",
                    label, previous.median, previous.max, few.median, few.max, rows.median, rows.max,
                    scrolled, unchangedSummary.median, unchangedSummary.max, fetched, everyBranch.median
                ))
                #expect(few.median <= 250)
                #expect(rows.median <= 250)
                #expect(scrolled <= 250)
                #expect(unchangedSummary.median <= 8)
                #expect(fetched <= 250)
            }
            print("PERF upstream states, \(tracking.count) tracking branches: " + lines.joined(separator: "; "))
            await app.idle()
        }
    }
}

/// Records what a loader publishes and the refs of each git call,
/// comparing with git as the branches model does.
@MainActor
private final class Recorder: UpstreamStatesHost {
    private let model: BranchesModel
    var states: [String: BranchUpstreamState] = [:]
    var calls: [[String]] = []

    init(_ model: BranchesModel) {
        self.model = model
    }

    func listUpstreamTracking(_ refs: [String]) async throws -> [ExactString: UpstreamTrackingLine] {
        calls.append(refs)
        return try await model.listUpstreamTracking(refs)
    }

    func upstreamStatesDidChange(_ states: [String: BranchUpstreamState]) {
        self.states = states
    }
}
