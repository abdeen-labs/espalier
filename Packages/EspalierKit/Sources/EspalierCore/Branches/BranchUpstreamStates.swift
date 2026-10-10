// How local branches compare with their upstreams, for the sidebar's "↑2 ↓3"
// and "Upstream gone" on every local branch's row. Only the rows on screen are
// compared, and each result is cached by the two commits it compares: git costs
// about a millisecond a branch on a long history, so all 5,000 branches of a
// large repository take seconds after every refresh.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "branches")

/// How a local branch compares with its upstream.
public enum BranchUpstreamState: Sendable, Equatable {
    /// The upstream exists: the commits only the branch has (`ahead`) and
    /// only the upstream has (`behind`).
    case tracking(AheadBehind)
    /// The upstream is configured, but its remote-tracking branch is gone
    /// (deleted on the remote and pruned).
    case gone
}

/// The most branches one `git for-each-ref` compares: git matches every
/// branch of the repository against every ref it's given.
let upstreamStatesBatchSize = 100

/// The two commits an upstream state compares.
struct UpstreamStateKey: Hashable, Sendable {
    /// The local branch's tip.
    let tip: ExactString
    /// The upstream's tip; nil when the upstream isn't a listed branch
    /// (gone, or outside `refs/heads` and `refs/remotes`).
    let upstreamTip: ExactString?
}

/// A local branch with an upstream, as the branch list has it.
struct UpstreamStateRequest: Sendable, Equatable {
    let ref: String
    let key: UpstreamStateKey
    /// The upstream's full ref, when it's listed.
    let upstreamRef: String?
}

/// What `git for-each-ref` lists for one ref.
struct UpstreamTrackingLine: Sendable, Equatable {
    /// `%(objectname)`.
    let objectName: String
    /// `%(upstream)`: the upstream's full ref; empty without one.
    let upstream: String
    /// `%(upstream:track,nobracket)`: empty when in sync, "gone", or
    /// "ahead N", "behind N", "ahead N, behind M".
    let track: String
}

/// What the loader needs from its repository.
@MainActor
protocol UpstreamStatesHost: AnyObject {
    /// Lists `refs` with their upstreams and how they compare
    /// (`loadUpstreamTracking`).
    func listUpstreamTracking(_ refs: [String]) async throws -> [ExactString: UpstreamTrackingLine]
    /// The states the rows show changed.
    func upstreamStatesDidChange(_ states: [String: BranchUpstreamState])
}

/// Loads how local branches compare with their upstreams, for the rows on
/// screen, and caches each result by the two commits it compares.
///
/// Rows ask for their branch while they're on screen (`watch`). Branches
/// whose pair of commits isn't cached are compared in batches: one
/// `git for-each-ref --stdin` with `%(upstream:track)` for up to 100
/// branches, one batch at a time, off the main actor. A batch whose rows
/// all left the screen is cancelled (git gets SIGTERM). A branch at its
/// upstream's commit is in sync without asking git, as git answers.
///
/// A result is cached only when the same git call lists the branch and its
/// upstream at the commits the branch list has, so a cached pair is never
/// wrong, whatever moved while git ran. After a refresh, only branches
/// whose pair moved are compared again: rows on screen keep what they show
/// until then, and the others forget it. Upstreams that aren't listed
/// (gone ones, mostly) are compared again once per refresh.
@MainActor
final class UpstreamStatesLoader {
    /// What a row shows.
    private struct Shown {
        /// Nil when git listed no upstream for the branch.
        var state: BranchUpstreamState?
        /// The pair it was compared for.
        var key: UpstreamStateKey
        /// The branch list it was compared for (`listGeneration`).
        var generation: UInt64
    }

    private struct Batch {
        let id: UInt64
        /// The branches it compares; empty until it starts.
        var refs: Set<ExactString>
        let task: Task<Void, Never>
    }

    weak var host: (any UpstreamStatesHost)?

    /// The local branches with an upstream, by ref.
    private var requests: [ExactString: UpstreamStateRequest] = [:]
    /// The rows on screen, by ref (a branch can be on screen twice).
    private var demand: [ExactString: Int] = [:]
    /// Comparisons whose pair git confirmed.
    private var cache: [UpstreamStateKey: BranchUpstreamState] = [:]
    private var shown: [ExactString: Shown] = [:]
    /// The rows whose state isn't a cached comparison: the upstream isn't
    /// listed, git listed other commits, or it's shown until compared again.
    private var unconfirmed: Set<ExactString> = []
    /// Counts the branch lists.
    private var listGeneration: UInt64 = 0
    /// The branch list the requests are for.
    private var lastBranches: [Branch] = []
    private var lastUpstreams: [ExactString: Branch] = [:]
    private var batch: Batch?
    private var nextBatchID: UInt64 = 0

    init() {}

    /// How many comparisons are cached (for tests).
    var cachedCount: Int {
        cache.count
    }

    /// The branches rows on screen watch (for tests).
    var watchedRefs: Set<String> {
        Set(demand.keys.map(\.value))
    }

    // MARK: Rows

    /// Keeps `ref`'s state loaded until the calling task is cancelled (a
    /// row's `.task`).
    func watch(_ ref: String) async {
        beginWatching([ref])
        await waitForCancellation()
        endWatching([ref])
    }

    /// Rows showing `refs` appeared.
    func beginWatching(_ refs: [String]) {
        for ref in refs {
            demand[ExactString(ref), default: 0] += 1
        }
        loadIfNeeded()
    }

    /// Rows showing `refs` disappeared: a batch comparing only branches no
    /// row shows any more stops.
    func endWatching(_ refs: [String]) {
        for ref in refs {
            let key = ExactString(ref)
            if let count = demand[key], count > 1 {
                demand[key] = count - 1
            } else {
                demand[key] = nil
            }
        }
        if let batch, !batch.refs.isEmpty, batch.refs.allSatisfy({ demand[$0] == nil }) {
            batch.task.cancel()
            self.batch = nil
            loadIfNeeded()
        }
    }

    // MARK: The branch list

    /// A refresh loaded the refs: cached pairs show at once, and rows on
    /// screen whose pair moved, or whose state git didn't confirm, are
    /// compared again.
    func branchesDidChange(_ snapshot: BranchesSnapshot) {
        listGeneration &+= 1
        // The same list (the same storage, when the refresh found nothing
        // new): only the unconfirmed states are compared again.
        if snapshot.all == lastBranches, snapshot.upstreams == lastUpstreams {
            let forgotten = unconfirmed.filter { demand[$0] == nil }
            if !forgotten.isEmpty {
                for ref in forgotten {
                    shown[ref] = nil
                }
                unconfirmed.subtract(forgotten)
                publish()
            }
            loadIfNeeded()
            return
        }
        lastBranches = snapshot.all
        lastUpstreams = snapshot.upstreams

        var requests: [ExactString: UpstreamStateRequest] = [:]
        for branch in snapshot.all where branch.type == .local {
            guard let upstreamName = branch.upstream, !upstreamName.isEmpty else {
                continue
            }
            let ref = ExactString(branch.ref)
            let upstream = snapshot.upstreams[ref]
            requests[ref] = UpstreamStateRequest(
                ref: branch.ref,
                key: UpstreamStateKey(tip: ExactString(branch.tip.sha), upstreamTip: upstream.map { ExactString($0.tip.sha) }),
                upstreamRef: upstream?.ref
            )
        }
        self.requests = requests

        let keys = Set(requests.values.map(\.key))
        cache = cache.filter { keys.contains($0.key) }
        var shown: [ExactString: Shown] = [:]
        var unconfirmed: Set<ExactString> = []
        for (ref, request) in requests {
            if let state = cachedState(request) {
                shown[ref] = Shown(state: state, key: request.key, generation: listGeneration)
            } else if demand[ref] != nil, let previous = self.shown[ref] {
                // Until it's compared again.
                shown[ref] = previous
                unconfirmed.insert(ref)
            }
        }
        self.shown = shown
        self.unconfirmed = unconfirmed
        publish()
        loadIfNeeded()
    }

    /// Forgets the branches and what rows show, and the cache too unless
    /// `keepingCache` (another worktree of the same repository shares its
    /// commits); a batch in flight stops.
    func reset(keepingCache: Bool) {
        batch?.task.cancel()
        batch = nil
        requests = [:]
        shown = [:]
        unconfirmed = []
        lastBranches = []
        lastUpstreams = [:]
        if !keepingCache {
            cache = [:]
        }
        listGeneration &+= 1
        publish()
    }

    /// Waits until no batch is in flight and every row on screen shows its
    /// branch's state.
    func idle() async {
        while let batch {
            await batch.task.value
        }
    }

    // MARK: Batches

    /// A cached comparison, or in sync when the branch is at its upstream's
    /// commit.
    private func cachedState(_ request: UpstreamStateRequest) -> BranchUpstreamState? {
        if let upstreamTip = request.key.upstreamTip, upstreamTip == request.key.tip {
            return .tracking(AheadBehind(ahead: 0, behind: 0))
        }
        return cache[request.key]
    }

    /// Whether a row on screen needs its branch compared.
    private func needsComparing(_ ref: ExactString) -> Bool {
        // Cached pairs are shown when the list or a batch brings them.
        guard demand[ref] != nil, let request = requests[ref], cachedState(request) == nil else {
            return false
        }
        guard let shown = shown[ref] else {
            return true
        }
        return shown.key != request.key || shown.generation != listGeneration
    }

    /// Starts a batch when rows on screen need comparing and none is in
    /// flight. It picks its branches when it runs, after the rows that
    /// appeared in the same turn have asked.
    private func loadIfNeeded() {
        guard batch == nil, host != nil, demand.keys.contains(where: needsComparing) else {
            return
        }
        nextBatchID &+= 1
        let id = nextBatchID
        batch = Batch(id: id, refs: [], task: Task { [weak self] in
            await self?.runBatch(id)
        })
    }

    private func runBatch(_ id: UInt64) async {
        guard batch?.id == id else {
            return
        }
        let batchRequests = demand.keys
            .filter(needsComparing)
            .prefix(upstreamStatesBatchSize)
            .compactMap { requests[$0] }
        guard !batchRequests.isEmpty, let host else {
            batch = nil
            return
        }
        batch?.refs = Set(batchRequests.map { ExactString($0.ref) })
        let generation = listGeneration
        // The upstreams too, so git's listing shows their commits.
        var refs = batchRequests.map(\.ref)
        var listed = Set(refs.map(ExactString.init))
        for upstream in batchRequests.compactMap(\.upstreamRef) where listed.insert(ExactString(upstream)).inserted {
            refs.append(upstream)
        }

        let lines: [ExactString: UpstreamTrackingLine]?
        do {
            lines = try await host.listUpstreamTracking(refs)
        } catch {
            if !Task.isCancelled {
                logger.error("Could not read the branches' upstreams: \(error.localizedDescription, privacy: .public)")
            }
            lines = nil
        }
        // Cancelled when its rows left the screen (a newer batch may run).
        guard batch?.id == id, !Task.isCancelled else {
            return
        }
        batch = nil
        apply(lines, for: batchRequests, generation: generation)
        loadIfNeeded()
    }

    /// Caches and shows a batch's results; nil `lines` when git failed (not
    /// tried again for this branch list).
    private func apply(_ lines: [ExactString: UpstreamTrackingLine]?, for batchRequests: [UpstreamStateRequest], generation: UInt64) {
        for request in batchRequests {
            let ref = ExactString(request.ref)
            let line = lines?[ref]
            let state = line.flatMap(upstreamState)
            if let lines, let line, let state, state != .gone, isConfirmed(request, line: line, lines: lines) {
                cache[request.key] = state
            }
            // The branch list moved on: compared again for the new one.
            guard let current = requests[ref], current.key == request.key else {
                continue
            }
            if let cached = cachedState(current) {
                shown[ref] = Shown(state: cached, key: current.key, generation: listGeneration)
                unconfirmed.remove(ref)
            } else if generation == listGeneration {
                shown[ref] = Shown(state: lines == nil ? shown[ref]?.state : state, key: current.key, generation: generation)
                unconfirmed.insert(ref)
            }
        }
        publish()
    }

    /// Whether git listed the branch and its upstream at the commits the
    /// request names, so its comparison is of that pair.
    private func isConfirmed(_ request: UpstreamStateRequest, line: UpstreamTrackingLine, lines: [ExactString: UpstreamTrackingLine]) -> Bool {
        guard let upstreamRef = request.upstreamRef, let upstreamTip = request.key.upstreamTip,
              ExactString(line.objectName) == request.key.tip,
              ExactString(line.upstream) == ExactString(upstreamRef),
              let upstreamLine = lines[ExactString(upstreamRef)],
              ExactString(upstreamLine.objectName) == upstreamTip else {
            return false
        }
        return true
    }

    private func publish() {
        var states: [String: BranchUpstreamState] = [:]
        states.reserveCapacity(shown.count)
        for (ref, shown) in self.shown {
            if let state = shown.state {
                states[ref.value] = state
            }
        }
        host?.upstreamStatesDidChange(states)
    }
}

/// The state `git for-each-ref` lists for a branch: nil without an
/// upstream.
func upstreamState(of line: UpstreamTrackingLine) -> BranchUpstreamState? {
    guard !line.upstream.isEmpty else {
        return nil
    }
    let track = line.track.trimmingCharacters(in: .whitespaces)
    if track == "gone" {
        return .gone
    }
    var ahead = 0
    var behind = 0
    for part in track.split(separator: ",") {
        let words = part.split(separator: " ")
        guard words.count == 2, let count = Int(words[1]) else {
            continue
        }
        switch words[0] {
        case "ahead": ahead = count
        case "behind": behind = count
        default: break
        }
    }
    return .tracking(AheadBehind(ahead: ahead, behind: behind))
}

/// Parses `for-each-ref` lines of
/// `<ref>\0<objectname>\0<upstream>\0<track>`, by ref.
func parseUpstreamTrackingLines(_ output: String) -> [ExactString: UpstreamTrackingLine] {
    var lines: [ExactString: UpstreamTrackingLine] = [:]
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        let fields = line.split(separator: "\0", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4 else {
            continue
        }
        lines[ExactString(String(fields[0]))] = UpstreamTrackingLine(
            objectName: String(fields[1]),
            upstream: String(fields[2]),
            track: String(fields[3])
        )
    }
    return lines
}

/// Lists `refs` (full refs, never empty: git lists every ref without one)
/// with their commits, upstreams, and how they compare with them: one
/// `git for-each-ref --stdin`, off the main actor.
@concurrent
func loadUpstreamTracking(_ path: String, refs: [String]) async throws -> [ExactString: UpstreamTrackingLine] {
    precondition(!refs.isEmpty, "for-each-ref lists every ref without a pattern")
    let input = refs.map { $0 + "\n" }.joined()
    let result = try await git(
        ["for-each-ref", "--stdin", "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:track,nobracket)"],
        path,
        "getBranchUpstreamStates",
        options: GitExecutionOptions(stdin: Data(input.utf8))
    )
    return parseUpstreamTrackingLines(result.stdout)
}

extension BranchesModel: UpstreamStatesHost {
    /// Keeps the upstream state of the local branch `ref` loaded until the
    /// calling task is cancelled: a branch row's `.task` while it's on
    /// screen. `upstreamStates` has it once it's loaded.
    public func watchUpstreamState(of ref: String) async {
        await upstreamStatesLoader.watch(ref)
    }

    /// Waits until the upstream states of the rows on screen are loaded.
    public func upstreamStatesIdle() async {
        await upstreamStatesLoader.idle()
    }

    func listUpstreamTracking(_ refs: [String]) async throws -> [ExactString: UpstreamTrackingLine] {
        guard let repository else {
            return [:]
        }
        // Git's commit-graph file makes the comparisons after this one about
        // five times as fast.
        repository.writeCommitGraphIfMissing()
        let path = repository.gitRepository.path
        return try await repository.environment.withRuntimes {
            try await loadUpstreamTracking(path, refs: refs)
        }
    }

    func upstreamStatesDidChange(_ states: [String: BranchUpstreamState]) {
        if upstreamStates != states {
            upstreamStates = states
        }
    }
}
