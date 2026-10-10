// A commit row's ref capsules: at most three, then "+N", whose popover
// lists the rest. Drawn with the design system's `RefCapsuleRenderer`.

import AppKit
import SwiftUI

/// Draws a row's ref capsules.
final class RefCapsulesView: NSView {
    /// The refs, in the order they show.
    var refs: [RefCapsuleContent] = [] {
        didSet {
            if refs != oldValue {
                items = []
                laidOutWidth = nil
                needsDisplay = true
            }
        }
    }

    /// The colors capsules take their track colors from.
    var palette = TrackPalette.Resolved() {
        didSet {
            needsDisplay = true
        }
    }

    private var items: [RefCapsuleRenderer.Item] = []
    private var laidOutWidth: CGFloat?
    private var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    /// Lays the capsules out in at most `maximumWidth` and returns the width
    /// they take (0 for none).
    func layoutCapsules(maximumWidth: CGFloat) -> CGFloat {
        guard !refs.isEmpty else {
            items = []
            return 0
        }
        if laidOutWidth != maximumWidth || items.isEmpty {
            items = RefCapsuleRenderer.layout(refs, maximumWidth: maximumWidth)
            laidOutWidth = maximumWidth
            needsDisplay = true
        }
        return RefCapsuleRenderer.width(of: items)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty else {
            return
        }
        RefCapsuleRenderer.draw(items, at: .zero, palette: palette, appearance: effectiveAppearance)
    }

    // MARK: The overflow popover

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let overflow = items.first(where: { $0.content == nil && $0.frame.contains(point) }) else {
            super.mouseDown(with: event)
            return
        }
        showOverflow(from: overflow.frame)
    }

    /// Shows the refs that don't fit, in a popover.
    func showOverflow(from rect: CGRect? = nil) {
        let shown = items.filter { $0.content != nil }.count
        let rest = Array(refs.dropFirst(shown))
        guard !rest.isEmpty else {
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: RefOverflowList(refs: rest, palette: palette))
        let anchor = rect ?? items.last?.frame ?? bounds
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        self.popover = popover
    }
}

/// The refs a row has no room for.
struct RefOverflowList: View {
    let refs: [RefCapsuleContent]
    var palette = TrackPalette.Resolved()

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.RefCapsule.spacing) {
            ForEach(refs) { ref in
                RefCapsule(ref, palette: palette)
            }
        }
        .padding(Metrics.insetMedium)
    }
}
