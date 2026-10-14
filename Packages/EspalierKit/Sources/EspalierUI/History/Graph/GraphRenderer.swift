// Drawing one row of the history graph with Core Graphics. The lanes come
// from EspalierCore's `CommitGraphLayout`. The graph is a transit map:
// 3-point lines with round caps and joins, rings for commits, and a line
// that changes lanes (a merge leaving its node, a branch joining its parent)
// does so on a short diagonal centered on the boundary between two rows.
// Each row draws its half of such a diagonal, from where its neighbors say
// the line crosses, so a column of rows reads as one picture.

import AppKit
import EspalierCore

/// How a row's node is drawn.
nonisolated struct GraphNode: Sendable, Equatable {
    enum Shape: Sendable, Equatable {
        /// A commit: a ring.
        case commit
        /// A merge commit: a small ring.
        case merge
        /// The working copy: a dashed ring when there are changes, a faint
        /// ring when it's clean.
        case workingCopy(isDirty: Bool)
    }

    var shape: Shape
    /// The current tip (HEAD's commit): a bold ring with a dot in it.
    var isCurrentTip: Bool

    init(shape: Shape, isCurrentTip: Bool = false) {
        self.shape = shape
        self.isCurrentTip = isCurrentTip
    }

    static let commit = GraphNode(shape: .commit)
    static let merge = GraphNode(shape: .merge)

    /// The size the node is drawn at.
    var size: GraphNodeSize {
        if isCurrentTip {
            return .head
        }
        switch shape {
        case .commit: return .commit
        case .merge: return .merge
        case .workingCopy: return .workingCopy
        }
    }
}

/// The dashed edge joining the working copy to HEAD: which of a row's
/// segments belong to it.
nonisolated enum GraphDashedSegment: Sendable, Equatable {
    /// The working copy's own row: its line down.
    case outgoing(lane: Int)
    /// A row in between: the line passing through `lane`.
    case passing(lane: Int)
    /// HEAD's row: the line arriving from `lane`.
    case incoming(lane: Int)

    func contains(_ edge: CommitGraphEdge) -> Bool {
        switch self {
        case .outgoing(let lane): edge.kind == .outgoing && edge.lane == lane
        case .passing(let lane): edge.kind == .passing && edge.lane == lane
        case .incoming(let lane): edge.kind == .incoming && edge.lane == lane
        }
    }
}

/// The lines that change lanes at one of a row's edges: at its top, those
/// the row above's node sends into other lanes (merges); at its bottom,
/// those turning into the next row's node (forks).
nonisolated struct GraphBends: Sendable, Equatable {
    /// The neighboring row's node.
    var nodeLane: Int
    /// The lanes whose lines bend from or into it.
    var lanes: [Int]
    /// At the top: the lanes a merge joins while a line already runs
    /// straight down them, so two lines enter the lane and meet.
    var joinedLanes: [Int]

    init(nodeLane: Int, lanes: [Int], joinedLanes: [Int] = []) {
        self.nodeLane = nodeLane
        self.lanes = lanes
        self.joinedLanes = joinedLanes
    }

    /// The bends at the top of row `index`: the merges of the row above.
    init?(above index: Int, in layout: CommitGraphLayout) {
        guard index > 0, index - 1 < layout.count else {
            return nil
        }
        self.init(layout[index - 1], kind: .outgoing)
    }

    /// The bends at the bottom of row `index`: the lines turning into the
    /// next row's node.
    init?(below index: Int, in layout: CommitGraphLayout) {
        guard index >= 0, index + 1 < layout.count else {
            return nil
        }
        self.init(layout[index + 1], kind: .incoming)
    }

    private init?(_ row: CommitGraphRow, kind: CommitGraphEdge.Kind) {
        var lanes: [Int] = []
        for edge in row.edges where edge.kind == kind && edge.lane != row.lane {
            lanes.append(edge.lane)
        }
        guard !lanes.isEmpty else {
            return nil
        }
        var joined: [Int] = []
        if kind == .outgoing {
            for edge in row.edges where edge.kind == .passing && lanes.contains(edge.lane) {
                joined.append(edge.lane)
            }
        }
        self.init(nodeLane: row.lane, lanes: lanes, joinedLanes: joined)
    }

    /// Where the line in `lane` goes beyond the edge: the neighbor's node
    /// for a bending line, else its lane.
    func end(of lane: Int) -> Int {
        lanes.contains(lane) ? nodeLane : lane
    }
}

/// What one row of the graph draws.
nonisolated struct GraphRowDrawing: Sendable, Equatable {
    var row: CommitGraphRow
    /// The row's index, so dashes continue from the row above.
    var index: Int
    var node: GraphNode
    /// The working copy's dashed edge, where this row draws part of it.
    var dashed: GraphDashedSegment?
    /// Lines the row above's node sends into other lanes, crossing the top
    /// edge on a diagonal.
    var bendsAbove: GraphBends?
    /// Lines turning into the next row's node, crossing the bottom edge on
    /// a diagonal.
    var bendsBelow: GraphBends?

    init(row: CommitGraphRow, index: Int = 0, node: GraphNode, dashed: GraphDashedSegment? = nil, bendsAbove: GraphBends? = nil, bendsBelow: GraphBends? = nil) {
        self.row = row
        self.index = index
        self.node = node
        self.dashed = dashed
        self.bendsAbove = bendsAbove
        self.bendsBelow = bendsBelow
    }

    /// The drawing of row `index` of `layout`.
    ///
    /// - Parameters:
    ///   - isMerge: Whether the row's commit has more than one parent.
    ///   - headRow: HEAD's commit's row, when it's loaded.
    ///   - hasHead: Whether there is a HEAD commit (not an unborn branch):
    ///     the working copy's dashed edge runs to it, past rows not loaded.
    ///   - workingCopyIsDirty: Whether the working copy has changes.
    init(layout: CommitGraphLayout, row index: Int, isMerge: Bool, headRow: Int?, hasHead: Bool, workingCopyIsDirty: Bool) {
        let row = layout[index]
        if row.isUncommittedWork {
            node = GraphNode(shape: .workingCopy(isDirty: workingCopyIsDirty))
        } else {
            node = GraphNode(shape: isMerge ? .merge : .commit, isCurrentTip: index == headRow)
        }
        self.row = row
        self.index = index
        dashed = nil
        bendsAbove = GraphBends(above: index, in: layout)
        bendsBelow = GraphBends(below: index, in: layout)
        guard hasHead, layout.hasUncommittedWorkRow, !layout.isEmpty else {
            return
        }
        let lane = layout[0].lane
        if index == 0 {
            dashed = .outgoing(lane: lane)
        } else if let headRow, index == headRow {
            dashed = .incoming(lane: lane)
        } else if headRow.map({ index < $0 }) ?? true {
            dashed = .passing(lane: lane)
        }
    }
}

extension GraphRowDrawing {
    /// Whether two lines enter `lane` at the top: one straight down it, and
    /// a merge from the row above joining it.
    func joinsAbove(lane: Int) -> Bool {
        bendsAbove?.joinedLanes.contains(lane) == true
    }

    /// Where the line in `lane` crosses the row's top edge, given the lane
    /// it reaches in this row (the node's, for a line turning into it).
    func topX(lane: Int, reaching end: Int, geometry: GraphGeometry) -> CGFloat {
        geometry.crossingX(from: bendsAbove?.end(of: lane) ?? lane, to: end)
    }

    /// Where the line in `lane` crosses the row's bottom edge, given the
    /// lane it leaves from in this row (the node's, for a merge).
    func bottomX(lane: Int, from start: Int, geometry: GraphGeometry) -> CGFloat {
        geometry.crossingX(from: start, to: bendsBelow?.end(of: lane) ?? lane)
    }
}

/// How a row's graph is emphasized: selection, a hovered or focused track,
/// search dimming, and a node outline.
nonisolated struct GraphEmphasis: Sendable, Equatable {
    /// The row is selected: rings are filled with the selection's color
    /// rather than the background.
    var isSelected = false
    /// The track drawn at full strength while others are dimmed.
    var emphasizedTrack: Int?
    /// The other tracks' opacity while `emphasizedTrack` is set.
    var dimming: CGFloat = 1
    /// The node's opacity (search dims rows that don't match).
    var nodeOpacity: CGFloat = 1
    /// Dimmed tracks also draw dashed (Differentiate without color).
    var dashesDimmedTracks = false
    /// The node is outlined: a stub's other end, or a jump's target.
    var outlinesNode = false
    /// A stub of the row is loading its other end: a spinner shows at it.
    var isLoadingStub = false

    init() {}
}

/// The graph's colors for one appearance, resolved once and shared by every
/// row's drawing.
final class GraphColors {
    /// The tracks' colors.
    let palette: TrackPalette.Resolved
    private let trunk: CGColor
    private let current: CGColor
    private let named: [Int: CGColor]
    private let others: [CGColor]
    /// What fills a ring: the row's background, or a selected row's.
    let background: CGColor
    let selectedBackground: CGColor

    init(palette: TrackPalette.Resolved = TrackPalette.Resolved(), appearance: NSAppearance) {
        var trunk = Palette.accent.cgColor
        var current = trunk
        var named: [Int: CGColor] = [:]
        var others: [CGColor] = []
        var background = NSColor.white.cgColor
        var selectedBackground = background
        appearance.performAsCurrentDrawingAppearance {
            trunk = palette.trunk.cgColor
            current = palette.current.cgColor
            named = palette.namedTracks.mapValues(\.cgColor)
            others = palette.otherTracks.map(\.cgColor)
            let variant = AppearanceVariant.of(appearance)
            let base = Palette.background.resolved(in: variant)
            background = base.cgColor
            selectedBackground = ColorContrast.composite(Palette.accentSoft.resolved(in: variant), over: base).cgColor
        }
        self.palette = palette
        self.trunk = trunk
        self.current = current
        self.named = named
        self.others = others
        self.background = background
        self.selectedBackground = selectedBackground
    }

    /// The color of track `track`, as `TrackPalette.Resolved` gives it: the
    /// current branch's in the accent, a local branch's in its own color,
    /// the trunk's teal, the others the entries no branch has.
    func color(forTrack track: Int) -> CGColor {
        if track == palette.currentTrack {
            return current
        }
        if let color = named[track] {
            return color
        }
        guard track > 0, !others.isEmpty else {
            return trunk
        }
        return others[(track - 1) % others.count]
    }
}

/// Draws rows of the history graph.
enum GraphRenderer {
    /// Where a row's stubs end, for tooltips and clicks.
    struct StubTarget: Equatable {
        /// The index of the stub's segment in the row.
        var edgeIndex: Int
        var edge: CommitGraphEdge
        /// The point a click or hover is checked around.
        var point: CGPoint
    }

    /// Draws `drawing` into `context`, a flipped band with its top at
    /// y = 0. Nothing is allocated for ordinary rows.
    static func draw(
        _ drawing: GraphRowDrawing,
        emphasis: GraphEmphasis,
        geometry: GraphGeometry,
        colors: GraphColors,
        in context: CGContext
    ) {
        let row = drawing.row
        let nodeX = geometry.laneX(row.lane)
        let nodeY = geometry.nodeY
        let height = geometry.rowHeight
        let bend = geometry.bendHeight
        let clearance = geometry.clearance(drawing.node.size)
        let sides = Sides(row)

        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Dashes continue from the row above: lines start at the band's top.
        let dashPhase = (CGFloat(drawing.index) * height).truncatingRemainder(dividingBy: Metrics.Graph.dash.reduce(0, +))

        // Lines first, then stubs, then the node on top. Lines run to the
        // node's center, and its filled ring covers their ends.
        for edge in row.edges {
            var pen = Pen(edge.track, emphasis: emphasis, geometry: geometry, colors: colors, dashed: drawing.dashed?.contains(edge) == true)
            pen.dashPhase = dashPhase
            switch edge.kind {
            case .passing:
                // Straight down, finishing a diagonal from above or starting
                // one below where a neighbor bends this line.
                let x = geometry.laneX(edge.lane)
                let top = drawing.topX(lane: edge.lane, reaching: edge.lane, geometry: geometry)
                let bottom = drawing.bottomX(lane: edge.lane, from: edge.lane, geometry: geometry)
                pen.stroke(context) { context in
                    if top != x {
                        // The diagonal's whole length, from beyond the top
                        // edge: the band's edge cuts it where the row above
                        // cuts its half, so the two meet without a notch.
                        context.move(to: CGPoint(x: 2 * top - x, y: -bend))
                        context.addLine(to: CGPoint(x: x, y: bend))
                    } else {
                        context.move(to: CGPoint(x: x, y: 0))
                    }
                    if bottom != x {
                        context.addLine(to: CGPoint(x: x, y: height - bend))
                        context.addLine(to: CGPoint(x: 2 * bottom - x, y: height + bend))
                    } else {
                        context.addLine(to: CGPoint(x: x, y: height))
                    }
                    if drawing.joinsAbove(lane: edge.lane) {
                        // The line that was already in the lane, meeting
                        // the merge joining it.
                        context.move(to: CGPoint(x: x, y: 0))
                        context.addLine(to: CGPoint(x: x, y: bend))
                    }
                }
            case .incoming:
                // Down into the node, or (a fork, or a merge from the row
                // above) the second half of a diagonal into it.
                let top = drawing.topX(lane: edge.lane, reaching: row.lane, geometry: geometry)
                pen.stroke(context) { context in
                    let joint = CGPoint(x: nodeX, y: min(bend, nodeY))
                    // A diagonal starts beyond the top edge (see `.passing`).
                    func enter(at top: CGFloat) {
                        if top != nodeX {
                            context.move(to: CGPoint(x: 2 * top - nodeX, y: -joint.y))
                            context.addLine(to: joint)
                        } else {
                            context.move(to: CGPoint(x: nodeX, y: 0))
                        }
                    }
                    enter(at: top)
                    context.addLine(to: CGPoint(x: nodeX, y: nodeY))
                    if drawing.joinsAbove(lane: edge.lane) {
                        enter(at: geometry.crossingX(from: edge.lane, to: row.lane))
                        context.addLine(to: joint)
                    }
                }
            case .outgoing:
                // Down from the node, or (a merge, or a fork into the next
                // row) the first half of a diagonal.
                let bottom = drawing.bottomX(lane: edge.lane, from: row.lane, geometry: geometry)
                pen.stroke(context) { context in
                    context.move(to: CGPoint(x: nodeX, y: nodeY))
                    if bottom != nodeX {
                        // On beyond the bottom edge (see `.passing`).
                        let start = max(height - bend, nodeY)
                        context.addLine(to: CGPoint(x: nodeX, y: start))
                        context.addLine(to: CGPoint(x: 2 * bottom - nodeX, y: 2 * height - start))
                    } else {
                        context.addLine(to: CGPoint(x: nodeX, y: height))
                    }
                }
            case .unrouted, .incomingStub, .outgoingStub:
                continue
            }
        }

        var layout = StubLayout(sides: sides)
        for edge in row.edges {
            let pen = Pen(edge.track, emphasis: emphasis, geometry: geometry, colors: colors, dashed: false)
            switch edge.kind {
            case .outgoingStub:
                if edge.parentIndex ?? 0 == 0 {
                    drawOutgoingStub(from: nodeX, side: nil, pen: pen, geometry: geometry, clearance: clearance, in: context)
                } else if let side = layout.nextOutgoingSide() {
                    drawOutgoingStub(from: nodeX, side: side, pen: pen, geometry: geometry, clearance: clearance, in: context)
                }
            case .incomingStub:
                if let slot = layout.nextIncomingSlot() {
                    drawIncomingStub(to: nodeX, side: slot.side, pen: pen, geometry: geometry, clearance: clearance, in: context)
                }
            case .unrouted:
                drawUnrouted(edge, row: row, nodeX: nodeX, pen: pen, geometry: geometry, clearance: clearance, in: context)
            case .passing, .incoming, .outgoing:
                continue
            }
        }
        if layout.extraOutgoing > 0 {
            // Beside the last stub drawn, or beside the other one when that
            // side has no room (a node in lane 0).
            let ends = layout.outgoingSidesDrawn.map { side in
                (geometry.outgoingStubEnd(nodeX: nodeX, side: side), side)
            }
            drawCount(layout.extraOutgoing, candidates: ends.reversed(), geometry: geometry, colors: colors, track: row.track, opacity: nodeOpacity(row, emphasis: emphasis), in: context)
        }
        if layout.extraIncoming > 0 {
            let starts = layout.incomingSlotsDrawn.map { slot in
                (geometry.incomingStubStart(nodeX: nodeX, side: slot.side), slot.side ?? 1)
            }
            drawCount(layout.extraIncoming, candidates: starts.reversed(), geometry: geometry, colors: colors, track: row.track, opacity: nodeOpacity(row, emphasis: emphasis), in: context)
        }

        drawNode(drawing.node, row: row, at: CGPoint(x: nodeX, y: nodeY), emphasis: emphasis, geometry: geometry, colors: colors, in: context)
    }

    /// The stubs of a row and the points their ends are hit-tested around,
    /// laid out as `draw` lays them out.
    static func stubTargets(of row: CommitGraphRow, geometry: GraphGeometry) -> [StubTarget] {
        let nodeX = geometry.laneX(row.lane)
        var layout = StubLayout(sides: Sides(row))
        var targets: [StubTarget] = []
        for (index, edge) in row.edges.enumerated() {
            switch edge.kind {
            case .outgoingStub:
                if edge.parentIndex ?? 0 == 0 {
                    targets.append(StubTarget(edgeIndex: index, edge: edge, point: geometry.outgoingStubEnd(nodeX: nodeX, side: nil)))
                } else if let side = layout.nextOutgoingSide() {
                    targets.append(StubTarget(edgeIndex: index, edge: edge, point: geometry.outgoingStubEnd(nodeX: nodeX, side: side)))
                } else if let side = layout.lastOutgoingSide {
                    // Counted in "+N": it shares the last shown stub's end.
                    targets.append(StubTarget(edgeIndex: index, edge: edge, point: geometry.outgoingStubEnd(nodeX: nodeX, side: side)))
                }
            case .incomingStub:
                if let slot = layout.nextIncomingSlot() ?? layout.lastIncomingSlot {
                    targets.append(StubTarget(edgeIndex: index, edge: edge, point: geometry.incomingStubStart(nodeX: nodeX, side: slot.side)))
                }
            case .unrouted:
                targets.append(StubTarget(edgeIndex: index, edge: edge, point: unroutedEnd(edge, row: row, nodeX: nodeX, geometry: geometry)))
            case .passing, .incoming, .outgoing:
                continue
            }
        }
        return targets
    }

    // MARK: Stubs

    /// A long edge's child end: down from the node (a first parent), or
    /// diagonally down to the side (another parent), fading, with a
    /// chevron.
    private static func drawOutgoingStub(
        from nodeX: CGFloat,
        side: CGFloat?,
        pen: Pen,
        geometry: GraphGeometry,
        clearance: CGFloat,
        in context: CGContext
    ) {
        let nodeY = geometry.nodeY
        let end = geometry.outgoingStubEnd(nodeX: nodeX, side: side)
        let direction = CGVector(dx: end.x - nodeX, dy: end.y - nodeY).normalized
        let start = CGPoint(x: nodeX + direction.dx * clearance, y: nodeY + direction.dy * clearance)
        pen.strokeFading(from: start, to: end, fadeIn: false, in: context)
        pen.chevron(at: end, pointing: direction, in: context)
    }

    /// A long edge's parent end: from above the node (or diagonally from
    /// the side), fading in toward it, with a chevron where it starts.
    private static func drawIncomingStub(
        to nodeX: CGFloat,
        side: CGFloat?,
        pen: Pen,
        geometry: GraphGeometry,
        clearance: CGFloat,
        in context: CGContext
    ) {
        let nodeY = geometry.nodeY
        let start = geometry.incomingStubStart(nodeX: nodeX, side: side)
        let direction = CGVector(dx: nodeX - start.x, dy: nodeY - start.y).normalized
        let end = CGPoint(x: nodeX - direction.dx * clearance, y: nodeY - direction.dy * clearance)
        pen.strokeFading(from: start, to: end, fadeIn: true, in: context)
        pen.chevron(at: start, pointing: CGVector(dx: -direction.dx, dy: -direction.dy), in: context)
    }

    /// Where an `unrouted` edge's mark ends: up and to the left, toward a
    /// parent the input showed above its child.
    private static func unroutedEnd(_ edge: CommitGraphEdge, row: CommitGraphRow, nodeX: CGFloat, geometry: GraphGeometry) -> CGPoint {
        let reach = min((geometry.clearance(.commit) + Metrics.Graph.stubLength) / 2.squareRoot(), geometry.nodeY - 1)
        return CGPoint(x: nodeX - reach, y: geometry.nodeY - reach)
    }

    /// An edge the layout couldn't route: a short dashed mark toward its
    /// parent, with a chevron.
    private static func drawUnrouted(
        _ edge: CommitGraphEdge,
        row: CommitGraphRow,
        nodeX: CGFloat,
        pen: Pen,
        geometry: GraphGeometry,
        clearance: CGFloat,
        in context: CGContext
    ) {
        let end = unroutedEnd(edge, row: row, nodeX: nodeX, geometry: geometry)
        let nodeY = geometry.nodeY
        let direction = CGVector(dx: end.x - nodeX, dy: end.y - nodeY).normalized
        let start = CGPoint(x: nodeX + direction.dx * clearance, y: nodeY + direction.dy * clearance)
        var dashed = pen
        dashed.isDashed = true
        dashed.stroke(context) { context in
            context.move(to: start)
            context.addLine(to: end)
        }
        pen.chevron(at: end, pointing: direction, in: context)
    }

    /// "+N" for the stubs a node has beyond the two drawn: beside the first
    /// of `candidates` (a stub's end and its side) with room outward, at
    /// the node's opacity.
    private static func drawCount(
        _ count: Int,
        candidates: [(point: CGPoint, side: CGFloat)],
        geometry: GraphGeometry,
        colors: GraphColors,
        track: Int,
        opacity: CGFloat,
        in context: CGContext
    ) {
        guard let first = candidates.first else {
            return
        }
        let color = colors.color(forTrack: track)
        let font = AppKitTypography.tinyCount
        let text = NSAttributedString(string: "+\(count)", attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .secondaryLabelColor,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padding: CGFloat = 3
        let width = bounds.width + padding * 2
        let height = font.pointSize + 2
        func origin(_ candidate: (point: CGPoint, side: CGFloat)) -> CGFloat {
            candidate.side > 0 ? candidate.point.x + 2 : candidate.point.x - 2 - width
        }
        let fits = candidates.first { candidate in
            let x = origin(candidate)
            return x >= 0 && x + width <= geometry.columnWidth
        }
        let chosen = fits ?? first
        let x = min(max(origin(chosen), 0), max(geometry.columnWidth - width, 0))
        let capsule = CGRect(x: x, y: chosen.point.y - height / 2, width: width, height: height)
        context.saveGState()
        context.setAlpha(opacity)
        context.setFillColor(color.copy(alpha: 0.16) ?? color)
        context.addPath(CGPath(roundedRect: capsule, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.fillPath()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: capsule.minX + padding - bounds.minX, y: capsule.midY + (bounds.height / 2) + bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: Nodes

    /// A ring filled with the row's background (so the lines under it stop
    /// at it); the current tip's bold, with a dot in it.
    private static func drawNode(
        _ node: GraphNode,
        row: CommitGraphRow,
        at center: CGPoint,
        emphasis: GraphEmphasis,
        geometry: GraphGeometry,
        colors: GraphColors,
        in context: CGContext
    ) {
        let size = node.size
        let ring = geometry.ring(size)
        let color = colors.color(forTrack: row.track)
        let opacity = nodeOpacity(row, emphasis: emphasis)
        context.saveGState()
        defer { context.restoreGState() }

        if let dot = GraphDot(size, style: geometry.nodeStyle) {
            dot.draw(
                at: center,
                color: color,
                background: emphasis.isSelected ? colors.selectedBackground : colors.background,
                opacity: opacity,
                scale: geometry.nodeScale,
                extraStroke: geometry.extraStroke,
                in: context
            )
            if emphasis.outlinesNode {
                context.setAlpha(1)
                context.setStrokeColor(color)
                context.setLineWidth(Metrics.Graph.targetOutline)
                context.strokeEllipse(in: circle(center, outlineRadius(for: size, geometry: geometry)))
            }
            return
        }

        // The fill is opaque whatever the node's opacity (and whatever the
        // pens left on the context), so dimmed rings still hide the lines'
        // ends.
        context.setAlpha(1)
        context.setFillColor(emphasis.isSelected ? colors.selectedBackground : colors.background)
        context.fillEllipse(in: circle(center, ring.radius + ring.stroke / 2))

        context.setAlpha(opacity)
        context.setStrokeColor(color)
        context.setLineWidth(ring.stroke)
        switch node.shape {
        case .workingCopy(let isDirty):
            if isDirty {
                context.setLineDash(phase: 0, lengths: Metrics.Graph.dash)
                context.strokeEllipse(in: circle(center, ring.radius))
                context.setLineDash(phase: 0, lengths: [])
            } else {
                context.setAlpha(opacity * Metrics.Graph.cleanWorkingCopyOpacity)
                context.strokeEllipse(in: circle(center, ring.radius))
            }
        case .commit, .merge:
            context.strokeEllipse(in: circle(center, ring.radius))
        }
        if node.isCurrentTip {
            context.setFillColor(color)
            context.fillEllipse(in: circle(center, Metrics.Graph.headDotRadius * geometry.nodeScale))
        }

        if emphasis.outlinesNode {
            context.setAlpha(1)
            context.setLineWidth(Metrics.Graph.targetOutline)
            context.strokeEllipse(in: circle(center, outlineRadius(for: size, geometry: geometry)))
        }
    }

    /// A node's opacity: dimmed while another track is emphasized, and
    /// as search dims its row.
    private static func nodeOpacity(_ row: CommitGraphRow, emphasis: GraphEmphasis) -> CGFloat {
        let isEmphasized = emphasis.emphasizedTrack == nil || emphasis.emphasizedTrack == row.track
        return (isEmphasized ? 1 : emphasis.dimming) * emphasis.nodeOpacity
    }

    /// The radius of the outline that marks a node (a stub's other end, a
    /// jump's target): just outside its ring.
    static func outlineRadius(for size: GraphNodeSize, geometry: GraphGeometry) -> CGFloat {
        geometry.clearance(size) + Metrics.Graph.targetOutline / 2 + 1.5
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

// MARK: - Pens

/// How one segment strokes: its track's color, width, and emphasis.
private struct Pen {
    let color: CGColor
    let width: CGFloat
    /// The segment's opacity before fading.
    let opacity: CGFloat
    var isDashed: Bool
    /// Where in the dash pattern a path starts.
    var dashPhase: CGFloat = 0

    init(_ track: Int, emphasis: GraphEmphasis, geometry: GraphGeometry, colors: GraphColors, dashed: Bool) {
        let isEmphasized = emphasis.emphasizedTrack == track
        let isDimmed = emphasis.emphasizedTrack != nil && !isEmphasized
        color = colors.color(forTrack: track)
        opacity = isDimmed ? emphasis.dimming : 1
        width = geometry.stroke(track: track) + (isEmphasized ? Metrics.Graph.emphasizedStroke : 0)
        isDashed = dashed || (isDimmed && emphasis.dashesDimmedTracks)
    }

    /// Strokes the path `build` adds.
    func stroke(_ context: CGContext, _ build: (CGContext) -> Void) {
        context.setAlpha(opacity)
        context.setStrokeColor(color)
        context.setLineWidth(width)
        if isDashed {
            context.setLineCap(.butt)
            context.setLineDash(phase: dashPhase, lengths: Metrics.Graph.dash)
        }
        context.beginPath()
        build(context)
        context.strokePath()
        if isDashed {
            context.setLineDash(phase: 0, lengths: [])
            context.setLineCap(.round)
        }
    }

    /// Strokes a straight segment whose last (`fadeIn`: first)
    /// `stubFadeLength` points fade to clear, in one-point steps.
    func strokeFading(from start: CGPoint, to end: CGPoint, fadeIn: Bool, in context: CGContext) {
        let vector = CGVector(dx: end.x - start.x, dy: end.y - start.y)
        let length = (vector.dx * vector.dx + vector.dy * vector.dy).squareRoot()
        guard length > 0 else {
            return
        }
        let unit = CGVector(dx: vector.dx / length, dy: vector.dy / length)
        let fade = min(Metrics.Graph.stubFadeLength, length)
        let solid = length - fade
        func point(_ distance: CGFloat) -> CGPoint {
            CGPoint(x: start.x + unit.dx * distance, y: start.y + unit.dy * distance)
        }
        context.setStrokeColor(color)
        context.setLineWidth(width)
        // The solid part, from the node's side.
        let solidRange = fadeIn ? (fade, length) : (0, solid)
        if solidRange.1 > solidRange.0 {
            context.setAlpha(opacity)
            context.beginPath()
            context.move(to: point(solidRange.0))
            context.addLine(to: point(solidRange.1))
            context.strokePath()
        }
        // The fading part, in steps with butt caps so they don't overlap.
        let steps = max(Int(fade.rounded(.up)), 1)
        let step = fade / CGFloat(steps)
        context.setLineCap(.butt)
        for index in 0..<steps {
            let from = (fadeIn ? 0 : solid) + CGFloat(index) * step
            // Opacity falls toward the far end: the stub's end for an
            // outgoing stub, its start for an incoming one.
            let distanceFromNode = fadeIn ? fade - (CGFloat(index) + 0.5) * step : (CGFloat(index) + 0.5) * step
            let alpha = max(0, 1 - distanceFromNode / fade)
            context.setAlpha(opacity * alpha)
            context.beginPath()
            context.move(to: point(from))
            context.addLine(to: point(from + step))
            context.strokePath()
        }
        context.setLineCap(.round)
    }

    /// A small chevron at `point`, pointing along `direction`, at 60%.
    func chevron(at point: CGPoint, pointing direction: CGVector, in context: CGContext) {
        let unit = direction.normalized
        let size = Metrics.Graph.stubChevron
        // The arms go back from the tip at 45° to either side.
        let back = CGVector(dx: -unit.dx * size * 0.75, dy: -unit.dy * size * 0.75)
        let across = CGVector(dx: -unit.dy * size * 0.75, dy: unit.dx * size * 0.75)
        context.setAlpha(opacity * Metrics.Graph.stubChevronOpacity)
        context.setStrokeColor(color)
        context.setLineWidth(min(width, Metrics.Graph.trackStroke + 0.25))
        context.beginPath()
        context.move(to: CGPoint(x: point.x + back.dx + across.dx, y: point.y + back.dy + across.dy))
        context.addLine(to: point)
        context.addLine(to: CGPoint(x: point.x + back.dx - across.dx, y: point.y + back.dy - across.dy))
        context.strokePath()
    }
}

// MARK: - Stub placement

/// Which sides of a node its lines already use, so stubs go elsewhere.
private struct Sides {
    /// A merge line leaves the node to the right or left.
    var outgoingRight = false
    var outgoingLeft = false
    /// A fork arm arrives at the node from the right or left.
    var incomingRight = false
    var incomingLeft = false
    /// A line arrives at the node from straight above.
    var incomingAbove = false

    init(_ row: CommitGraphRow) {
        for edge in row.edges {
            switch edge.kind {
            case .outgoing where edge.lane != row.lane:
                if edge.lane > row.lane { outgoingRight = true } else { outgoingLeft = true }
            case .incoming:
                if edge.lane == row.lane {
                    incomingAbove = true
                } else if edge.lane > row.lane {
                    incomingRight = true
                } else {
                    incomingLeft = true
                }
            default:
                break
            }
        }
    }
}

/// Where an incoming stub arrives from.
private enum IncomingSlot: Equatable {
    /// Straight above the node.
    case above
    /// Diagonally from above and to the side (1 right, −1 left).
    case side(CGFloat)

    /// The side, or nil for straight above (`GraphGeometry`'s convention).
    var side: CGFloat? {
        if case .side(let side) = self { side } else { nil }
    }
}

/// Places a node's stubs one at a time: first-parent stubs go straight
/// down; other outgoing stubs go to a free side, the second to the other
/// side, and the rest are counted ("+N"). Incoming stubs come from straight
/// above when no line does, else diagonally from a free side; the second
/// goes to the other side, and the rest are counted.
private struct StubLayout {
    private let outgoingSlots: (CGFloat, CGFloat)
    private let incomingSlots: (IncomingSlot, IncomingSlot)
    private var outgoingCount = 0
    private var incomingCount = 0
    private(set) var extraOutgoing = 0
    private(set) var extraIncoming = 0
    private(set) var lastOutgoingSide: CGFloat?
    private(set) var lastIncomingSlot: IncomingSlot?

    /// The sides outgoing stubs were drawn on, in order.
    var outgoingSidesDrawn: [CGFloat] {
        [outgoingSlots.0, outgoingSlots.1].prefix(min(outgoingCount, 2)).map { $0 }
    }

    /// The slots incoming stubs were drawn in, in order.
    var incomingSlotsDrawn: [IncomingSlot] {
        [incomingSlots.0, incomingSlots.1].prefix(min(incomingCount, 2)).map { $0 }
    }

    init(sides: Sides) {
        outgoingSlots = sides.outgoingRight && !sides.outgoingLeft ? (-1, 1) : (1, -1)
        let incomingRightIsTaken = sides.incomingRight && !sides.incomingLeft
        if sides.incomingAbove {
            incomingSlots = incomingRightIsTaken ? (.side(-1), .side(1)) : (.side(1), .side(-1))
        } else {
            incomingSlots = (.above, incomingRightIsTaken ? .side(-1) : .side(1))
        }
    }

    /// The side of the next outgoing stub that isn't a first parent's, or
    /// nil when it's counted instead.
    mutating func nextOutgoingSide() -> CGFloat? {
        defer { outgoingCount += 1 }
        switch outgoingCount {
        case 0:
            lastOutgoingSide = outgoingSlots.0
        case 1:
            lastOutgoingSide = outgoingSlots.1
        default:
            extraOutgoing += 1
            return nil
        }
        return lastOutgoingSide
    }

    /// Where the next incoming stub arrives from, or nil when it's counted
    /// instead.
    mutating func nextIncomingSlot() -> IncomingSlot? {
        defer { incomingCount += 1 }
        switch incomingCount {
        case 0:
            lastIncomingSlot = incomingSlots.0
        case 1:
            lastIncomingSlot = incomingSlots.1
        default:
            extraIncoming += 1
            return nil
        }
        return lastIncomingSlot
    }
}

extension CGVector {
    /// The vector scaled to length 1 (zero stays zero).
    fileprivate var normalized: CGVector {
        let length = (dx * dx + dy * dy).squareRoot()
        return length > 0 ? CGVector(dx: dx / length, dy: dy / length) : self
    }
}
