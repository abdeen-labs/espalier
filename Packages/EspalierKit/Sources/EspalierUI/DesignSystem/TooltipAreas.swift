// AppKit views' tooltips: a tooltip over a view's whole bounds
// (`setTooltip(_:)`), and tooltip areas whose text an owner gives as each
// is about to show (`addTooltipArea(_:owner:tag:)`). A view with either
// gets a `TooltipTracker`, the owner of a tracking area over the view's
// visible part, which tells its window's `TooltipCenter` where the pointer
// is. A view's whole-bounds tooltip is also its VoiceOver help.

import AppKit
import ObjectiveC

/// Gives the text of a view's tooltip areas as each is about to show.
@MainActor
public protocol TooltipOwner: AnyObject {
    /// The tooltip of `view`'s area tagged `tag`, the pointer at `point` (in
    /// the view's coordinates); nil or empty for none.
    func tooltip(for view: NSView, tag: Int, at point: CGPoint) -> String?
}

extension NSView {
    private static var tooltipTrackerKey: UInt8 = 0

    /// The view's tracker, once it has had a tooltip or a tooltip area.
    var tooltipTracker: TooltipTracker? {
        objc_getAssociatedObject(self, &Self.tooltipTrackerKey) as? TooltipTracker
    }

    /// The view's tracker, made the first time it's asked for.
    func makeTooltipTracker() -> TooltipTracker {
        if let tracker = tooltipTracker {
            return tracker
        }
        let tracker = TooltipTracker(view: self)
        objc_setAssociatedObject(self, &Self.tooltipTrackerKey, tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return tracker
    }

    /// Shows `text` as the view's tooltip, over its whole bounds, and makes
    /// it the view's VoiceOver help. Nil or empty is none.
    public func setTooltip(_ text: String?) {
        let text = text.flatMap { $0.isEmpty ? nil : $0 }
        guard text != tooltipTracker?.text else {
            return
        }
        makeTooltipTracker().text = text
        setAccessibilityHelp(text)
    }

    /// The view's tooltip over its whole bounds, if any.
    public var tooltipText: String? {
        tooltipTracker?.text
    }

    /// Adds a tooltip area: `rect`, in the view's coordinates, whose text
    /// `owner` gives (for `tag`) as it's about to show. It shows below the
    /// area. An area takes the pointer from the view's whole-bounds tooltip
    /// and from areas added before it.
    public func addTooltipArea(_ rect: CGRect, owner: any TooltipOwner, tag: Int = 0) {
        makeTooltipTracker().areas.append(TooltipArea(rect: rect, tag: tag, owner: owner))
    }

    /// Removes the view's tooltip areas.
    public func removeTooltipAreas() {
        guard let tracker = tooltipTracker, !tracker.areas.isEmpty else {
            return
        }
        tracker.areas = []
    }
}

extension NSWindow {
    private static var tooltipCenterKey: UInt8 = 0

    /// The center that shows the window's tooltips: the shared one, or a
    /// test's.
    var tooltipCenter: TooltipCenter {
        get {
            (objc_getAssociatedObject(self, &Self.tooltipCenterKey) as? TooltipCenter) ?? .shared
        }
        set {
            objc_setAssociatedObject(self, &Self.tooltipCenterKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

/// A tooltip area of a view.
struct TooltipArea {
    /// In the view's coordinates.
    var rect: CGRect
    var tag: Int
    weak var owner: (any TooltipOwner)?
}

/// Follows the pointer over a view with a tooltip or tooltip areas, through
/// a tracking area over the view's visible part, and tells the view's
/// window's `TooltipCenter`.
@MainActor
final class TooltipTracker: NSResponder {
    private(set) weak var view: NSView?
    /// The tooltip over the view's whole bounds; nil for none.
    var text: String? {
        didSet {
            if text != oldValue {
                changed()
            }
        }
    }

    /// The view's tooltip areas, later ones first under the pointer.
    var areas: [TooltipArea] = [] {
        didSet {
            changed()
        }
    }

    /// The center the tracker last told, for when the view has left its
    /// window.
    private weak var lastCenter: TooltipCenter?

    init(view: NSView) {
        self.view = view
        super.init()
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect]
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseEntered(with event: NSEvent) {
        report(.entered, event)
    }

    override func mouseMoved(with event: NSEvent) {
        report(.moved, event)
    }

    override func mouseExited(with event: NSEvent) {
        report(.exited, event)
    }

    private func report(_ change: TooltipCenter.PointerChange, _ event: NSEvent) {
        let window = event.window ?? view?.window
        guard let center = window.map({ $0.tooltipCenter }) ?? lastCenter else {
            return
        }
        lastCenter = center
        center.pointer(change, tracker: self, at: event.locationInWindow, in: window)
    }

    private func changed() {
        (view?.window?.tooltipCenter ?? lastCenter)?.tooltipChanged(self)
    }

    /// The tooltip area at `point` (in the view's coordinates): the last
    /// area added there, else the whole view when it has a tooltip; nil
    /// when the view is hidden or the point is outside its visible part.
    func target(at point: CGPoint) -> TooltipCenter.Target? {
        guard let view, !view.isHiddenOrHasHiddenAncestor else {
            return nil
        }
        // Views don't clip to their bounds, so the visible rect can reach
        // past them.
        let visible = view.visibleRect.intersection(view.bounds)
        guard visible.contains(point) else {
            return nil
        }
        if let index = areas.lastIndex(where: { $0.owner != nil && $0.rect.contains(point) }) {
            return TooltipCenter.Target(tracker: self, area: index, rect: areas[index].rect)
        }
        guard text != nil else {
            return nil
        }
        return TooltipCenter.Target(tracker: self, area: nil, rect: visible)
    }

    /// The text of `target`, the pointer at `point` (in the view's
    /// coordinates): the whole view's, or what the area's owner gives.
    func text(of target: TooltipCenter.Target, at point: CGPoint) -> String? {
        guard let index = target.area else {
            return text
        }
        guard areas.indices.contains(index), let view, let owner = areas[index].owner else {
            return nil
        }
        return owner.tooltip(for: view, tag: areas[index].tag, at: point)
    }
}
