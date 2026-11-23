// The history graph's geometry.

import AppKit

extension Metrics.Graph {
    /// The width of the outline that marks a stub's other end, and a jump's
    /// target.
    static let targetOutline: CGFloat = 2
    /// The 2-on-2 dash of the working copy's ring and edge, and of
    /// `unrouted` edges.
    static let dash: [CGFloat] = [2, 2]
    /// The working copy is a ring: the radius of its stroke's center line,
    /// and its stroke, thinner than a line, so its dashes read as dashes.
    static let workingCopyRadius: CGFloat = 6
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

    /// A node is a dot: a commit's, a merge's (with a hole), the current
    /// tip's, and the hole's radius in each, with a gap of the row's
    /// background around them.
    static let dotRadius: CGFloat = 6
    static let headDotNodeRadius: CGFloat = 7.5
    static let mergeHoleRadius: CGFloat = 2.5
    static let headHoleRadius: CGFloat = 3
    static let dotGap: CGFloat = 2
}

/// The kinds of node a row draws, for their sizes.
nonisolated enum GraphNodeSize: Sendable, Equatable {
    /// A commit's dot.
    case commit
    /// A merge commit's dot, with a hole.
    case merge
    /// The current tip's bigger dot, with a hole.
    case head
    /// The working copy's dashed ring.
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
    /// The lines' width: the theme's.
    let lineWidth: CGFloat

    /// - Parameters:
    ///   - rowHeight: The row height (`Metrics.HistoryRows.height`).
    ///   - laneCount: The most lanes any row seen so far uses.
    ///   - increaseContrast: Whether Increase Contrast is on.
    init(rowHeight: CGFloat = Metrics.HistoryRows.height, laneCount: Int, increaseContrast: Bool = false) {
        self.rowHeight = rowHeight
        self.laneCount = max(laneCount, 1)
        let compressed = self.laneCount > Metrics.Graph.maxUncompressedLanes
        lanePitch = compressed ? Metrics.Graph.compressedLanePitch : Metrics.Graph.lanePitch
        columnWidth = Metrics.Graph.columnWidth(lanes: self.laneCount)
        bendHeight = (rowHeight * Metrics.Graph.bendFraction).rounded()
        nodeScale = compressed ? Metrics.Graph.compressedNodeScale : 1
        extraStroke = increaseContrast ? Metrics.Graph.increaseContrastStroke : 0
        lineWidth = Theme.current.graph.lineWidth
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

    /// The working copy's ring: the radius of its stroke's center line, and
    /// the stroke.
    var workingCopyRing: (radius: CGFloat, stroke: CGFloat) {
        (Metrics.Graph.workingCopyRadius * nodeScale, Metrics.Graph.workingCopyStroke + extraStroke)
    }

    /// How far from the node's center its dot's gap (or the working copy's
    /// ring) reaches: lines stop there, and stubs start there.
    func clearance(_ size: GraphNodeSize) -> CGFloat {
        if let dot = GraphDot(size) {
            return dot.clearance(scale: nodeScale, extraStroke: extraStroke)
        }
        let ring = workingCopyRing
        return ring.radius + ring.stroke / 2
    }

    /// A segment's stroke width.
    func stroke(track: Int) -> CGFloat {
        lineWidth + extraStroke
    }

    /// Where an outgoing stub ends: below the node for a first parent,
    /// diagonally below and beside it for the others (`side` 1 for the
    /// right, −1 for the left). Stubs are laid out around a commit's dot.
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

/// A node drawn as a dot: every node but the working copy's, which is a
/// dashed ring.
struct GraphDot: Equatable {
    /// The dot's radius, and the hole's in it (a merge's, the current
    /// tip's), at full scale.
    var radius: CGFloat
    var hole: CGFloat?
    /// The gap of background around it.
    var gap: CGFloat

    init?(_ size: GraphNodeSize) {
        let graph = Metrics.Graph.self
        switch size {
        case .workingCopy:
            return nil
        case .commit:
            self.init(radius: graph.dotRadius, gap: graph.dotGap)
        case .merge:
            self.init(radius: graph.dotRadius, hole: graph.mergeHoleRadius, gap: graph.dotGap)
        case .head:
            self.init(radius: graph.headDotNodeRadius, hole: graph.headHoleRadius, gap: graph.dotGap)
        }
    }

    init(radius: CGFloat, hole: CGFloat? = nil, gap: CGFloat) {
        self.radius = radius
        self.hole = hole
        self.gap = gap
    }

    /// How far from the center the dot and its gap reach.
    func clearance(scale: CGFloat, extraStroke: CGFloat) -> CGFloat {
        (radius + gap) * scale + extraStroke / 2
    }

    /// Draws the dot at `center`: the gap in `background`, the dot in
    /// `color` at `opacity`, and the hole.
    func draw(at center: CGPoint, color: CGColor, background: CGColor, opacity: CGFloat, scale: CGFloat, extraStroke: CGFloat, in context: CGContext) {
        func circle(_ radius: CGFloat) -> CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
        let radius = radius * scale + extraStroke / 2
        // The gap is opaque whatever the node's opacity, so dimmed dots
        // still hide the lines' ends.
        context.setAlpha(1)
        context.knockOutEllipse(in: circle(clearance(scale: scale, extraStroke: extraStroke)), background: background)
        context.setAlpha(opacity)
        context.setFillColor(color)
        context.fillEllipse(in: circle(radius))
        if let hole {
            context.knockOutEllipse(in: circle(hole * scale), background: background)
        }
    }
}

extension CGContext {
    /// Fills the ellipse in `rect` with `background`: a gap or hole a node
    /// makes in what's drawn.
    nonisolated func knockOutEllipse(in rect: CGRect, background: CGColor) {
        setFillColor(background)
        fillEllipse(in: rect)
    }
}
