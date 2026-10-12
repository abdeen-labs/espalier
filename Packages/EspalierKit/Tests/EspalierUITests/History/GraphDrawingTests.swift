// The history graph's drawing data: every stub on a node can be clicked,
// lanes compress past twelve, Increase Contrast thickens strokes, a line
// changing lanes meets itself at the row boundary, and every stub's end is
// where it's drawn.

import AppKit
import EspalierCore
import Testing
@testable import EspalierUI

@Suite("History graph drawing") @MainActor
struct GraphDrawingTests {
    // MARK: Stubs and lanes

    @Test("every stub on a node with three or more can be clicked")
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
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount)
        // The node with three merge stubs: every stub can be clicked.
        let targets = GraphRenderer.stubTargets(of: layout[0], geometry: geometry)
        #expect(targets.filter { $0.edge.kind == .outgoingStub }.count == 3)
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
    }

    @Test("Increase Contrast thickens every stroke")
    func increaseContrast() {
        let scenario = graphGoldenScenarios[3]  // branch from a branch
        let geometry = GraphGeometry(rowHeight: 32, laneCount: scenario.layout.laneCount, increaseContrast: true)
        #expect(geometry.stroke(track: 0) == Metrics.Graph.trackStroke + Metrics.Graph.increaseContrastStroke)
        #expect(geometry.ring(.commit).stroke == Metrics.Graph.nodeStroke + Metrics.Graph.increaseContrastStroke)
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
        let rows = rowDrawings(layout, commits: commits)
        // In every golden, each line leaving the bottom of a row enters the
        // top of the next at the same x (a merge joining a line already in
        // its lane enters beside it).
        for scenario in graphGoldenScenarios {
            let drawings = rowDrawings(scenario.layout, commits: scenario.commits)
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
        #expect(rows[0].bendsBelow == nil)
        #expect(rows[1].bendsAbove == GraphBends(nodeLane: 0, lanes: [1]))
        // F's line turns into B, crossing halfway between the lanes.
        #expect(rows[1].bendsBelow == GraphBends(nodeLane: 0, lanes: [1]))
        #expect(rows[1].bottomX(lane: 1, from: 1, geometry: geometry) == geometry.crossingX(from: 1, to: 0))
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

    /// The drawing of each row of a whole layout, without HEAD.
    private func rowDrawings(_ layout: CommitGraphLayout, commits: [CommitGraphCommit]) -> [GraphRowDrawing] {
        let offset = layout.hasUncommittedWorkRow ? 1 : 0
        return layout.indices.map { index in
            GraphRowDrawing(
                layout: layout,
                row: index,
                isMerge: index >= offset && commits[index - offset].parentSHAs.count > 1,
                headRow: nil,
                hasHead: false,
                workingCopyIsDirty: true
            )
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
