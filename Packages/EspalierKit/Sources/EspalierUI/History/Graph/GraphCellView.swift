// The view that draws one row of the history graph. It draws in `draw(_:)`
// with Core Graphics from the row's segments, in O(1) per row, and is
// hidden from accessibility: the row describes the graph in words.

import AppKit
import EspalierCore
import GitKit
import QuartzCore
import os

/// Draws one row of the history graph.
final class GraphCellView: NSView, TooltipOwner {
    /// What the row draws; nil draws nothing.
    var drawing: GraphRowDrawing? {
        didSet {
            if drawing != oldValue {
                needsDisplay = true
                removeTargetOutline()
                updateToolTips()
            }
        }
    }

    /// The tooltip for the node (no stub) or a stub of the row `row`.
    var tooltipProvider: ((_ row: Int, _ stub: GraphRenderer.StubTarget?) -> String?)?
    private var stubTargets: [GraphRenderer.StubTarget] = []

    /// Selection, hover, focus, and search dimming.
    var emphasis = GraphEmphasis() {
        didSet {
            if emphasis != oldValue {
                needsDisplay = true
            }
            if emphasis.isLoadingStub != oldValue.isLoadingStub {
                updateSpinner()
            }
        }
    }

    /// The spinner at a stub whose other end is loading.
    private var spinner: ArcProgressView?

    private func updateSpinner() {
        guard emphasis.isLoadingStub, let drawing,
              let stub = GraphRenderer.stubTargets(of: drawing.row, geometry: geometry).first(where: { $0.edge.kind == .outgoingStub && $0.edge.parentRow == nil }) else {
            spinner?.removeFromSuperview()
            spinner = nil
            return
        }
        let size = Metrics.Progress.ArcSize.mini.side
        let indicator = spinner ?? ArcProgressView(.mini)
        indicator.frame = CGRect(x: stub.point.x - size / 2, y: stub.point.y - size / 2, width: size, height: size)
        if indicator.superview == nil {
            addSubview(indicator)
        }
        spinner = indicator
    }

    /// Where lanes and nodes are.
    var geometry = GraphGeometry(laneCount: 1) {
        didSet {
            if geometry != oldValue {
                needsDisplay = true
                updateToolTips()
            }
        }
    }

    /// The colors for the view's appearance, shared by every row.
    var colors: GraphColors? {
        didSet {
            if colors !== oldValue {
                needsDisplay = true
            }
        }
    }

    /// The format the stubs' counts draw in.
    var numberFormat = defaultNumberFormat {
        didSet {
            if numberFormat != oldValue {
                needsDisplay = true
            }
        }
    }

    private var targetLayer: CAShapeLayer?

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

    override func draw(_ dirtyRect: NSRect) {
        guard let drawing, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let colors = colors ?? GraphColors(appearance: effectiveAppearance)
        if UISignposts.signposter.isEnabled {
            let state = UISignposts.begin(.graphCellDraw)
            GraphRenderer.draw(drawing, emphasis: emphasis, geometry: geometry, colors: colors, numberFormat: numberFormat, in: context)
            UISignposts.end(.graphCellDraw, state)
        } else {
            GraphRenderer.draw(drawing, emphasis: emphasis, geometry: geometry, colors: colors, numberFormat: numberFormat, in: context)
        }
    }

    // MARK: Tooltips

    /// Tooltip areas for the node and each stub's end, made again only when
    /// they move (most rows have a node in the same place and no stubs).
    private func updateToolTips() {
        guard let drawing else {
            if nodeToolTipRect != nil {
                removeTooltipAreas()
                nodeToolTipRect = nil
            }
            stubTargets = []
            return
        }
        let row = drawing.row
        let radius = geometry.clearance(drawing.node.size) + 1
        let center = CGPoint(x: geometry.laneX(row.lane), y: geometry.nodeY)
        let nodeRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let targets = GraphRenderer.stubTargets(of: row, geometry: geometry)
        guard nodeRect != nodeToolTipRect || targets.map(\.point) != stubTargets.map(\.point) else {
            stubTargets = targets
            return
        }
        removeTooltipAreas()
        nodeToolTipRect = nodeRect
        addTooltipArea(nodeRect, owner: self, tag: 0)
        stubTargets = targets
        for index in stubTargets.indices {
            addTooltipArea(geometry.hitArea(around: stubTargets[index].point), owner: self, tag: index + 1)
        }
    }

    private var nodeToolTipRect: CGRect?

    /// The node's tooltip (tag 0), or a stub's (its index plus one).
    func tooltip(for view: NSView, tag: Int, at point: CGPoint) -> String? {
        guard let drawing else {
            return nil
        }
        let stub = stubTargets.indices.contains(tag - 1) ? stubTargets[tag - 1] : nil
        return tooltipProvider?(drawing.index, stub)
    }

    // MARK: Jump targets

    /// Marks the node as a jump's target: two pulses of an outline, or with
    /// Reduce Motion a still outline for a moment.
    func pulseNode(reduceMotion: Bool) {
        guard let drawing, let layer else {
            return
        }
        removeTargetOutline()
        let row = drawing.row
        let radius = GraphRenderer.outlineRadius(for: drawing.node.size, geometry: geometry)
        let center = CGPoint(x: geometry.laneX(row.lane), y: geometry.nodeY)
        let outline = CAShapeLayer()
        outline.frame = bounds
        outline.isGeometryFlipped = !layer.contentsAreFlipped()
        outline.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        outline.fillColor = nil
        outline.lineWidth = Metrics.Graph.targetOutline
        var color = Palette.accent.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = (colors?.color(forTrack: row.track)) ?? Palette.accent.cgColor
        }
        outline.strokeColor = color
        layer.addSublayer(outline)
        targetLayer = outline

        if reduceMotion {
            outline.opacity = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stillOutlineDuration) { [weak self, weak outline] in
                guard let self, let outline, self.targetLayer === outline else {
                    return
                }
                self.removeTargetOutline()
            }
        } else {
            outline.opacity = 0
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0
            pulse.toValue = 1
            pulse.duration = Motion.pulse
            pulse.autoreverses = true
            pulse.repeatCount = 2
            // Eased in and out, as a scroll is.
            pulse.timingFunction = Motion.scrollTimingFunction
            outline.add(pulse, forKey: "pulse")
        }
    }

    /// How long the still outline shows under Reduce Motion.
    static let stillOutlineDuration: TimeInterval = 1.5

    private func removeTargetOutline() {
        targetLayer?.removeFromSuperlayer()
        targetLayer = nil
    }
}
