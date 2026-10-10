// The history graph's geometry.

import AppKit

extension Metrics.Graph {
    /// The width of the outline that marks a stub's other end, and a jump's
    /// target.
    static let targetOutline: CGFloat = 2
    /// The 2-on-2 dash of the working copy's ring and edge, and of
    /// `unrouted` edges.
    static let dash: [CGFloat] = [2, 2]
    /// The working copy's dashed ring is thinner than a line, so its
    /// dashes read as dashes.
    static let workingCopyStroke: CGFloat = 2
    /// A dimmed track's opacity while another track is hovered.
    static let hoverDimming: CGFloat = 0.4
    /// A dimmed track's opacity while a branch or tag is focused.
    static let focusDimming: CGFloat = 0.28
    /// A row's opacity when it doesn't match the search.
    static let searchDimming: CGFloat = 0.35
    /// The clean working copy's ring opacity.
    static let cleanWorkingCopyOpacity: CGFloat = 0.5
    /// Added to the stroke of the focused or hovered track.
    static let emphasizedStroke: CGFloat = 0.5
}

/// The kinds of node a row draws, for their sizes.
nonisolated enum GraphNodeSize: Sendable, Equatable {
    /// A commit's ring.
    case commit
    /// A merge commit's small ring.
    case merge
    /// The current tip's bold ring.
    case head
    /// The working copy's ring.
    case workingCopy
}

/// Where a row's lanes, node, bends, and stubs are. Rows are drawn in a
/// flipped band whose top is y = 0 and whose bottom is the row height.
struct GraphGeometry: Equatable {
    /// H: the row height.
    let rowHeight: CGFloat
    /// The number of lanes the column is sized for: the most seen so far.
    let laneCount: Int
    /// P: the lane pitch, compressed past `Metrics.Graph.maxUncompressedLanes`.
    let lanePitch: CGFloat
    /// The graph column's width.
    let columnWidth: CGFloat
    /// How much of a lane change's diagonal each row draws: it runs from
    /// `bendHeight` above a row boundary to `bendHeight` below it.
    let bendHeight: CGFloat
    /// Nodes' scale: smaller once lanes are compressed.
    let nodeScale: CGFloat
    /// Added to every stroke (Increase Contrast).
    let extraStroke: CGFloat

    /// - Parameters:
    ///   - rowHeight: The row height (`Metrics.Graph.rowHeight`).
    ///   - laneCount: The most lanes any row seen so far uses.
    ///   - increaseContrast: Whether Increase Contrast is on.
    init(rowHeight: CGFloat = Metrics.Graph.rowHeight, laneCount: Int, increaseContrast: Bool = false) {
        self.rowHeight = rowHeight
        self.laneCount = max(laneCount, 1)
        let compressed = self.laneCount > Metrics.Graph.maxUncompressedLanes
        lanePitch = compressed ? Metrics.Graph.compressedLanePitch : Metrics.Graph.lanePitch
        columnWidth = Metrics.Graph.columnWidth(lanes: self.laneCount)
        bendHeight = (rowHeight * Metrics.Graph.bendFraction).rounded()
        nodeScale = compressed ? Metrics.Graph.compressedNodeScale : 1
        extraStroke = increaseContrast ? Metrics.Graph.increaseContrastStroke : 0
    }

    /// The x of a lane's center.
    func laneX(_ lane: Int) -> CGFloat {
        Metrics.Graph.laneX(lane, pitch: lanePitch)
    }

    /// Where a line crosses a row boundary on its way from lane `from`
    /// (above) to lane `to` (below): halfway, so the diagonal is centered
    /// on the boundary and each row draws half of it.
    func crossingX(from: Int, to: Int) -> CGFloat {
        from == to ? laneX(from) : (laneX(from) + laneX(to)) / 2
    }

    /// The y of the node's center.
    var nodeY: CGFloat {
        (rowHeight / 2).rounded(.down)
    }

    /// A node's ring: the radius of its stroke's center line, and the
    /// stroke.
    func ring(_ size: GraphNodeSize) -> (radius: CGFloat, stroke: CGFloat) {
        switch size {
        case .commit:
            (Metrics.Graph.nodeRadius * nodeScale, Metrics.Graph.nodeStroke + extraStroke)
        case .merge:
            (Metrics.Graph.mergeNodeRadius * nodeScale, Metrics.Graph.mergeNodeStroke + extraStroke)
        case .head:
            (Metrics.Graph.headNodeRadius * nodeScale, Metrics.Graph.headNodeStroke + extraStroke)
        case .workingCopy:
            (Metrics.Graph.nodeRadius * nodeScale, Metrics.Graph.workingCopyStroke + extraStroke)
        }
    }

    /// How far from the node's center its ring reaches: lines stop there,
    /// and stubs start there.
    func clearance(_ size: GraphNodeSize) -> CGFloat {
        let ring = ring(size)
        return ring.radius + ring.stroke / 2
    }

    /// A segment's stroke width.
    func stroke(track: Int) -> CGFloat {
        Metrics.Graph.trackStroke + extraStroke
    }

    /// Where an outgoing stub ends: below the node for a first parent,
    /// diagonally below and beside it for the others (`side` 1 for the
    /// right, −1 for the left). Stubs are laid out around a commit's ring.
    func outgoingStubEnd(nodeX: CGFloat, side: CGFloat?) -> CGPoint {
        let reach = clearance(.commit) + Metrics.Graph.stubLength
        guard let side else {
            return CGPoint(x: nodeX, y: min(nodeY + reach, rowHeight - 1))
        }
        let diagonal = min(reach / 2.squareRoot(), rowHeight - 1 - nodeY)
        return CGPoint(x: nodeX + side * diagonal, y: nodeY + diagonal)
    }

    /// Where an incoming stub starts (its far end): straight above the node,
    /// or diagonally above and to the side (`side` 1 for the right, −1 for
    /// the left).
    func incomingStubStart(nodeX: CGFloat, side: CGFloat?) -> CGPoint {
        let reach = clearance(.commit) + Metrics.Graph.stubLength
        guard let side else {
            return CGPoint(x: nodeX, y: max(nodeY - reach, 1))
        }
        let diagonal = min(reach / 2.squareRoot(), nodeY - 1)
        return CGPoint(x: nodeX + side * diagonal, y: nodeY - diagonal)
    }

    /// The square a stub's end can be clicked in.
    func hitArea(around point: CGPoint) -> CGRect {
        let size = Metrics.Graph.stubHitArea
        return CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }
}
