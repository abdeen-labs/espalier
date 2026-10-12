// The commit graph engine's 22 golden histories
// (Tests/EspalierCoreTests/History/CommitGraphLayoutTests.swift,
// `scenarios`), so the drawing is checked against the layouts the engine's
// ASCII goldens check. Every one is checked for where its stubs are drawn.
// Keep the two lists the same: a history changed or added there changes or
// adds one here.

import EspalierCore
import Foundation
import Testing

/// One of the engine's golden histories: commits in `git log --topo-order`
/// order, one per line, a name and then its parents' names.
struct GraphGoldenScenario: Sendable, CustomTestStringConvertible {
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
}

let graphGoldenScenarios: [GraphGoldenScenario] = [
    GraphGoldenScenario(name: "linear", history: """
        C B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "C")),
    GraphGoldenScenario(name: "feature merged back", history: """
        M m1 f2
        f2 f1
        f1 B
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "M")),
    GraphGoldenScenario(name: "several concurrent branches", history: """
        m2 m1
        x2 x1
        y1 m1
        x1 m1
        z1 A
        m1 A
        A
        """, options: CommitGraphOptions(trunkTip: "m2")),
    GraphGoldenScenario(name: "branch from a branch", history: """
        Mb Ma b2
        b2 b1
        b1 a1
        Ma B a2
        a2 a1
        a1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "Mb")),
    GraphGoldenScenario(name: "main merged into a feature branch", history: """
        f2 fM
        fM f1 m1
        m1 B
        f1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "m1")),
    GraphGoldenScenario(name: "main merged into a feature branch, both shown", history: """
        f2 fM
        fM f1 m1
        f1 B
        m2 m1
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "m2")),
    GraphGoldenScenario(name: "criss-cross merges", history: """
        M2 Q P
        M1 P Q
        Q B
        P B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "M1")),
    GraphGoldenScenario(name: "octopus merge", history: """
        O m1 a1 b1 c1
        c1 B
        b1 B
        a1 B
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "O")),
    GraphGoldenScenario(name: "long-lived release branch", history: """
        M2 m2 r4
        r4 r3
        r3 r2
        m2 M1
        M1 m1 r2
        r2 r1
        r1 B
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "M2")),
    GraphGoldenScenario(name: "unrelated roots", history: """
        M m1 u2
        u2 u1
        u1
        m1 A
        A
        g2 g1
        g1
        """, options: CommitGraphOptions(trunkTip: "M")),
    GraphGoldenScenario(name: "no trunk", history: """
        x1 B
        m1 B
        B A
        A
        """, options: CommitGraphOptions()),
    GraphGoldenScenario(name: "uncommitted work on the trunk", history: """
        C B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "C", includesUncommittedWork: true, headSHA: "C")),
    GraphGoldenScenario(name: "uncommitted work off the trunk", history: """
        f1 m1
        m1 A
        A
        """, options: CommitGraphOptions(trunkTip: "m1", includesUncommittedWork: true, headSHA: "f1")),
    GraphGoldenScenario(name: "parent above, parent never shown, SHA shown twice", history: """
        B A
        C B
        A Z
        C A
        """, options: CommitGraphOptions()),
    GraphGoldenScenario(name: "branch forked far below", history: """
        M m4 f2
        f2 f1
        f1 B
        m4 m3
        m3 m2
        m2 m1
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "M", longEdgeThreshold: 3)),
    GraphGoldenScenario(name: "long-range merge", history: """
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
    GraphGoldenScenario(name: "long-range merge, as lines", history: """
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
    GraphGoldenScenario(name: "long-lived branch", history: """
        M2 m5 r5
        r5 r4
        r4 r3
        r3 r2
        m5 m4
        m4 m3
        m3 M1
        M1 m2 r2
        r2 r1
        r1 B
        m2 m1
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "M2", longEdgeThreshold: 3)),
    GraphGoldenScenario(name: "boundary at exactly T", history: """
        x1 m1
        y1 m1
        m3 m2
        m2 m1
        m1 A
        A
        """, options: CommitGraphOptions(trunkTip: "m3", longEdgeThreshold: 3)),
    GraphGoldenScenario(name: "merge of the trunk's tip from far above", history: """
        f3 f2
        f2 fM
        fM f1 m3
        f1 fa
        fa fb
        fb m1
        m3 m2
        m2 m1
        m1 A
        A
        """, options: CommitGraphOptions(trunkTip: "m3", longEdgeThreshold: 3)),
    GraphGoldenScenario(name: "two stubs reach one commit", history: """
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
    GraphGoldenScenario(name: "commit only a stub reaches", history: """
        t3 t2
        f1 b2
        t2 t1
        t1 t0
        t0
        b2 b1
        b1
        """, options: CommitGraphOptions(longEdgeThreshold: 3)),
]
