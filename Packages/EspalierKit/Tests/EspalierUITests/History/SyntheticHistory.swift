// A history for the graph table's tests and its performance test, without
// a repository: commits made up from a list of SHAs and parents, laid out
// by the engine and published page by page as `HistoryModel` publishes
// them.

@testable import EspalierCore
import Foundation
import GitKit
@testable import EspalierUI

/// A made-up history the graph table can show.
@MainActor
final class SyntheticHistory: GraphTableSource {
    private(set) var graph = CommitGraphLayout()
    private(set) var graphChange = HistoryGraphChange(kind: .reload, generation: 0, reloadGeneration: 0, relaidRows: 0..<0, insertedRows: 0..<0)
    private(set) var isGraphComplete = false
    var isLoadingMore = false

    /// Every commit of the history, in order.
    private(set) var allCommits: [CommitGraphCommit]
    private(set) var options: CommitGraphOptions
    /// The commits published so far.
    private(set) var commits: [Commit] = []
    private var indexBySHA: [String: Int] = [:]
    private var builder: CommitGraphBuilder
    var refsBySHA: [String: [HistoryRef]] = [:]
    var localSHAs: Set<String> = []
    /// How many times the table asked for the next page, or every page.
    private(set) var nextPageRequests = 0
    private(set) var remainingPagesRequests = 0
    private(set) var cancellations = 0

    /// - Parameters:
    ///   - commits: The history, in display order.
    ///   - options: The layout's options.
    ///   - now: The date the newest commit was made; each older one a
    ///     minute before the one above.
    init(_ commits: [CommitGraphCommit], options: CommitGraphOptions = CommitGraphOptions(), now: Date = UIFixtures.now) {
        allCommits = commits
        self.options = options
        builder = CommitGraphBuilder(options: options)
        self.now = now
    }

    private let now: Date

    var rowOffset: Int {
        graph.hasUncommittedWorkRow ? 1 : 0
    }

    // MARK: Publishing

    /// Publishes the first `count` commits as a reload.
    func publishFirstPage(_ count: Int) {
        builder = CommitGraphBuilder(options: options)
        commits = []
        indexBySHA = [:]
        let page = Array(allCommits.prefix(count))
        builder.append(page)
        let isLast = page.count == allCommits.count
        if isLast {
            builder.finish()
        }
        add(page)
        graph = builder.layout
        isGraphComplete = isLast
        graphChange = HistoryGraphChange(
            kind: .reload,
            generation: graphChange.generation &+ 1,
            reloadGeneration: graphChange.reloadGeneration &+ 1,
            relaidRows: 0..<0,
            insertedRows: 0..<graph.count
        )
    }

    /// Replaces the history (new commits on top, a new scope) and publishes
    /// its first `count` commits as a reload.
    func reload(with commits: [CommitGraphCommit], options: CommitGraphOptions? = nil, count: Int) {
        allCommits = commits
        if let options {
            self.options = options
        }
        publishFirstPage(count)
    }

    /// Lays out the next `count` commits without publishing them; returns
    /// a function that publishes them (so a test can time only that).
    func prepareNextPage(_ count: Int) -> () -> Void {
        let start = commits.count
        let page = Array(allCommits[start..<min(start + count, allCommits.count)])
        var next = builder
        next.append(page)
        let isLast = start + page.count >= allCommits.count
        if isLast {
            next.finish()
        }
        let oldCount = graph.count
        let oldStable = graph.stableRowCount
        let layout = next.layout
        return { [self] in
            builder = next
            add(page)
            graph = layout
            isGraphComplete = isLast
            graphChange = HistoryGraphChange(
                kind: .append,
                generation: graphChange.generation &+ 1,
                reloadGeneration: graphChange.reloadGeneration,
                relaidRows: oldStable..<oldCount,
                insertedRows: oldCount..<layout.count
            )
        }
    }

    /// Lays out and publishes the next `count` commits.
    func publishNextPage(_ count: Int) {
        prepareNextPage(count)()
    }

    private func add(_ page: [CommitGraphCommit]) {
        for item in page {
            let index = commits.count
            if indexBySHA[item.sha] == nil {
                indexBySHA[item.sha] = index
            }
            commits.append(Self.commit(item, number: index, now: now))
        }
    }

    /// A made-up commit: "Commit <n>" by one of a few authors, a minute
    /// older than the one before.
    static func commit(_ item: CommitGraphCommit, number: Int, now: Date) -> Commit {
        let authors = [("Joe Bloggs", "joe@example.com"), ("Mary Jane", "mary@example.com"), ("Hubot", "hubot@example.com")]
        let author = authors[number % authors.count]
        let identity = CommitIdentity(name: author.0, email: author.1, date: now.addingTimeInterval(-60 * Double(number + 1)), tzOffset: 0)
        return Commit(
            sha: item.sha,
            shortSha: String(item.sha.prefix(7)),
            summary: "Commit \(item.sha)",
            body: "",
            author: identity,
            committer: identity,
            parentSHAs: item.parentSHAs,
            trailers: [],
            tags: []
        )
    }

    // MARK: GraphTableSource

    func commit(atRow row: Int) -> Commit? {
        let index = row - rowOffset
        return commits.indices.contains(index) ? commits[index] : nil
    }

    func row(of sha: String) -> Int? {
        indexBySHA[sha].map { $0 + rowOffset }
    }

    func refs(at sha: String) -> [HistoryRef] {
        refsBySHA[sha] ?? []
    }

    func isLocalCommit(_ sha: String) -> Bool {
        localSHAs.contains(sha)
    }

    func loadNextPage() async {
        nextPageRequests += 1
    }

    func loadRemainingPages() async {
        remainingPagesRequests += 1
    }

    func cancelLoading() {
        cancellations += 1
    }
}

// MARK: - Generated histories

/// SplitMix64, so generated histories are the same on every run.
struct GraphRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(max(bound, 1)))
    }

    mutating func chance(_ percent: Int) -> Bool {
        below(100) < percent
    }
}

/// A generated history and its trunk's tip: the engine's generator
/// (Tests/EspalierCoreTests/History/CommitGraphTestSupport.swift), so the
/// table's performance test sees the history the engine's does.
struct GeneratedHistory {
    var commits: [CommitGraphCommit]
    var trunkTip: String
}

/// Builds a history the way a team does (main, feature branches forking
/// from main or each other, merges back, the odd octopus, main merged into
/// features, unrelated roots) and lists it as `git log --topo-order` does.
func generateHistory(seed: UInt64, commits count: Int, maxBranches: Int) -> GeneratedHistory {
    var random = GraphRandom(state: seed)
    var parentsOf: [String: [String]] = [:]
    var order: [String] = []
    func commit(_ parents: [String]) -> String {
        let sha = "c\(order.count)"
        parentsOf[sha] = parents
        order.append(sha)
        return sha
    }
    var main = commit([])
    var branches: [String] = []
    while order.count < count {
        let roll = random.below(100)
        if roll < 30 || branches.isEmpty && roll < 60 {
            main = commit([main])
        } else if roll < 45 && branches.count < maxBranches {
            let base = branches.isEmpty || random.chance(70) ? main : branches[random.below(branches.count)]
            branches.append(commit([base]))
        } else if roll < 80 && !branches.isEmpty {
            let index = random.below(branches.count)
            branches[index] = commit([branches[index]])
        } else if roll < 92 && !branches.isEmpty {
            let index = random.below(branches.count)
            var merged = [branches.remove(at: index)]
            if random.chance(10) && !branches.isEmpty {
                merged.append(branches.remove(at: random.below(branches.count)))
            }
            main = commit([main] + merged)
        } else if roll < 98 && !branches.isEmpty {
            let index = random.below(branches.count)
            branches[index] = commit([branches[index], main])
        } else if random.chance(20) {
            branches.append(commit([]))
        } else {
            main = commit([main])
        }
    }
    var children: [String: Int] = [:]
    for sha in order {
        for parent in parentsOf[sha] ?? [] {
            children[parent, default: 0] += 1
        }
    }
    var stack = ([main] + branches).reversed().filter { children[$0, default: 0] == 0 }
    var seen: Set<String> = []
    var listed: [CommitGraphCommit] = []
    while let sha = stack.popLast() {
        guard seen.insert(sha).inserted else {
            continue
        }
        let parents = parentsOf[sha] ?? []
        listed.append(CommitGraphCommit(sha: sha, parentSHAs: parents))
        for parent in parents {
            children[parent, default: 0] -= 1
            if children[parent] == 0 {
                stack.append(parent)
            }
        }
    }
    return GeneratedHistory(commits: listed, trunkTip: main)
}
