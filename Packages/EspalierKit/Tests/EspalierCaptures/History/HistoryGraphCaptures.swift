// The history graph's drawing, row by row with each row's name and stubs
// beside it: nine of the engine's golden histories (GraphGoldenHistories),
// then what they don't reach: three or more stubs on a node, a stub beside
// a line, HEAD and the working copy clean and dirty, compressed lanes,
// every kind of emphasis, and Increase Contrast.

import AppKit
import EspalierCore
import Testing
@testable import EspalierUI

@Suite("History graph", .captures) @MainActor
struct HistoryGraphCaptures {
    private let area = "HistoryGraph"

    @Test("the engine's golden layouts that cover each drawing primitive", arguments: graphGoldenHistories)
    func goldens(_ golden: GraphGoldenHistory) {
        let layout = golden.layout
        let rows = GraphCapture.rows(layout, commits: golden.commits, headSHA: golden.options.headSHA)
        capture(rows, geometry: GraphGeometry(rowHeight: 32, laneCount: layout.laneCount), named: golden.captureName)
    }

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
        let rows = GraphCapture.rows(layout, commits: commits, headSHA: nil)
        capture(rows, geometry: GraphGeometry(rowHeight: 32, laneCount: layout.laneCount), named: "stubs-many")
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
        let rows = GraphCapture.rows(layout, commits: commits, headSHA: nil)
        capture(rows, geometry: GraphGeometry(rowHeight: 32, laneCount: layout.laneCount), named: "stubs-beside-line")
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
        let layout = graphLayout(commits, CommitGraphOptions(trunkTip: "m2", includesUncommittedWork: true, headSHA: "f1"))
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount)
        // f2 sits between the working copy and HEAD: the dashed edge passes it.
        capture(GraphCapture.rows(layout, commits: commits, headSHA: "f1"), geometry: geometry, named: "workingCopy-dirty")
        capture(GraphCapture.rows(layout, commits: commits, headSHA: "f1", workingCopyIsDirty: false), geometry: geometry, named: "workingCopy-clean")
    }

    @Test("past twelve lanes the pitch compresses")
    func compressedLanes() {
        // Fourteen branches open at once, merged by an octopus.
        let branches = (1...14).map { "b\($0)" }
        let history = (["O m1 " + branches.joined(separator: " ")] + branches.map { "\($0) B" } + ["m1 B", "B"]).joined(separator: "\n")
        let commits = graphCommits(history)
        let layout = graphLayout(commits, CommitGraphOptions(trunkTip: "O"))
        let rows = GraphCapture.rows(layout, commits: commits, headSHA: nil)
        capture(rows, geometry: GraphGeometry(rowHeight: 32, laneCount: layout.laneCount), named: "lanes-compressed")
    }

    @Test("selection, hover, focus, search, and outlines")
    func emphasis() throws {
        let golden = try #require(graphGoldenHistories.first { $0.name == "feature merged back" })
        let layout = golden.layout
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount)
        let base = GraphCapture.rows(layout, commits: golden.commits, headSHA: "M")

        var selected = base
        selected[1].isSelected = true
        selected[2].isSelected = true
        capture(selected, geometry: geometry, named: "emphasis-selected")

        // Hovering the feature's line dims the others to 40%.
        capture(base.map { row in
            var row = row
            row.emphasis.emphasizedTrack = 1
            row.emphasis.dimming = Metrics.Graph.hoverDimming
            return row
        }, geometry: geometry, named: "emphasis-hover")

        // A focused branch dims the others to 28%; with Differentiate
        // without color they're also dashed.
        capture(base.map { row in
            var row = row
            row.emphasis.emphasizedTrack = 0
            row.emphasis.dimming = Metrics.Graph.focusDimming
            row.emphasis.dashesDimmedTracks = true
            return row
        }, geometry: geometry, named: "emphasis-focus")

        // Rows that don't match the search dim their nodes; a jump's target
        // is outlined.
        capture(base.enumerated().map { index, row in
            var row = row
            row.emphasis.nodeOpacity = index == 2 ? 1 : Metrics.Graph.searchDimming
            row.emphasis.outlinesNode = index == 2
            return row
        }, geometry: geometry, named: "emphasis-search")
    }

    @Test("Increase Contrast thickens every stroke")
    func increaseContrast() throws {
        let golden = try #require(graphGoldenHistories.first { $0.name == "branch from a branch" })
        let layout = golden.layout
        let geometry = GraphGeometry(rowHeight: 32, laneCount: layout.laneCount, increaseContrast: true)
        capture(GraphCapture.rows(layout, commits: golden.commits, headSHA: nil), geometry: geometry, named: "increaseContrast")
    }

    /// Captures `rows` drawn with `geometry`.
    private func capture(_ rows: [GraphCaptureRow], geometry: GraphGeometry, named name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        EspalierCaptures.capture(named: name, area: area, sourceLocation: sourceLocation) { appearance in
            GraphCapture.render(rows, geometry: geometry, appearance: appearance)
        }
    }
}
