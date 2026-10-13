// Nine of the commit graph engine's golden histories
// (Tests/EspalierCoreTests/History/CommitGraphLayoutTests.swift,
// `scenarios`), chosen to cover each drawing primitive: a line, a merge, a
// branch from a branch, merges that cross, an octopus, long-range merges as
// stubs and as lines, two stubs into one commit, and unrelated roots.

import EspalierCore
import Foundation
import Testing

/// One of the engine's golden histories: commits in `git log --topo-order`
/// order, one per line, a name and then its parents' names.
struct GraphGoldenHistory: Sendable, CustomTestStringConvertible {
    let name: String
    let history: String
    let options: CommitGraphOptions

    var testDescription: String {
        name
    }

    /// The commits, names standing in for SHAs.
    var commits: [CommitGraphCommit] {
        graphCommits(history)
    }

    /// The finished layout, as the engine's tests lay it out.
    var layout: CommitGraphLayout {
        graphLayout(commits, options)
    }

    /// The capture's name: "golden-" and the name's words joined by dashes.
    var captureName: String {
        "golden-" + name.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "'", with: "")
            .split(separator: " ")
            .joined(separator: "-")
    }
}

let graphGoldenHistories: [GraphGoldenHistory] = [
    GraphGoldenHistory(name: "linear", history: """
        C B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "C")),
    GraphGoldenHistory(name: "feature merged back", history: """
        M m1 f2
        f2 f1
        f1 B
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "M")),
    GraphGoldenHistory(name: "branch from a branch", history: """
        Mb Ma b2
        b2 b1
        b1 a1
        Ma B a2
        a2 a1
        a1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "Mb")),
    GraphGoldenHistory(name: "criss-cross merges", history: """
        M2 Q P
        M1 P Q
        Q B
        P B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "M1")),
    GraphGoldenHistory(name: "octopus merge", history: """
        O m1 a1 b1 c1
        c1 B
        b1 B
        a1 B
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "O")),
    GraphGoldenHistory(name: "long-range merge", history: """
        M m6 f3
        f3 fM
        fM f2 m5
        f2 f1
        f1 m1
        m6 m5
        m5 m4
        m4 m3
        m3 m2
        m2 m1
        m1 A
        A
        """, options: CommitGraphOptions(trunkTip: "M", longEdgeThreshold: 3)),
    GraphGoldenHistory(name: "long-range merge, as lines", history: """
        M m6 f3
        f3 fM
        fM f2 m5
        f2 f1
        f1 m1
        m6 m5
        m5 m4
        m4 m3
        m3 m2
        m2 m1
        m1 A
        A
        """, options: CommitGraphOptions(trunkTip: "M")),
    GraphGoldenHistory(name: "two stubs reach one commit", history: """
        M2 m3 r3
        r3 r2
        m3 M1
        M1 m2 r2
        m2 m1
        m1 B
        q1 r2
        r2 r1
        r1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "M2", longEdgeThreshold: 2)),
    GraphGoldenHistory(name: "unrelated roots", history: """
        M m1 u2
        u2 u1
        u1
        m1 A
        A
        g2 g1
        g1
        """, options: CommitGraphOptions(trunkTip: "M")),
]
