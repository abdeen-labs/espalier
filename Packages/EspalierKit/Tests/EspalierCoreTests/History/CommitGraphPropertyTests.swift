// Properties of the commit graph layout, checked on generated histories
// and on deliberately broken input.

@testable import EspalierCore
import Testing

/// Checks every property the layout promises for the commits received so
/// far (the whole history once the layout is complete); returns the failures.
private func violations(
    _ layout: CommitGraphLayout,
    _ commits: [CommitGraphCommit],
    _ options: CommitGraphOptions
) -> [String] {
    var problems: [String] = []
    let offset = options.includesUncommittedWork ? 1 : 0
    guard layout.count == commits.count + offset else {
        return ["\(layout.count) rows for \(commits.count) commits"]
    }
    let threshold = max(0, options.longEdgeThreshold)
    var firstRow: [String: Int] = [:]
    for (index, commit) in commits.enumerated() where firstRow[commit.sha] == nil {
        firstRow[commit.sha] = index + offset
    }
    let firstBranchLane = options.trunkTip == nil ? 0 : 1
    func parents(of row: Int) -> [String] {
        if offset == 1 && row == 0 {
            return options.headSHA.map { [$0] } ?? []
        }
        return commits[row - offset].parentSHAs
    }

    // The trunk: its rows, and the commits lane 0 waits for, in order (the
    // last one may not have arrived).
    var trunkRows: Set<Int> = []
    var trunkChain: [(sha: String, row: Int?)] = []
    if let tip = options.trunkTip {
        var previous = -1
        var next: String? = tip
        if options.includesUncommittedWork && options.headSHA == tip {
            trunkRows.insert(0)
            previous = 0
        }
        while let sha = next {
            let row = firstRow[sha]
            if let row, row <= previous { break }
            trunkChain.append((sha, row))
            guard let row else { break }
            trunkRows.insert(row)
            previous = row
            next = parents(of: row).first
        }
    }
    /// The trunk commit lane 0 waits for below `row`.
    func trunkNext(after row: Int) -> String? {
        trunkChain.first { $0.row.map { $0 > row } ?? true }?.sha
    }

    // One node per row; no line passes through a node; lanes carry one line;
    // stubs stay at the node.
    var bottoms: [[Int: Int]] = []
    for (r, row) in layout.enumerated() {
        var top: [Int: Int] = [:], bottom: [Int: Int] = [:]
        if row.lane >= layout.laneCount { problems.append("row \(r): lane \(row.lane) beyond \(layout.laneCount)") }
        for edge in row.edges {
            switch edge.kind {
            case .passing:
                if edge.lane == row.lane { problems.append("row \(r): a line passes through the node") }
                if top.updateValue(edge.track, forKey: edge.lane) != nil { problems.append("row \(r): two lines at top of lane \(edge.lane)") }
                bottom[edge.lane] = edge.track
            case .incoming:
                if top.updateValue(edge.track, forKey: edge.lane) != nil { problems.append("row \(r): two lines at top of lane \(edge.lane)") }
            case .incomingStub, .outgoingStub, .unrouted:
                if edge.lane != row.lane { problems.append("row \(r): a \(edge.kind) away from the node") }
            case .outgoing:
                break
            }
        }
        for edge in row.edges where edge.kind == .outgoing {
            if let existing = bottom[edge.lane], existing != edge.track {
                problems.append("row \(r): a merge joins lane \(edge.lane) with another track")
            }
            bottom[edge.lane] = edge.track
        }
        if r > 0 && top != bottoms[r - 1] {
            problems.append("row \(r): lines at its top \(top) don't match the row above \(bottoms[r - 1])")
        }
        bottoms.append(bottom)
    }

    // Every parent edge reaches its parent's row and lane: a line, or a stub
    // pair naming both ends. Stubs exactly for edges longer than T, except
    // the trunk's, which is never cut, and a merge joining it.
    var expectedIncomingStubs = 0
    for r in layout.indices {
        for (k, parent) in parents(of: r).enumerated() {
            let target = firstRow[parent]
            let edges = layout[r].edges.filter { $0.parentIndex == min(k, 255) }
            if let target, target <= r {
                if !edges.contains(where: { $0.kind == .unrouted && $0.parentRow == target }) {
                    problems.append("row \(r): no unrouted edge to parent \(k) above")
                }
                continue
            }
            let isFar = target.map { $0 - r > threshold } ?? (layout.isComplete || r < layout.stableRowCount)
            let isTrunkEdge = k == 0 && trunkRows.contains(r) || k > 0 && parent == trunkNext(after: r)
            if let stub = edges.first(where: { $0.kind == .outgoingStub }) {
                if isTrunkEdge || !isFar { problems.append("row \(r): a stub to parent \(k), \(target.map { $0 - r } ?? -1) rows away") }
                if stub.parentRow != target { problems.append("row \(r): a stub to parent \(k) names row \(stub.parentRow ?? -1)") }
                guard let target else { continue }
                expectedIncomingStubs += 1
                let other = layout[target].edges.filter { $0.kind == .incomingStub && $0.childRow == r && $0.parentIndex == min(k, 255) }
                if other.count != 1 || other.first?.track != stub.track {
                    problems.append("row \(r): no matching stub at parent \(k)'s row \(target)")
                }
                continue
            }
            guard let lane = edges.first(where: { $0.kind == .outgoing })?.lane else {
                problems.append("row \(r): no edge to parent \(k)")
                continue
            }
            if isFar && !isTrunkEdge { problems.append("row \(r): a line to parent \(k), \(target.map { $0 - r } ?? -1) rows away") }
            let end = target ?? layout.count
            for q in (r + 1)..<max(end, r + 1) where !layout[q].edges.contains(where: { $0.kind == .passing && $0.lane == lane }) {
                problems.append("row \(r): edge to parent \(k) breaks at row \(q)")
                break
            }
            if let target, !layout[target].edges.contains(where: { $0.kind == .incoming && $0.lane == lane }) {
                problems.append("row \(r): edge to parent \(k) doesn't reach row \(target)")
            }
        }
    }
    var incomingStubs = 0
    for row in layout {
        incomingStubs += row.edges.count { $0.kind == .incomingStub }
    }
    if incomingStubs != expectedIncomingStubs {
        problems.append("\(incomingStubs) stubs arrive, \(expectedIncomingStubs) leave for loaded parents")
    }

    // The trunk is lane 0 and track 0; nothing else is in lane 0.
    if options.trunkTip != nil {
        for (r, row) in layout.enumerated() {
            if trunkRows.contains(r) != (row.lane == 0) { problems.append("row \(r): trunk and lane 0 disagree") }
            if trunkRows.contains(r) && row.track != 0 { problems.append("row \(r): trunk commit off track 0") }
        }
    }

    // A merge that starts a line or a stub toward a commit that stubs
    // already wait for takes their track (a first-parent stub's first).
    var waitingStubs: [String: [CommitGraphEdge]] = [:]
    for (r, row) in layout.enumerated() {
        let passing = Set(row.edges.filter { $0.kind == .passing }.map(\.lane))
        let rowParents = parents(of: r)
        for edge in row.edges where edge.kind == .outgoing || edge.kind == .outgoingStub {
            guard let k = edge.parentIndex, k < rowParents.count else { continue }
            let parent = rowParents[k]
            let startsLine = edge.kind == .outgoingStub
                || !passing.contains(edge.lane) && !(firstBranchLane == 1 && edge.lane == 0)
            if k > 0 && startsLine, let stubs = waitingStubs[parent],
               let stub = stubs.first(where: { $0.parentIndex == 0 }) ?? stubs.first, stub.track != edge.track {
                problems.append("row \(r): a merge toward stubs on track \(stub.track) takes track \(edge.track)")
            }
            if edge.kind == .outgoingStub {
                waitingStubs[parent, default: []].append(edge)
            }
        }
    }

    // New lines take the lowest free lane; a commit only stubs reach
    // continues a stub's track.
    for (r, row) in layout.enumerated() {
        let passing = Set(row.edges.filter { $0.kind == .passing }.map(\.lane))
        let isTip = !row.edges.contains { $0.kind == .incoming } && !(firstBranchLane == 1 && row.lane == 0)
        if isTip, let lowest = (firstBranchLane...).first(where: { !passing.contains($0) }), lowest != row.lane {
            problems.append("row \(r): a tip in lane \(row.lane), not the free lane \(lowest)")
        }
        let stubs = row.edges.filter { $0.kind == .incomingStub }
        if isTip, let stub = stubs.first(where: { $0.parentIndex == 0 }) ?? stubs.first, stub.track != row.track {
            problems.append("row \(r): a commit only stubs reach on track \(row.track), not \(stub.track)")
        }
        var used = passing.union([row.lane])
        for edge in row.edges where edge.kind == .outgoing && (edge.parentIndex ?? 0) > 0 {
            defer { used.insert(edge.lane) }
            if used.contains(edge.lane) || (firstBranchLane == 1 && edge.lane == 0) { continue }
            if let lowest = (firstBranchLane...).first(where: { !used.contains($0) }), lowest != edge.lane {
                problems.append("row \(r): a merge in lane \(edge.lane), not the free lane \(lowest)")
            }
        }
    }
    return problems
}

/// A row's segments as a layout with only `loadedRows` rows shows them: a
/// stub's parent row is unknown until the parent's page arrives.
private func segments(_ row: CommitGraphRow, loadedRows: Int) -> [CommitGraphEdge] {
    row.edges.map { edge in
        var edge = edge
        if edge.kind == .outgoingStub, let parentRow = edge.parentRow, parentRow >= loadedRows {
            edge.parentRow = nil
        }
        return edge
    }
}

/// Checks that the stable rows of a partial layout are the whole layout's.
private func stableRowsMatch(_ partial: CommitGraphLayout, _ whole: CommitGraphLayout) -> Bool {
    (0..<partial.stableRowCount).allSatisfy { r in
        let row = partial[r], final = whole[r]
        return row.lane == final.lane && row.track == final.track && row.isUncommittedWork == final.isUncommittedWork
            && Array(row.edges) == segments(final, loadedRows: partial.count)
    }
}

/// Breaks a history on purpose: rows swapped out of order, a SHA repeated,
/// commits dropped (their children's parents are never shown), self-parents.
private func damaged(_ commits: [CommitGraphCommit], seed: UInt64) -> [CommitGraphCommit] {
    var random = GraphRandom(state: seed)
    var result = commits
    for _ in 0..<(commits.count / 20 + 1) {
        let a = random.below(result.count), b = random.below(result.count)
        switch random.below(4) {
        case 0: result.swapAt(a, b)
        case 1: result.insert(result[a], at: b)
        case 2: if result.count > 2 { result.remove(at: a) }
        default: result[a].parentSHAs.append(result[a].sha)
        }
    }
    return result
}

@Suite("commit graph layout properties")
struct CommitGraphPropertyTests {
    @Test("generated histories keep every property", arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
    func generated(seed: UInt64) {
        let history = generateHistory(seed: seed, commits: 400, maxBranches: Int(seed % 4) * 3 + 2)
        for threshold in [30, 5, Int.max] {
            for options in [
                CommitGraphOptions(trunkTip: history.trunkTip),
                CommitGraphOptions(),
                CommitGraphOptions(trunkTip: history.trunkTip, includesUncommittedWork: true, headSHA: history.trunkTip),
                CommitGraphOptions(trunkTip: history.trunkTip, includesUncommittedWork: true,
                                   headSHA: history.commits[history.commits.count / 3].sha),
            ] {
                var options = options
                options.longEdgeThreshold = threshold
                let layout = graphLayout(history.commits, options)
                #expect(violations(layout, history.commits, options) == [])
            }
        }
    }

    @Test("broken input keeps every property", arguments: [UInt64(11), 12, 13, 14, 15, 16])
    func broken(seed: UInt64) {
        let history = generateHistory(seed: seed, commits: 300, maxBranches: 6)
        let commits = damaged(history.commits, seed: seed)
        for threshold in [30, 3] {
            for options in [
                CommitGraphOptions(trunkTip: history.trunkTip, longEdgeThreshold: threshold),
                CommitGraphOptions(longEdgeThreshold: threshold),
            ] {
                let layout = graphLayout(commits, options)
                #expect(violations(layout, commits, options) == [])
            }
        }
    }

    @Test("pages equal the whole layout for every stable row", arguments: [UInt64(21), 22, 23, 24])
    func incremental(seed: UInt64) {
        let history = generateHistory(seed: seed, commits: 700, maxBranches: 8)
        let commits = seed.isMultiple(of: 2) ? history.commits : damaged(history.commits, seed: seed)
        for threshold in [30, 4] {
            let options = CommitGraphOptions(trunkTip: history.trunkTip, includesUncommittedWork: true,
                                             headSHA: commits.first?.sha, longEdgeThreshold: threshold)
            let whole = graphLayout(commits, options)
            var random = GraphRandom(state: seed)
            var builder = CommitGraphBuilder(options: options)
            var start = 0
            while start < commits.count {
                let end = min(commits.count, start + 1 + random.below(150))
                let previousStable = builder.layout.stableRowCount
                let changed = builder.append(commits[start..<end])
                let layout = builder.layout
                #expect(changed == previousStable..<layout.count)
                #expect(layout.stableRowCount == max(previousStable, layout.count - threshold))
                #expect(stableRowsMatch(layout, whole))
                // The provisional rows are a valid graph of what has arrived.
                #expect(violations(layout, Array(commits[..<end]), options) == [])
                start = end
            }
            builder.finish()
            #expect(builder.layout == whole)
        }
    }

    @Test("snapshots stay as they were while pages cross chunks", arguments: [UInt64(31), 32])
    func snapshots(seed: UInt64) {
        let history = generateHistory(seed: seed, commits: 3 * CommitGraphLayout.chunkSize + 100, maxBranches: 10)
        let options = CommitGraphOptions(trunkTip: history.trunkTip)
        let whole = graphLayout(history.commits, options)
        var random = GraphRandom(state: seed)
        var builder = CommitGraphBuilder(options: options)
        var held: [(layout: CommitGraphLayout, rendered: String, end: Int)] = []
        var start = 0
        while start < history.commits.count {
            let end = min(history.commits.count, start + 1 + random.below(400))
            builder.append(history.commits[start..<end])
            held.append((builder.layout, renderGraph(builder.layout, history.commits), end))
            start = end
        }
        builder.finish()
        #expect(builder.layout == whole)
        #expect(builder.layout.chunks.count == 4)
        for snapshot in held {
            #expect(renderGraph(snapshot.layout, history.commits) == snapshot.rendered)
            #expect(stableRowsMatch(snapshot.layout, whole))
            #expect(violations(snapshot.layout, Array(history.commits[..<snapshot.end]), options) == [])
        }
    }

    @Test("lanes are reused")
    func lanesReused() {
        // Fifty short branches off the trunk, one after another, share lane 1.
        let commits = graphHistory("t0 t1\n" + (0..<50).map { "f\($0) t\($0 + 1)\nt\($0 + 1) t\($0 + 2)" }.joined(separator: "\n"))
        let options = CommitGraphOptions(trunkTip: "t0")
        let layout = graphLayout(commits, options)
        #expect(layout.laneCount == 2)
        #expect(Set(layout.map(\.track)).count == 51)
        #expect(violations(layout, commits, options) == [])
    }
}
