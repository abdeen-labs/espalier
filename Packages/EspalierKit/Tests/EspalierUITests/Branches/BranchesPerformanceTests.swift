// The branch lists' budgets. Opt-in, because the numbers only mean something
// in a release build on a quiet machine:
//
//     ESPALIER_PERF_REPO=/path/to/repository swift test -c release \
//         --filter BranchesPerformanceTests
//
// The synthetic tests build the Branches section filtered and filter the
// branch picker over 5,000 branches: each within a frame at 120 Hz (8 ms)
// on the main actor. The repository test clones the repository the variable names
// (locally, into a temporary directory), gives it 5,000 local branches (its
// remote branches tracked, five commits behind; the others at older
// commits, in folders), and measures, off the main actor, the upstream
// states of the rows a sidebar shows (the first 50 tracking branches, cold:
// ≤ 250 ms, with the refs packed as clone and gc leave them, with and
// without the commit-graph History writes; with loose refs, and every
// branch's, reported only) and the picker's commit dates (one
// `log --no-walk`, ≤ 500 ms cold), then the section built from them on the
// main actor (≤ 8 ms). UpstreamStatesPerformanceTests (EspalierCoreTests)
// measures the upstream states on a synthetic history.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

private let perfRepository = ProcessInfo.processInfo.environment["ESPALIER_PERF_REPO"]

/// A frame at 120 Hz.
private let frameBudget = 8.0

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

/// Times `body` `runs` times, in milliseconds.
@MainActor
private func measure(runs: Int = 30, _ body: () -> Void) -> [Double] {
    (0..<runs).map { _ in
        let start = ContinuousClock.now
        body()
        return milliseconds(.now - start)
    }
}

@Suite("Branches performance", .serialized, .enabled(if: perfRepository != nil)) @MainActor
struct BranchesPerformanceTests {
    /// 5,000 branches: 4,000 local ones in two levels of folders, every
    /// fifth tracking a remote branch, 100 with pull requests; 1,000 remote
    /// ones.
    private static func syntheticInputs(filter: String = "") -> BranchesSectionContent.Inputs {
        let repository = gitHubRepoFixture(owner: "octo-org", name: "website")
        func sha(_ index: Int) -> String {
            let hex = String(index, radix: 16)
            return String(repeating: "0", count: 40 - hex.count) + hex
        }
        var local: [Branch] = []
        var states: [String: BranchUpstreamState] = [:]
        for index in 0..<4_000 {
            let name = "team-\(index % 20)/area-\(index % 7)/topic-\(index)"
            let tracks = index.isMultiple(of: 5)
            let branch = localBranch(name, sha: sha(index), upstream: tracks ? "origin/\(name)" : nil)
            local.append(branch)
            if tracks {
                states[branch.ref] = .tracking(AheadBehind(ahead: index % 3, behind: index % 4))
            }
        }
        let remote = (0..<1_000).map { remoteBranch("origin/remote-only/topic-\($0)", sha: sha(10_000 + $0)) }
        let pullRequests = (0..<100).map { index in
            pullRequest(1_000 + index, head: local[index * 5].name, in: repository)
        }
        return BranchesSectionContent.Inputs(
            branches: local + remote,
            tip: .valid(branch: local[0]),
            defaultBranch: local[1],
            recentBranches: Array(local[2..<7]),
            currentAheadBehind: AheadBehind(ahead: 1, behind: 2),
            upstreamStates: states,
            pullRequests: pullRequests,
            checks: Dictionary(uniqueKeysWithValues: pullRequests.map { ($0.pullRequestNumber, ChecksState.success) }),
            remotes: [Remote(name: "origin", url: "https://github.com/octo-org/website.git")],
            filter: filter
        )
    }

    @Test("the Branches section over 5,000 branches builds within a frame when filtered")
    func section() {
        // Unfiltered, the repository test measures it.
        let filtered = Self.syntheticInputs(filter: "topic-12")
        var content = BranchesSectionContent()
        let narrowed = summary(measure { content = BranchesSectionContent.make(filtered) })
        // Local topics 12, 120-129, and 1200-1299; remote topics 12 and
        // 120-129.
        #expect(content.allRows.count == 111 + 11)
        print(String(
            format: "PERF Branches section, 5,000 branches, filtered: median %.2f ms, p95 %.2f, max %.2f",
            narrowed.median, narrowed.p95, narrowed.max
        ))
        #expect(narrowed.p95 <= frameBudget)
    }

    @Test("the branch picker filters 5,000 branches within a frame")
    func picker() {
        let inputs = Self.syntheticInputs()
        var results: [String] = []
        for filter in ["", "t", "topic-4", "team-3/area-2", "tpc49", "nothing-matches"] {
            var content = BranchPickerContent(groups: [], filter: "")
            let timing = summary(measure {
                content = BranchPickerContent.make(
                    branches: inputs.branches,
                    defaultBranch: inputs.defaultBranch,
                    recentBranches: inputs.recentBranches,
                    includesRemoteBranches: true,
                    filter: filter
                )
            })
            results.append(String(format: "\"%@\" (%d) median %.2f ms, p95 %.2f", filter, content.branches.count, timing.median, timing.p95))
            #expect(timing.p95 <= frameBudget, "filter \"\(filter)\"")
        }
        print("PERF branch picker, 5,000 branches: " + results.joined(separator: "; "))
    }

    @Test("a real repository with 5,000 branches: upstream states, commit dates, and the section")
    func repository() async throws {
        let source = try #require(perfRepository)
        try await withIsolatedGitConfig { _ in
            let directory = try createTempDirectory()
            let clonePath = POSIXPath.join(directory, "repository")
            let clone = try await Dugite.exec(["clone", "--quiet", "--local", source, clonePath], directory)
            #expect(clone.exitCode == 0)
            let local = Repository(path: clonePath)
            // A clone's remote branches are the source's local ones: bring
            // the source's remote branches along as the clone's.
            try await runGit(["fetch", "--quiet", "origin", "+refs/remotes/origin/*:refs/remotes/origin/*"], local)
            let localCount = try await Self.addBranches(to: local, total: 5_000)

            let harness = try AppHarness()
            let app = await harness.loadedApp()
            let repository = try await harness.addAndSelect(local, to: app)
            let branches = repository.gitState.branches.all
            #expect(branches.filter { $0.type == .local }.count == localCount)

            // The upstream states of the rows on screen, cold: a fresh
            // loader each run, off the main actor. First with the new
            // branches as loose refs (reported only: git reads 5,000 ref
            // files, for the branch list too); then packed, as clone and gc
            // keep a repository's refs, without a commit-graph and with the
            // one History writes.
            let tracking = branches.filter { $0.type == .local && $0.upstream != nil }.map(\.ref)
            let shown = Array(tracking.prefix(50))
            var states: [String: BranchUpstreamState] = [:]
            @MainActor func upstreamStates(_ refs: [String], runs: Int) async -> [Double] {
                var samples: [Double] = []
                for _ in 0..<runs {
                    let loader = UpstreamStatesLoader()
                    let host = UpstreamStatesRecorder(repository.branches)
                    loader.host = host
                    loader.branchesDidChange(repository.gitState.branches)
                    let start = ContinuousClock.now
                    loader.beginWatching(refs)
                    await loader.idle()
                    samples.append(milliseconds(.now - start))
                    states = host.states
                }
                return samples
            }
            try await runGit(["config", "core.commitGraph", "false"], local)
            let loose = summary(await upstreamStates(shown, runs: 3))
            try await runGit(["pack-refs", "--all"], local)
            let upstreamSamples = await upstreamStates(shown, runs: 5)
            let everyBranch = summary(await upstreamStates(tracking, runs: 1))
            try await runGit(["config", "--unset", "core.commitGraph"], local)
            try await writeCommitGraph(local)
            let withGraph = summary(await upstreamStates(shown, runs: 5))
            let everyBranchWithGraph = summary(await upstreamStates(tracking, runs: 1))
            // At least five behind (more when the fifth first-parent
            // ancestor skips a merge's commits).
            let tracked = states.values.filter { if case .tracking(let aheadBehind) = $0 { aheadBehind.behind >= 5 } else { false } }.count
            #expect(tracked > 0)

            // The picker's dates: cold (one git log), then cached.
            var coldSamples: [Double] = []
            for _ in 0..<3 {
                repository.branches.tipDateCache.removeAll()
                let start = ContinuousClock.now
                let dates = await repository.branches.tipDates(for: branches)
                coldSamples.append(milliseconds(.now - start))
                #expect(dates.count == Set(branches.map(\.tip.sha)).count)
            }
            let warmStart = ContinuousClock.now
            _ = await repository.branches.tipDates(for: branches)
            let warm = milliseconds(.now - warmStart)

            // The section, as the sidebar builds it from the model.
            let section = summary(measure(runs: 10) {
                _ = BranchesSectionContent.make(repository, upstreamStates: states, filter: "")
            })

            let upstream = summary(upstreamSamples)
            let cold = summary(coldSamples)
            print(String(
                format: "PERF %d branches (%d local, %d tracking, %d behind): upstream states of %d rows median %.1f ms, max %.1f "
                    + "(with History's commit-graph %.1f ms; loose refs %.1f ms); every branch's %.1f ms (with the graph %.1f ms); "
                    + "commit dates cold median %.1f ms, max %.1f, cached %.2f ms; section median %.2f ms, p95 %.2f",
                branches.count, localCount, tracking.count, tracked, shown.count, upstream.median, upstream.max, withGraph.median, loose.median,
                everyBranch.median, everyBranchWithGraph.median, cold.median, cold.max, warm, section.median, section.p95
            ))
            #expect(upstream.median <= 250)
            #expect(withGraph.median <= 250)
            #expect(cold.median <= 500)
            #expect(section.p95 <= frameBudget)
            await app.idle()
        }
    }

    /// Gives `repository` local branches up to `total`: one per remote
    /// branch (as many as fit), tracking it five commits behind, then the
    /// others at older first-parent commits, in folders. Returns how many
    /// local branches it has.
    private static func addBranches(to repository: Repository, total: Int) async throws -> Int {
        let existing = Set(try await runGit(["for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads"], repository).split(separator: "\n").map(String.init))
        // The remote branches no local branch has, with their tips.
        let remoteBranches: [(name: String, tip: String)] = try await runGit(["for-each-ref", "--format=%(refname:lstrip=3) %(objectname)", "refs/remotes/origin"], repository)
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] != "HEAD", !existing.contains(parts[0]) else {
                    return nil
                }
                return (parts[0], parts[1])
            }
        // A repository can have more of them than `total` (vscode has 5,484).
        let tracked = Array(remoteBranches.prefix(max(0, total - existing.count)))
        // Five commits behind, or at the tip for a branch with fewer
        // commits ("<expression> missing").
        let lookups = tracked.map { "\($0.tip)~5\n" }.joined()
        let resolved = try await Dugite.exec(["cat-file", "--batch-check=%(objectname)"], repository.path, options: Dugite.ExecutionOptions(stdin: Data(lookups.utf8)))
        let behind = String(decoding: resolved.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(behind.count == tracked.count)
        let older = try await runGit(["rev-list", "--first-parent", "--skip=10", "-n", String(total), "HEAD"], repository)
            .split(separator: "\n")
            .map(String.init)

        var commands = ""
        var config = ""
        for (branch, line) in zip(tracked, behind) {
            let sha = line.count == 40 ? line : branch.tip
            commands += "create refs/heads/\(branch.name) \(sha)\n"
            config += "[branch \"\(branch.name)\"]\n\tremote = origin\n\tmerge = refs/heads/\(branch.name)\n"
        }
        let others = max(0, total - existing.count - tracked.count)
        for (index, sha) in older.prefix(others).enumerated() {
            commands += "create refs/heads/perf/team-\(index % 20)/area-\(index % 7)/topic-\(index) \(sha)\n"
        }
        let update = try await Dugite.exec(["update-ref", "--stdin"], repository.path, options: Dugite.ExecutionOptions(stdin: Data(commands.utf8)))
        #expect(update.exitCode == 0)
        let configPath = POSIXPath.join(repository.path, ".git", "config")
        let handle = try FileHandle(forWritingTo: URL(filePath: configPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(config.utf8))
        try handle.close()
        return existing.count + tracked.count + min(others, older.count)
    }
}

/// Records the upstream states a loader publishes, comparing with git as
/// the branches model does.
@MainActor
private final class UpstreamStatesRecorder: UpstreamStatesHost {
    private let model: BranchesModel
    var states: [String: BranchUpstreamState] = [:]

    init(_ model: BranchesModel) {
        self.model = model
    }

    func listUpstreamTracking(_ refs: [String]) async throws -> [ExactString: UpstreamTrackingLine] {
        try await model.listUpstreamTracking(refs)
    }

    func upstreamStatesDidChange(_ states: [String: BranchUpstreamState]) {
        self.states = states
    }
}
