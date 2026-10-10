// The AppKit diff table and its SwiftUI wrapper. The table is a view-based
// `NSTableView` with one row per diff row and no cell views: each row view
// draws its row. The table takes the mouse (staging, text selection, hunk
// headers), the keyboard (the line cursor, Space, ⌥Space, ⌥↑ and ⌥↓, copy,
// select all), the find bar (`NSTextFinder`), and context menus. When lines
// don't wrap, it's wider than the pane and the scroll view scrolls it
// sideways.

import AppKit
import EspalierCore
import GitKit
import SwiftUI

/// The diff table.
final class DiffTableView: NSTableView {
    weak var controller: DiffTableController?
    private var trackingArea: NSTrackingArea?
    /// The window whose find actions come here.
    private weak var findWindow: NSWindow?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        controller?.redrawVisibleRows()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        controller?.redrawVisibleRows()
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let findWindow, findWindow !== newWindow {
            DiffFindForwarder.detach(self, from: findWindow)
            self.findWindow = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            DiffFindForwarder.attach(self, to: window)
            findWindow = window
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        controller?.liveResizeDidEnd()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let controller else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let drag = controller.mouseDown(
            at: point,
            clickCount: event.clickCount,
            extendsSelection: event.modifierFlags.contains(.shift)
        )
        guard drag != .none, let window else {
            return
        }
        // Track the drag, autoscrolling while the pointer is outside (every
        // 50 ms without a mouse event, rather than with periodic events,
        // which can't be started twice).
        var lastDrag = event
        while true {
            let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.05),
                inMode: .eventTracking,
                dequeue: true
            )
            guard let next else {
                let point = convert(lastDrag.locationInWindow, from: nil)
                if !visibleRect.contains(point) {
                    autoscroll(with: lastDrag)
                    controller.mouseDragged(to: point, drag: drag)
                }
                continue
            }
            if next.type == .leftMouseUp {
                controller.mouseUp(drag: drag)
                return
            }
            lastDrag = next
            autoscroll(with: next)
            controller.mouseDragged(to: convert(next.locationInWindow, from: nil), drag: drag)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.mouseMoved(to: point)
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.mouseMoved(to: nil)
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at point: CGPoint) {
        if controller?.showsTextCursor(at: point) == true {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else {
            return nil
        }
        return controller.menu(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Scrolling

    /// Rows draw at the visible part of the table, so they redraw as it
    /// scrolls sideways: scrolling stays on the main thread, in step with
    /// them.
    override class var isCompatibleWithResponsiveScrolling: Bool {
        false
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if controller?.keyDown(event) == true {
            return
        }
        // Page Up and Down, Home, and End scroll as in any table.
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        controller?.copySelection()
    }

    override func selectAll(_ sender: Any?) {
        controller?.selectAll()
    }

    // MARK: Find

    override func performTextFinderAction(_ sender: Any?) {
        guard let controller, let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
              let action = NSTextFinder.Action(rawValue: tag) else {
            return
        }
        controller.textFinder.performAction(action)
    }

    /// Edit ▸ Find's items send this (NSTextView's selector); their tags
    /// are `NSTextFinder.Action`'s.
    @objc func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let controller else {
            return false
        }
        switch item.action {
        case #selector(copy(_:)):
            return controller.canCopy
        case #selector(selectAll(_:)):
            return controller.document.rowCount > 0
        case #selector(performTextFinderAction(_:)), #selector(performFindPanelAction(_:)):
            guard let action = NSTextFinder.Action(rawValue: item.tag) else {
                return false
            }
            return controller.textFinder.validateAction(action)
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Accessibility

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        controller?.accessibilityRotors() ?? []
    }
}

/// The diff table in SwiftUI.
struct DiffTextView: NSViewRepresentable {
    let content: DiffTableContent
    let actions: DiffTableActions
    @Environment(\.diffBuildsSynchronously) private var buildsSynchronously

    func makeCoordinator() -> DiffTableController {
        DiffTableController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.buildsSynchronously = buildsSynchronously
        return context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let controller = context.coordinator
        controller.buildsSynchronously = buildsSynchronously
        controller.actions = actions
        controller.apply(content)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: DiffTableController) {
        coordinator.tearDown()
    }
}

extension EnvironmentValues {
    /// Builds diff documents on the main actor, so a snapshot renders the
    /// rows at once.
    @Entry var diffBuildsSynchronously = false
}
