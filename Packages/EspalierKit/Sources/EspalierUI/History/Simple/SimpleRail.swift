// The rail of History's simple list: the branch as one line. Each row draws
// its part of one line in the branch's color, with the graph's nodes: HEAD's
// commit a bold ring with a dot, other commits rings, merge commits small
// rings. Whether a commit is pushed shows by its title, as in the graph. From
// the commit where the branch started, the line takes the base's color, so
// where it began shows without a heading. A merge has a stub in the merged
// branch's color that leaves on a short diagonal and fades out; expanded, the
// merged commits sit on that stub, 16 to the right, with small rings, and it
// fades out below the last of them. Every color is a branch's
// (`BranchColors`), so the rail matches the sidebar and the graph.

import AppKit
import EspalierCore
import GitKit

/// What one row's rail draws.
struct SimpleRail: Equatable {
    /// The row's node, as the graph draws it.
    enum Node: Equatable {
        /// No node: the row is the status line under a merge's commits.
        case none
        /// HEAD's commit: a bold ring with a dot.
        case head
        /// A commit: a ring.
        case commit
        /// A merge commit: a small ring.
        case merge
        /// A commit a merge brought in, on the merge's stub: a small ring.
        case merged
    }

    /// A line that fades out toward the row's bottom, or runs on.
    struct SideLine: Equatable {
        var color: NSColor
        var fades: Bool
    }

    var node = Node.none
    /// The node's color.
    var nodeColor: NSColor?
    /// The branch's line above the node (or the row's middle), and below
    /// it; nil where the line starts or ends.
    var top: NSColor?
    var bottom: NSColor?
    /// A merge's stub, leaving its node.
    var stub: SideLine?
    /// The merged commits' line beside the branch's (their rows, and the
    /// status line under them).
    var side: SideLine?
    /// The row doesn't match the search: its node dims.
    var isDimmed = false
}

/// The colors the rail takes from the repository's branches.
struct SimpleRailColors: Equatable {
    /// The branch's line: the shown branch's color (the current branch's is
    /// the accent).
    var line: NSColor
    /// The base's color, from the row the branch started at.
    var base: NSColor?
    /// That row.
    var startRow: Int?
    /// The repository's branches, for merged branches' colors.
    var branchColors: BranchColors?

    init(line: NSColor = Palette.accent, base: NSColor? = nil, startRow: Int? = nil, branchColors: BranchColors? = nil) {
        self.line = line
        self.base = base
        self.startRow = startRow
        self.branchColors = branchColors
    }

    /// The colors for `branchColors` and where the branch started: for the
    /// line of `branch` (another branch's place), or of the current branch
    /// when nil.
    init(branchColors: BranchColors, start: SimpleHistoryStart?, branch: Branch? = nil) {
        let line = branch.map { branchColors.color(of: (name: $0.name, isRemote: $0.type == .remote)) }
            ?? branchColors.current.flatMap { branchColors.color(forBranch: $0) }
            ?? Palette.accent
        let base = start.map { branchColors.color(of: (name: $0.base.name, isRemote: $0.base.type == .remote)) }
        self.init(line: line, base: base, startRow: start?.row, branchColors: branchColors)
    }

    /// The line's color at and below the node of `row`: the base's from
    /// where the branch started.
    func lineColor(atRow row: Int) -> NSColor {
        if let base, let startRow, row >= startRow {
            return base
        }
        return line
    }

    /// The color of the branch a merge brought in (its stub and commits).
    func mergedColor(branch: String?, isPullRequest: Bool, merge: String) -> NSColor {
        branchColors?.color(forMergedBranch: branch, isPullRequest: isPullRequest, merge: merge)
            ?? TrackPalette.palette().first.map(TrackPalette.color(of:))
            ?? TrackPalette.trunk
    }

    // MARK: Rails

    /// The rail of the commit in `row` of the branch's line.
    ///
    /// - Parameters:
    ///   - isHead: The commit is HEAD's.
    ///   - isLast: The row ends the line (a root commit, or a shallow
    ///     clone's last).
    ///   - merge: For a merge, the merged branch's color and whether its
    ///     commits show under it.
    func rail(row: Int, isHead: Bool, isLast: Bool, merge: (color: NSColor, isExpanded: Bool)?, isDimmed: Bool) -> SimpleRail {
        var rail = SimpleRail()
        rail.node = isHead ? .head : merge == nil ? .commit : .merge
        rail.nodeColor = row == 0 ? line : lineColor(atRow: row)
        rail.top = row == 0 ? nil : lineColor(atRow: row - 1)
        rail.bottom = isLast ? nil : lineColor(atRow: row)
        rail.stub = merge.map { SimpleRail.SideLine(color: $0.color, fades: !$0.isExpanded) }
        rail.isDimmed = isDimmed
        return rail
    }

    /// The rail of a commit the merge in `mergeRow` brought in.
    ///
    /// - Parameter isLast: The last line under the merge: its stub fades
    ///   out below it.
    func mergedRail(mergeRow: Int, color: NSColor, isLast: Bool, isDimmed: Bool) -> SimpleRail {
        var rail = SimpleRail()
        rail.node = .merged
        rail.nodeColor = color
        rail.top = lineColor(atRow: mergeRow)
        rail.bottom = lineColor(atRow: mergeRow)
        rail.side = SimpleRail.SideLine(color: color, fades: isLast)
        rail.isDimmed = isDimmed
        return rail
    }

    /// The rail of the status line under the merge in `mergeRow`'s
    /// commits: the stub fades out in it.
    func statusRail(mergeRow: Int, color: NSColor) -> SimpleRail {
        var rail = SimpleRail()
        rail.top = lineColor(atRow: mergeRow)
        rail.bottom = lineColor(atRow: mergeRow)
        rail.side = SimpleRail.SideLine(color: color, fades: true)
        return rail
    }
}

/// Draws a row's rail.
final class SimpleRailView: NSView {
    var rail = SimpleRail() {
        didSet {
            if rail != oldValue {
                needsDisplay = true
            }
        }
    }

    /// The row is selected: nodes are filled with the selection's color.
    var isSelectedRow = false {
        didSet {
            if isSelectedRow != oldValue {
                needsDisplay = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        SimpleRailRenderer.draw(
            rail,
            height: bounds.height,
            isSelected: isSelectedRow,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            appearance: effectiveAppearance,
            in: context
        )
    }
}

/// Draws rails with Core Graphics, in a flipped band whose top is y = 0.
enum SimpleRailRenderer {
    static func draw(_ rail: SimpleRail, height: CGFloat, isSelected: Bool, increaseContrast: Bool, appearance: NSAppearance, in context: CGContext) {
        let metrics = Metrics.SimpleList.self
        let graph = Metrics.Graph.self
        let x0 = metrics.lineX
        let x1 = metrics.mergedLineX
        let middle = (height / 2).rounded()
        let extraStroke = increaseContrast ? graph.increaseContrastStroke : 0
        var colors: [NSColor: CGColor] = [:]
        var background = NSColor.white.cgColor
        appearance.performAsCurrentDrawingAppearance {
            for color in [rail.nodeColor, rail.top, rail.bottom, rail.stub?.color, rail.side?.color].compactMap(\.self) {
                colors[color] = color.cgColor
            }
            let variant = AppearanceVariant.of(appearance)
            let base = Palette.background.resolved(in: variant)
            background = (isSelected ? ColorContrast.composite(Palette.accentSoft.resolved(in: variant), over: base) : base).cgColor
        }
        func cg(_ color: NSColor) -> CGColor {
            colors[color] ?? color.cgColor
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(graph.trackStroke + extraStroke)
        context.setLineCap(.butt)
        context.setLineJoin(.round)

        // The branch's line, above and below the node (or the middle).
        if let top = rail.top {
            line(from: CGPoint(x: x0, y: 0), to: CGPoint(x: x0, y: middle), color: cg(top), in: context)
        }
        if let bottom = rail.bottom {
            line(from: CGPoint(x: x0, y: middle), to: CGPoint(x: x0, y: height), color: cg(bottom), in: context)
        }

        // The merged commits' line, beside it.
        if let side = rail.side {
            let hasNode = rail.node != .none
            if hasNode {
                line(from: CGPoint(x: x1, y: 0), to: CGPoint(x: x1, y: middle), color: cg(side.color), in: context)
            }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x1, y: hasNode ? middle : 0))
            path.addLine(to: CGPoint(x: x1, y: height))
            stroke(path, color: cg(side.color), fadingFrom: side.fades ? (hasNode ? middle + metrics.fadeStart : 0) : nil, to: height, in: context)
        }

        // A merge's stub: a short diagonal, a turn down, then on to the
        // row's bottom.
        if let stub = rail.stub {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x0, y: middle))
            path.addLine(to: CGPoint(x: x0 + metrics.stubDiagonal, y: middle + metrics.stubDiagonal))
            path.addQuadCurve(
                to: CGPoint(x: x1, y: middle + metrics.stubTurnEnd),
                control: CGPoint(x: x1, y: middle + 2 * metrics.stubDiagonal)
            )
            path.addLine(to: CGPoint(x: x1, y: height))
            context.setLineCap(.round)
            stroke(path, color: cg(stub.color), fadingFrom: stub.fades ? middle + metrics.fadeStart : nil, to: height, in: context)
            context.setLineCap(.butt)
        }

        // The node, on top.
        guard let nodeColor = rail.nodeColor.map(cg) else {
            return
        }
        let center = CGPoint(x: rail.node == .merged ? x1 : x0, y: middle)
        let opacity = rail.isDimmed ? graph.searchDimming : 1
        func circle(_ radius: CGFloat) -> CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
        let nodeStyle = Theme.current.graph.node
        let size: GraphNodeSize? = switch rail.node {
        case .none: nil
        case .head: .head
        case .commit: .commit
        case .merge, .merged: .merge
        }
        if let size, let dot = GraphDot(size, style: nodeStyle) {
            dot.draw(at: center, color: nodeColor, background: background, opacity: opacity, scale: 1, extraStroke: extraStroke, in: context)
            return
        }
        func ring(radius: CGFloat, width: CGFloat) {
            let width = width + extraStroke
            // Filled with the background, so the lines stop at it.
            context.setFillColor(background)
            context.fillEllipse(in: circle(radius + width / 2))
            context.setAlpha(opacity)
            context.setStrokeColor(nodeColor)
            context.setLineWidth(width)
            context.strokeEllipse(in: circle(radius))
        }
        switch rail.node {
        case .none:
            break
        case .head:
            ring(radius: graph.headNodeRadius, width: graph.headNodeStroke)
            context.setFillColor(nodeColor)
            context.fillEllipse(in: circle(graph.headDotRadius))
        case .commit:
            ring(radius: graph.nodeRadius, width: graph.nodeStroke)
        case .merge, .merged:
            ring(radius: graph.mergeNodeRadius, width: graph.mergeNodeStroke)
        }
    }

    private static func line(from start: CGPoint, to end: CGPoint, color: CGColor, in context: CGContext) {
        context.setStrokeColor(color)
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    /// Strokes `path`, fading it out from `fadeStart` to `end` (y) when
    /// there's a start.
    private static func stroke(_ path: CGPath, color: CGColor, fadingFrom fadeStart: CGFloat?, to end: CGFloat, in context: CGContext) {
        guard let fadeStart,
              let gradient = CGGradient(colorsSpace: color.colorSpace, colors: [color, color.copy(alpha: 0) ?? color] as CFArray, locations: [0, 1])
        else {
            context.setStrokeColor(color)
            context.addPath(path)
            context.strokePath()
            return
        }
        context.saveGState()
        context.addPath(path)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: fadeStart), end: CGPoint(x: 0, y: end), options: [.drawsBeforeStartLocation])
        context.restoreGState()
    }
}
