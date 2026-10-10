// Helpers for the commit graph layout tests.

@testable import EspalierCore
import Foundation

/// Parses a history in display order, one commit per line: its name, then
/// its parents' names. Names stand in for SHAs.
func graphHistory(_ text: String) -> [CommitGraphCommit] {
    text.split(separator: "\n").compactMap { line in
        let words = line.split(separator: " ").map(String.init)
        guard let sha = words.first else { return nil }
        return CommitGraphCommit(sha: sha, parentSHAs: Array(words.dropFirst()))
    }
}

/// Lays out a whole history: every commit, then `finish()`.
func graphLayout(_ commits: [CommitGraphCommit], _ options: CommitGraphOptions = CommitGraphOptions()) -> CommitGraphLayout {
    var builder = CommitGraphBuilder(options: options)
    builder.append(commits)
    builder.finish()
    return builder.layout
}

/// Renders a layout as text, one line per row, two columns per lane, in
/// ASCII (the project keeps non-ASCII characters out of string literals):
///
///     *   a commit             o   uncommitted work
///     |   a line passing through (a horizontal passes behind it)
///     -   the horizontal part of a bend
///     .   a line leaves the node and turns down into this lane (a merge)
///     '   a line from above in this lane turns into the node (a fork point)
///     < > both: one line ends at the node, another leaves it, in this lane
///     |   at the end of a horizontal: a merge joins the line in this lane
///     +   the same, with the horizontal continuing past it
///
/// Stubs take no lane, so they're marked after the commit's name:
///
///     v X   a stub leaves the node for parent X, far below (`?`: not loaded,
///           or not shown)
///     ^ X   a stub from child X, far above, arrives at the node
///
/// Lines still open below the last row end with a row of `:`.
func renderGraph(_ layout: CommitGraphLayout, _ commits: [CommitGraphCommit]) -> String {
    let width = max(1, layout.laneCount * 2 - 1)
    func label(_ row: Int) -> String {
        if layout.hasUncommittedWorkRow && row == 0 { return "Uncommitted changes" }
        return commits[row - (layout.hasUncommittedWorkRow ? 1 : 0)].sha
    }
    var lines: [String] = []
    var openBelow: Set<Int> = []
    for (rowIndex, row) in layout.enumerated() {
        var cells = Array(repeating: Character(" "), count: width)
        var passing: Set<Int> = [], incoming: Set<Int> = [], outgoing: Set<Int> = []
        var notes: [String] = []
        openBelow = []
        for edge in row.edges {
            switch edge.kind {
            case .passing:
                passing.insert(edge.lane)
                openBelow.insert(edge.lane)
            case .incoming:
                if edge.lane != row.lane { incoming.insert(edge.lane) }
            case .outgoing:
                if edge.lane != row.lane { outgoing.insert(edge.lane) }
                openBelow.insert(edge.lane)
            case .unrouted:
                let parent = edge.parentRow.map(label) ?? "?"
                notes.append("(parent \(parent) above)")
            case .incomingStub:
                notes.append("^ " + (edge.childRow.map(label) ?? "?"))
            case .outgoingStub:
                notes.append("v " + (edge.parentRow.map(label) ?? "?"))
            }
        }
        for lane in passing { cells[lane * 2] = "|" }
        let bends = incoming.union(outgoing)
        let left = bends.filter { $0 < row.lane }
        let right = bends.filter { $0 > row.lane }
        if let leftmost = left.min() {
            for column in (leftmost * 2 + 1)..<(row.lane * 2) where cells[column] == " " { cells[column] = "-" }
        }
        if let rightmost = right.max() {
            for column in (row.lane * 2 + 1)..<(rightmost * 2) where cells[column] == " " { cells[column] = "-" }
        }
        for lane in bends {
            let isFarthest = lane < row.lane ? lane == left.min() : lane == right.max()
            if passing.contains(lane) {
                cells[lane * 2] = isFarthest ? "|" : "+"
            } else if incoming.contains(lane) && outgoing.contains(lane) {
                cells[lane * 2] = lane > row.lane ? "<" : ">"
            } else if incoming.contains(lane) {
                cells[lane * 2] = "'"
            } else {
                cells[lane * 2] = "."
            }
        }
        cells[row.lane * 2] = row.isUncommittedWork ? "o" : "*"
        lines.append(line(cells, width, label(rowIndex) + notes.map { " " + $0 }.joined()))
    }
    if !openBelow.isEmpty {
        var cells = Array(repeating: Character(" "), count: width)
        for lane in openBelow { cells[lane * 2] = ":" }
        lines.append(line(cells, width, ""))
    }
    return lines.joined(separator: "\n")
}

private func line(_ cells: [Character], _ width: Int, _ label: String) -> String {
    let graph = String(cells)
    let padded = graph.padding(toLength: width + 2, withPad: " ", startingAt: 0)
    let text = padded + label
    return String(text.reversed().drop(while: { $0 == " " }).reversed())
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
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(bound, 1))) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

/// A generated history: commits in git's topological order, the trunk's tip,
/// and the branch heads it was built from.
struct GeneratedHistory {
    var commits: [CommitGraphCommit]
    var trunkTip: String
}

/// Builds a history the way a team does: commits on main and on feature
/// branches that fork from main or from each other, merges back (sometimes
/// octopus), main merged into features, and the odd unrelated root. Then
/// lists it as `git log --topo-order` does: children before parents, a
/// stack seeded with the branch heads, so a merge's last parent comes first.
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
            // A new branch from main or from another branch's head.
            let base = branches.isEmpty || random.chance(70) ? main : branches[random.below(branches.count)]
            branches.append(commit([base]))
        } else if roll < 80 && !branches.isEmpty {
            let index = random.below(branches.count)
            branches[index] = commit([branches[index]])
        } else if roll < 92 && !branches.isEmpty {
            // Merge one branch (or several) into main.
            let index = random.below(branches.count)
            var merged = [branches.remove(at: index)]
            if random.chance(10) && !branches.isEmpty {
                merged.append(branches.remove(at: random.below(branches.count)))
            }
            main = commit([main] + merged)
        } else if roll < 98 && !branches.isEmpty {
            // Merge main into a branch.
            let index = random.below(branches.count)
            branches[index] = commit([branches[index], main])
        } else if random.chance(20) {
            branches.append(commit([]))
        } else {
            main = commit([main])
        }
    }
    // git's topological order.
    var children: [String: Int] = [:]
    for sha in order {
        for parent in parentsOf[sha] ?? [] { children[parent, default: 0] += 1 }
    }
    var stack = ([main] + branches).reversed().filter { children[$0, default: 0] == 0 }
    var seen: Set<String> = []
    var listed: [CommitGraphCommit] = []
    while let sha = stack.popLast() {
        guard seen.insert(sha).inserted else { continue }
        let parents = parentsOf[sha] ?? []
        listed.append(CommitGraphCommit(sha: sha, parentSHAs: parents))
        for parent in parents {
            children[parent, default: 0] -= 1
            if children[parent] == 0 { stack.append(parent) }
        }
    }
    return GeneratedHistory(commits: listed, trunkTip: main)
}
