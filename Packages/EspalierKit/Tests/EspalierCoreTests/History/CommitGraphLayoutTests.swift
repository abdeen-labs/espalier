// Golden renderings of the lane layout; `renderGraph` in
// CommitGraphTestSupport.swift has the legend. Histories list one commit
// per line (name, then parents) in the order `git log --topo-order` shows
// them.

@testable import EspalierCore
import Testing

private struct Scenario: Sendable, CustomTestStringConvertible {
    let name: String
    let history: String
    let options: CommitGraphOptions
    let expected: String
    var testDescription: String { name }
}

private let scenarios: [Scenario] = [
    Scenario(name: "linear", history: """
        C B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "C"), expected: """
        *  C
        *  B
        *  A
        """),
    Scenario(name: "feature merged back", history: """
        M m1 f2
        f2 f1
        f1 B
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "M"), expected: """
        *-.  M
        | *  f2
        | *  f1
        * |  m1
        *-'  B
        *    A
        """),
    Scenario(name: "several concurrent branches", history: """
        m2 m1
        x2 x1
        y1 m1
        x1 m1
        z1 A
        m1 A
        A
        """, options: CommitGraphOptions(trunkTip: "m2"), expected: """
        *        m2
        | *      x2
        | | *    y1
        | * |    x1
        | | | *  z1
        *-'-' |  m1
        *-----'  A
        """),
    Scenario(name: "branch from a branch", history: """
        Mb Ma b2
        b2 b1
        b1 a1
        Ma B a2
        a2 a1
        a1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "Mb"), expected: """
        *-.    Mb
        | *    b2
        | *    b1
        *-|-.  Ma
        | | *  a2
        | *-'  a1
        *-'    B
        *      A
        """),
    // History of the feature branch alone, with its merge base as the trunk.
    Scenario(name: "main merged into a feature branch", history: """
        f2 fM
        fM f1 m1
        m1 B
        f1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "m1"), expected: """
          *  f2
        .-*  fM
        * |  m1
        | *  f1
        *-'  B
        *    A
        """),
    // Both branches shown: the merged commit isn't the trunk's next commit
    // when the merge is laid out, so its edge takes a lane of its own.
    Scenario(name: "main merged into a feature branch, both shown", history: """
        f2 fM
        fM f1 m1
        f1 B
        m2 m1
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "m2"), expected: """
          *    f2
          *-.  fM
          * |  f1
        * | |  m2
        *-|-'  m1
        *-'    B
        *      A
        """),
    Scenario(name: "criss-cross merges", history: """
        M2 Q P
        M1 P Q
        Q B
        P B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "M1"), expected: """
          *-.  M2
        *-| |  M1
        | * |  Q
        *-|-'  P
        *-'    B
        *      A
        """),
    Scenario(name: "octopus merge", history: """
        O m1 a1 b1 c1
        c1 B
        b1 B
        a1 B
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "O"), expected: """
        *-.-.-.  O
        | | | *  c1
        | | * |  b1
        | * | |  a1
        * | | |  m1
        *-'-'-'  B
        *        A
        """),
    Scenario(name: "long-lived release branch", history: """
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
        """, options: CommitGraphOptions(trunkTip: "M2"), expected: """
        *-.  M2
        | *  r4
        | *  r3
        * |  m2
        *-|  M1
        | *  r2
        | *  r1
        * |  m1
        *-'  B
        *    A
        """),
    Scenario(name: "unrelated roots", history: """
        M m1 u2
        u2 u1
        u1
        m1 A
        A
        g2 g1
        g1
        """, options: CommitGraphOptions(trunkTip: "M"), expected: """
        *-.  M
        | *  u2
        | *  u1
        *    m1
        *    A
          *  g2
          *  g1
        """),
    Scenario(name: "no trunk", history: """
        x1 B
        m1 B
        B A
        A
        """, options: CommitGraphOptions(), expected: """
        *    x1
        | *  m1
        *-'  B
        *    A
        """),
    Scenario(name: "uncommitted work on the trunk", history: """
        C B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "C", includesUncommittedWork: true, headSHA: "C"), expected: """
        o  Uncommitted changes
        *  C
        *  B
        *  A
        """),
    Scenario(name: "uncommitted work off the trunk", history: """
        f1 m1
        m1 A
        A
        """, options: CommitGraphOptions(trunkTip: "m1", includesUncommittedWork: true, headSHA: "f1"), expected: """
          o  Uncommitted changes
          *  f1
        *-'  m1
        *    A
        """),
    // Out of order input: C's parent B is above it, A's parent Z is never
    // shown (in a complete history, a stub to nowhere), and C is shown twice.
    Scenario(name: "parent above, parent never shown, SHA shown twice", history: """
        B A
        C B
        A Z
        C A
        """, options: CommitGraphOptions(), expected: """
        *    B
        | *  C (parent B above)
        *    A v ?
        *    C (parent A above)
        """),

    // Long edges, with T = 3 to keep the histories short. A merged pull
    // request whose fork point is far below: its first commit's edge is a
    // stub, and its lane is free for the rest of the way.
    Scenario(name: "branch forked far below", history: """
        M m4 f2
        f2 f1
        f1 B
        m4 m3
        m3 m2
        m2 m1
        m1 B
        B A
        A
        """, options: CommitGraphOptions(trunkTip: "M", longEdgeThreshold: 3), expected: """
        *-.  M
        | *  f2
        | *  f1 v B
        *    m4
        *    m3
        *    m2
        *    m1
        *    B ^ f1
        *    A
        """),
    // Main merged into a feature branch long after the feature forked:
    // `git log --topo-order` shows the feature right below its merge, so
    // both the back-merge (fM to m5) and the fork (f1 to m1) are long.
    Scenario(name: "long-range merge", history: """
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
        """, options: CommitGraphOptions(trunkTip: "M", longEdgeThreshold: 3), expected: """
        *-.  M
        | *  f3
        | *  fM v m5
        | *  f2
        | *  f1 v m1
        *    m6
        *    m5 ^ fM
        *    m4
        *    m3
        *    m2
        *    m1 ^ f1
        *    A
        """),
    // The same history drawn with lines, for comparison: three lanes.
    Scenario(name: "long-range merge, as lines", history: """
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
        """, options: CommitGraphOptions(trunkTip: "M"), expected: """
        *-.    M
        | *    f3
        | *-.  fM
        | * |  f2
        | * |  f1
        * | |  m6
        *-|-'  m5
        * |    m4
        * |    m3
        * |    m2
        *-'    m1
        *      A
        """),
    // A release branch maintained beside main: r3's parent r2 is shown only
    // after main's merge of it (M1), far below. The merge line into r2 takes
    // the waiting stub's track, so the branch keeps one color and one lane.
    // r1's edge to B is exactly T long, so it stays a line.
    Scenario(name: "long-lived branch", history: """
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
        """, options: CommitGraphOptions(trunkTip: "M2", longEdgeThreshold: 3), expected: """
        *-.  M2
        | *  r5
        | *  r4
        | *  r3 v r2
        *    m5
        *    m4
        *    m3
        *-.  M1
        | *  r2 ^ r3
        | *  r1
        * |  m2
        * |  m1
        *-'  B
        *    A
        """),
    // y1's parent is exactly T rows below (a line), x1's is T + 1 (a stub).
    Scenario(name: "boundary at exactly T", history: """
        x1 m1
        y1 m1
        m3 m2
        m2 m1
        m1 A
        A
        """, options: CommitGraphOptions(trunkTip: "m3", longEdgeThreshold: 3), expected: """
          *  x1 v m1
          *  y1
        * |  m3
        * |  m2
        *-'  m1 ^ x1
        *    A
        """),
    // A feature ahead of main merged main's tip long ago: the merge still
    // joins lane 0, which the trunk holds anyway, so the trunk is drawn
    // from that row down. fb's edge to m1 is exactly T long: a line.
    Scenario(name: "merge of the trunk's tip from far above", history: """
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
        """, options: CommitGraphOptions(trunkTip: "m3", longEdgeThreshold: 3), expected: """
          *  f3
          *  f2
        .-*  fM
        | *  f1
        | *  fa
        | *  fb
        * |  m3
        * |  m2
        *-'  m1
        *    A
        """),
    // r3's first parent and M1's merge both reach r2 from far above. The
    // merge stub takes the waiting stub's track, so both are the release
    // branch's color; r2 itself sits on q1's line and continues its track.
    Scenario(name: "two stubs reach one commit", history: """
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
        """, options: CommitGraphOptions(trunkTip: "M2", longEdgeThreshold: 2), expected: """
        *-.  M2
        | *  r3 v r2
        *    m3
        *    M1 v r2
        *    m2
        *    m1
        | *  q1
        | *  r2 ^ r3 ^ M1
        | *  r1
        *-'  B
        *    A
        """),
    // A commit only a stub reaches sits in the lowest free lane and
    // continues the branch's track (b2 and b1 are f1's color).
    Scenario(name: "commit only a stub reaches", history: """
        t3 t2
        f1 b2
        t2 t1
        t1 t0
        t0
        b2 b1
        b1
        """, options: CommitGraphOptions(longEdgeThreshold: 3), expected: """
        *    t3
        | *  f1 v b2
        *    t2
        *    t1
        *    t0
        *    b2 ^ f1
        *    b1
        """),
]

@Suite("commit graph layout")
struct CommitGraphLayoutTests {
    @Test("lays out", arguments: scenarios)
    private func laysOut(_ scenario: Scenario) {
        let commits = graphHistory(scenario.history)
        let layout = graphLayout(commits, scenario.options)
        #expect(renderGraph(layout, commits) == scenario.expected)
    }

    @Test("tracks follow lines of development")
    func tracks() {
        let commits = graphHistory(scenarios[1].history)
        let layout = graphLayout(commits, scenarios[1].options)
        // M, f2, f1, m1, B, A: the trunk is track 0, the feature track 1.
        #expect(layout.map(\.track) == [0, 1, 1, 0, 0, 0])
        #expect(layout.trackCount == 2)
        // M's merge bend and B's fork both carry the feature's track.
        #expect(layout[0].edges.contains(CommitGraphEdge(kind: .outgoing, lane: 1, track: 1, parentIndex: 1)))
        #expect(layout[4].edges.contains(CommitGraphEdge(kind: .incoming, lane: 1, track: 1)))
    }

    @Test("a branch keeps its track across a stub")
    func tracksAcrossStubs() throws {
        let release = try #require(scenarios.first { $0.name == "long-lived branch" })
        let commits = graphHistory(release.history)
        let layout = graphLayout(commits, release.options)
        // M2, r5, r4, r3, m5, m4, m3, M1, r2, r1, m2, m1, B, A.
        #expect(layout.map(\.track) == [0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0])
        #expect(layout.trackCount == 2)

        let stubOnly = try #require(scenarios.first { $0.name == "commit only a stub reaches" })
        let stubCommits = graphHistory(stubOnly.history)
        // t3, f1, t2, t1, t0, b2, b1: b2 continues f1's track.
        #expect(graphLayout(stubCommits, stubOnly.options).map(\.track) == [1, 2, 1, 1, 1, 2, 2])

        let twoStubs = try #require(scenarios.first { $0.name == "two stubs reach one commit" })
        let twoStubsLayout = graphLayout(graphHistory(twoStubs.history), twoStubs.options)
        // r2 (row 7): r3's stub (row 1) and M1's merge stub (row 3) share the
        // release branch's track; r2 continues q1's.
        #expect(twoStubsLayout[7].edges.filter { $0.kind == .incomingStub } == [
            CommitGraphEdge(kind: .incomingStub, lane: 1, track: 1, parentIndex: 0, childRow: 1),
            CommitGraphEdge(kind: .incomingStub, lane: 1, track: 1, parentIndex: 1, childRow: 3),
        ])
        #expect(twoStubsLayout[3].edges.contains(
            CommitGraphEdge(kind: .outgoingStub, lane: 0, track: 1, parentIndex: 1, parentRow: 7)))
        #expect(twoStubsLayout[7].track == 2)
    }

    @Test("both stubs of a long edge name the other end")
    func stubsNameBothEnds() throws {
        let merge = try #require(scenarios.first { $0.name == "long-range merge" })
        let layout = graphLayout(graphHistory(merge.history), merge.options)
        // fM (row 2) merges m5 (row 6); f1 (row 4) forks from m1 (row 10).
        #expect(Array(layout[2].edges) == [
            CommitGraphEdge(kind: .incoming, lane: 1, track: 1),
            CommitGraphEdge(kind: .passing, lane: 0, track: 0),
            CommitGraphEdge(kind: .outgoing, lane: 1, track: 1, parentIndex: 0),
            CommitGraphEdge(kind: .outgoingStub, lane: 1, track: 2, parentIndex: 1, parentRow: 6),
        ])
        #expect(layout[6].edges.contains(
            CommitGraphEdge(kind: .incomingStub, lane: 0, track: 2, parentIndex: 1, childRow: 2)))
        #expect(layout[4].edges.contains(
            CommitGraphEdge(kind: .outgoingStub, lane: 1, track: 1, parentIndex: 0, parentRow: 10)))
        #expect(layout[10].edges.contains(
            CommitGraphEdge(kind: .incomingStub, lane: 0, track: 1, parentIndex: 0, childRow: 4)))
    }

    @Test("the last T rows of a partly loaded history are provisional")
    func provisionalRows() {
        let commits = graphHistory("""
            M m3 f1
            f1 B
            m3 m2
            m2 m1
            m1 B
            B A
            A
            """)
        let options = CommitGraphOptions(trunkTip: "M", longEdgeThreshold: 2)
        var builder = CommitGraphBuilder(options: options)

        // Nothing below m3 has arrived: f1's parent might be near, so its
        // line stays open.
        #expect(builder.append(commits[0..<3]) == 0..<3)
        #expect(builder.layout.stableRowCount == 1)
        #expect(!builder.layout.isComplete)
        #expect(renderGraph(builder.layout, commits) == """
            *-.  M
            | *  f1
            * |  m3
            : :
            """)

        // Two more rows: f1's parent isn't within 2 rows, so f1 is stable
        // with a stub to a parent not loaded yet.
        #expect(builder.append(commits[3..<5]) == 1..<5)
        #expect(builder.layout.stableRowCount == 3)
        #expect(renderGraph(builder.layout, commits) == """
            *-.  M
            | *  f1 v ?
            *    m3
            *    m2
            *    m1
            :
            """)

        // B arrives: f1's stub names it. Finishing makes every row stable.
        #expect(builder.append(commits[5...]) == 3..<7)
        #expect(builder.layout.stableRowCount == 5)
        #expect(builder.finish() == 5..<7)
        #expect(builder.layout.stableRowCount == 7)
        #expect(builder.layout.isComplete)
        let expected = """
            *-.  M
            | *  f1 v B
            *    m3
            *    m2
            *    m1
            *    B ^ f1
            *    A
            """
        #expect(renderGraph(builder.layout, commits) == expected)
        #expect(builder.layout == graphLayout(commits, options))
        #expect(builder.finish().isEmpty)
    }

    @Test("appending after finishing continues the history")
    func appendAfterFinish() {
        let commits = graphHistory("""
            M m2 f1
            f1 m1
            m2 m1
            m1 A
            A
            """)
        var builder = CommitGraphBuilder(options: CommitGraphOptions(trunkTip: "M", longEdgeThreshold: 1))
        builder.append(commits[0..<3])
        builder.finish()
        // f1's parent m1 never showed up: a stub to nowhere, now final.
        #expect(renderGraph(builder.layout, commits) == """
            *-.  M
            | *  f1 v ?
            *    m2
            :
            """)
        // It does show up after all: the stub names it, the rows before stay.
        #expect(builder.append(commits[3...]) == 3..<5)
        #expect(!builder.layout.isComplete)
        builder.finish()
        #expect(renderGraph(builder.layout, commits) == """
            *-.  M
            | *  f1 v m1
            *    m2
            *    m1 ^ f1
            *    A
            """)
    }

    @Test("lays out off the main actor")
    @MainActor
    func concurrentLayout() async {
        let commits = graphHistory(scenarios[1].history)
        let options = scenarios[1].options
        let layout = await CommitGraphBuilder.layout(of: commits, options: options)
        #expect(layout == graphLayout(commits, options))
        let builder = await CommitGraphBuilder(options: options).appending(commits, isLastPage: true)
        #expect(builder.layout == layout)
        let partial = await CommitGraphBuilder(options: options).appending(commits)
        #expect(!partial.layout.isComplete)
    }
}
