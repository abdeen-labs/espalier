// The history graph's drawing. Nine of the golden histories (a copy of the
// engine's, GraphGoldenScenarios.swift), chosen to cover each drawing
// primitive, are drawn as golden images; the engine's ASCII goldens pin the
// other layouts. Then the cases they don't reach: three or more stubs on a
// node, a stub beside a line, HEAD, the working copy clean and dirty,
// compressed lanes, and every kind of emphasis. The criss-cross golden, the
// selection, and the dirty working copy are drawn in light and dark, the
// rest in light.

import AppKit
import EspalierCore
import Testing
@testable import EspalierUI

@Suite("History graph drawing") @MainActor
struct GraphDrawingTests {
    private let area = "HistoryGraph"

    // MARK: The engine's goldens

    /// The goldens drawn: a line, a merge, a branch from a branch, merges
    /// that cross, an octopus, long-range merges as stubs and as lines, two
    /// stubs into one commit, and unrelated roots.
    nonisolated static let drawnGoldens = [
        "linear",
        "feature merged back",
        "branch from a branch",
        "criss-cross merges",
        "octopus merge",
        "long-range merge",
        "long-range merge, as lines",
        "two stubs reach one commit",
        "unrelated roots",
    ]

    @Test("draws the engine's golden layouts that cover each drawing primitive", arguments: GraphDrawingTests.drawnGoldens)
    func goldens(_ name: String) throws {
        let scenario = try #require(graphGoldenScenarios.first { $0.name == name })
        let layout = scenario.layout
        let rows = GraphDrawingSnapshot.rows(layout, commits: scenario.commits, headSHA: scenario.options.headSHA)
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount)
        assertGraph(
            rows,
            geometry: geometry,
            named: "golden-" + scenario.fileName,
            appearances: name == "criss-cross merges" ? SnapshotAppearance.allCases : [.light]
        )
    }

    // MARK: Stub cases

    @Test("three or more stubs on a node: one each side, then a count")
    func manyStubs() {
        // O merges three branches whose commits are far below; three
        // commits far above all fork from B.
        let commits = graphCommits("""
            O m1 p1 p2 p3
            m1 m2
            m2 m3
            m3 m4
            m4 B
            x1 B
            y1 B
            z1 B
            f1 B
            p1 B
            p2 B
            p3 B
            B A
            A
            """)
        let layout = graphLayout(commits, CommitGraphOptions(trunkTip: "O", longEdgeThreshold: 2))
        let rows = GraphDrawingSnapshot.rows(layout, commits: commits, headSHA: nil)
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount)
        assertGraph(rows, geometry: geometry, named: "stubs-many")
        // The node with three merge stubs: right, left, and "+1" beside the
        // left one; every stub can be clicked.
        let targets = GraphRenderer.stubTargets(of: layout[0], geometry: geometry)
        #expect(targets.filter { $0.edge.kind == .outgoingStub }.count == 3)
    }

    @Test("an incoming stub beside a line arrives diagonally")
    func stubBesideLine() {
        // f1 forks from B far below while m1 (just above B) continues the
        // trunk into it: B has both an incoming line and a stub.
        let commits = graphCommits("""
            M m1 f1
            f1 B
            m4 m3
            m3 m2
            m2 m1
            m1 B
            B A
            A
            """)
        let layout = graphLayout(commits, CommitGraphOptions(trunkTip: "M", longEdgeThreshold: 2))
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount)
        assertGraph(GraphDrawingSnapshot.rows(layout, commits: commits, headSHA: nil), geometry: geometry, named: "stubs-beside-line")
    }

    @Test("the current tip is a bold ring with a dot; the working copy is dashed, or faint when clean")
    func headAndWorkingCopy() {
        let commits = graphCommits("""
            f2 f1
            f1 m1
            m2 m1
            m1 A
            A
            """)
        let options = CommitGraphOptions(trunkTip: "m2", includesUncommittedWork: true, headSHA: "f1")
        let layout = graphLayout(commits, options)
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount)
        // f2 sits between the working copy and HEAD: the dashed edge passes it.
        assertGraph(
            GraphDrawingSnapshot.rows(layout, commits: commits, headSHA: "f1"),
            geometry: geometry,
            named: "workingCopy-dirty",
            appearances: SnapshotAppearance.allCases
        )
        assertGraph(
            GraphDrawingSnapshot.rows(layout, commits: commits, headSHA: "f1", workingCopyIsDirty: false),
            geometry: geometry,
            named: "workingCopy-clean"
        )
    }

    @Test("past twelve lanes the pitch compresses")
    func compressedLanes() {
        // Fourteen branches open at once, merged by an octopus.
        let branches = (1...14).map { "b\($0)" }
        let history = (["O m1 " + branches.joined(separator: " ")] + branches.map { "\($0) B" } + ["m1 B", "B"]).joined(separator: "\n")
        let commits = graphCommits(history)
        let layout = graphLayout(commits, CommitGraphOptions(trunkTip: "O"))
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount)
        #expect(layout.laneCount > Metrics.Graph.maxUncompressedLanes)
        #expect(geometry.lanePitch == Metrics.Graph.compressedLanePitch)
        assertGraph(GraphDrawingSnapshot.rows(layout, commits: commits, headSHA: nil), geometry: geometry, named: "lanes-compressed")
    }

    // MARK: Emphasis

    @Test("selection, hover, focus, search, and outlines")
    func emphasis() {
        let scenario = graphGoldenScenarios[1]  // feature merged back
        let layout = scenario.layout
        let commits = scenario.commits
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount)
        let base = GraphDrawingSnapshot.rows(layout, commits: commits, headSHA: "M")

        var selected = base
        selected[1].isSelected = true
        selected[2].isSelected = true
        assertGraph(selected, geometry: geometry, named: "emphasis-selected", appearances: SnapshotAppearance.allCases)

        // Hovering the feature's line dims the others to 40%.
        assertGraph(base.map { row in
            var row = row
            row.emphasis.emphasizedTrack = 1
            row.emphasis.dimming = Metrics.Graph.hoverDimming
            return row
        }, geometry: geometry, named: "emphasis-hover")

        // A focused branch dims the others to 28%; with Differentiate
        // without color they're also dashed.
        assertGraph(base.map { row in
            var row = row
            row.emphasis.emphasizedTrack = 0
            row.emphasis.dimming = Metrics.Graph.focusDimming
            row.emphasis.dashesDimmedTracks = true
            return row
        }, geometry: geometry, named: "emphasis-focus")

        // Rows that don't match the search dim their nodes; a jump's target
        // is outlined.
        assertGraph(base.enumerated().map { index, row in
            var row = row
            row.emphasis.nodeOpacity = index == 2 ? 1 : Metrics.Graph.searchDimming
            row.emphasis.outlinesNode = index == 2
            return row
        }, geometry: geometry, named: "emphasis-search")
    }

    @Test("Increase Contrast thickens every stroke")
    func increaseContrast() {
        let scenario = graphGoldenScenarios[3]  // branch from a branch
        let layout = scenario.layout
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount, increaseContrast: true)
        #expect(geometry.stroke(track: 0) == Metrics.Graph.trackStroke + Metrics.Graph.increaseContrastStroke)
        #expect(geometry.ring(.commit).stroke == Metrics.Graph.nodeStroke + Metrics.Graph.increaseContrastStroke)
        assertGraph(GraphDrawingSnapshot.rows(layout, commits: scenario.commits, headSHA: nil), geometry: geometry, named: "increaseContrast")
    }

    // MARK: Geometry

    @Test("a line changing lanes is drawn in halves that meet at the row boundary")
    func bendsMeet() {
        // M merges F; F's branch starts from B two rows below, joining the
        // trunk on a diagonal into B.
        let commits = graphCommits("""
            M B F
            F B
            B A
            A
            """)
        let layout = graphLayout(commits, CommitGraphOptions(trunkTip: "M"))
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount)
        let rows = GraphDrawingSnapshot.rows(layout, commits: commits, headSHA: nil)
        // In every golden, each line leaving the bottom of a row enters the
        // top of the next at the same x (a merge joining a line already in
        // its lane enters beside it).
        for scenario in graphGoldenScenarios {
            let drawings = GraphDrawingSnapshot.rows(scenario.layout, commits: scenario.commits, headSHA: nil).map(\.drawing)
            let geometry = GraphGeometry(rowHeight: 32, laneCount: scenario.layout.laneCount)
            for index in drawings.indices.dropLast() {
                let upper = drawings[index]
                let lower = drawings[index + 1]
                let bottoms = upper.row.edges.filter { $0.kind == .passing || $0.kind == .outgoing }.map { edge in
                    upper.bottomX(lane: edge.lane, from: edge.kind == .outgoing ? upper.row.lane : edge.lane, geometry: geometry)
                }
                var tops: [CGFloat] = []
                for edge in lower.row.edges where edge.kind == .passing || edge.kind == .incoming {
                    let end = edge.kind == .incoming ? lower.row.lane : edge.lane
                    tops.append(lower.topX(lane: edge.lane, reaching: end, geometry: geometry))
                    if lower.joinsAbove(lane: edge.lane) {
                        tops.append(geometry.crossingX(from: edge.lane, to: end))
                    }
                }
                #expect(bottoms.sorted() == tops.sorted(), "\(scenario.name): rows \(index) and \(index + 1)")
            }
        }
        // The merge leaves M toward F's lane and crosses halfway.
        #expect(rows[0].drawing.bendsBelow == nil)
        #expect(rows[1].drawing.bendsAbove == GraphBends(nodeLane: 0, lanes: [1]))
        // F's line turns into B, crossing halfway between the lanes.
        #expect(rows[1].drawing.bendsBelow == GraphBends(nodeLane: 0, lanes: [1]))
        #expect(rows[1].drawing.bottomX(lane: 1, from: 1, geometry: geometry) == geometry.crossingX(from: 1, to: 0))
    }

    @Test("a stub's end is where it's drawn, for every stub in the goldens")
    func stubTargets() {
        for scenario in graphGoldenScenarios {
            let layout = scenario.layout
            let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount)
            for row in layout {
                let stubs = row.edges.filter { [.incomingStub, .outgoingStub, .unrouted].contains($0.kind) }
                let targets = GraphRenderer.stubTargets(of: row, geometry: geometry)
                #expect(targets.count == stubs.count, "\(scenario.name)")
                for target in targets {
                    #expect(target.point.y >= 0 && target.point.y <= geometry.rowHeight, "\(scenario.name)")
                    #expect(target.point.x >= 0, "\(scenario.name)")
                }
            }
        }
    }

    // MARK: Helpers

    /// Snapshots the rows, in light unless `appearances` says otherwise.
    private func assertGraph(
        _ rows: [GraphSnapshotRow],
        geometry: GraphGeometry,
        named name: String,
        appearances: [SnapshotAppearance] = [.light],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for appearance in appearances {
            let image = GraphDrawingSnapshot.render(rows, geometry: geometry, appearance: appearance)
            assertSnapshot(image, named: name, area: area, appearance: appearance, sourceLocation: sourceLocation)
        }
    }
}

/// Parses a history: one commit per line, its name and then its parents'.
func graphCommits(_ text: String) -> [CommitGraphCommit] {
    text.split(separator: "\n").compactMap { line in
        let words = line.split(separator: " ").map(String.init)
        guard let sha = words.first else {
            return nil
        }
        return CommitGraphCommit(sha: sha, parentSHAs: Array(words.dropFirst()))
    }
}

/// Lays out a whole history.
func graphLayout(_ commits: [CommitGraphCommit], _ options: CommitGraphOptions) -> CommitGraphLayout {
    var builder = CommitGraphBuilder(options: options)
    builder.append(commits)
    builder.finish()
    return builder.layout
}
