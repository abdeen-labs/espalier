// The history graph's table in SwiftUI. An `NSTableView` behind
// `NSViewRepresentable`, as the API reference recommends for 100,000 rows;
// the table handles the graph's own keys (Return, Esc, End, keyboard
// reorder), stub clicks and hover, and the context menu.

import AppKit
import EspalierCore
import SwiftUI

/// The history graph's table.
struct GraphTableView: NSViewRepresentable {
    /// The history shown.
    let source: any GraphTableSource
    let presentation: GraphPresentation
    let selection: GraphSelection
    /// The keyboard reorder's insertion point, while reordering.
    let reorderInsertionRow: Int?
    let actions: GraphTableActions
    /// Called once with the table's controller (for the window's actions:
    /// jumps, reveals).
    var onController: (GraphTableController) -> Void = { _ in }
    /// The change the model last published, so the view updates with it.
    let graphGeneration: UInt64
    let isLoadingMore: Bool

    @Environment(\.avatarLoader) private var avatarLoader
    @Environment(\.fixedNow) private var fixedNow
    @Environment(\.dateTimeFormatting) private var dateTimeFormatting
    @Environment(\.timeZone) private var timeZone

    init(
        source: any GraphTableSource,
        presentation: GraphPresentation,
        selection: GraphSelection,
        reorderInsertionRow: Int? = nil,
        actions: GraphTableActions,
        onController: @escaping (GraphTableController) -> Void = { _ in }
    ) {
        self.source = source
        self.presentation = presentation
        self.selection = selection
        self.reorderInsertionRow = reorderInsertionRow
        self.actions = actions
        self.onController = onController
        graphGeneration = source.graphChange.generation
        isLoadingMore = source.isLoadingMore
    }

    func makeCoordinator() -> GraphTableController {
        GraphTableController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        onController(controller)
        return controller.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let controller = context.coordinator
        controller.actions = actions
        controller.avatarLoader = avatarLoader
        controller.dateFormatting = dateTimeFormatting
        controller.timeZone = timeZone
        if controller.fixedNow != fixedNow {
            controller.fixedNow = fixedNow
        }
        controller.update(source: source, presentation: presentation, selection: selection, reorderInsertionRow: reorderInsertionRow)
    }
}

/// The graph's `NSTableView`: the graph's keys, stub clicks, hover, and
/// context menus.
final class GraphNSTableView: NSTableView {
    weak var controller: GraphTableController?
    /// Whether keyboard reorder is on: ↑↓ move the insertion point, Return
    /// confirms, Esc cancels.
    var isReordering = false
    /// The row whose stub is loading its other end.
    var loadingStubRow: Int?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        controller?.pointerMoved(to: point)
        if controller?.hitTest(point).stub != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.pointerExited()
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command]).isEmpty,
           controller?.click(at: point) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else {
            return nil
        }
        return controller?.menu(forClickedRow: row)
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) }
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if isReordering {
            switch key {
            case NSUpArrowFunctionKey where modifiers.isEmpty:
                controller?.actions.moveReorderInsertion(-1)
                return
            case NSDownArrowFunctionKey where modifiers.isEmpty:
                controller?.actions.moveReorderInsertion(1)
                return
            case 0x0D, 0x03:
                controller?.actions.confirmReorder()
                return
            default:
                break
            }
        } else if key == 0x0D || key == 0x03, modifiers.isEmpty {
            controller?.activateSelection()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if isReordering {
            controller?.actions.cancelReorder()
            return
        }
        controller?.cancelLoading()
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        super.scrollToEndOfDocument(sender)
        controller?.loadRemainingPages()
    }

    /// ⌘C: the selected commits' SHAs.
    @objc func copy(_ sender: Any?) {
        controller?.actions.copy()
    }

    /// Find Next (⌘G) and Find Previous (⇧⌘G) move between search matches.
    override func performTextFinderAction(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
              let action = NSTextFinder.Action(rawValue: tag) else {
            return
        }
        switch action {
        case .nextMatch:
            _ = controller?.actions.moveSearchMatch(true)
        case .previousMatch:
            _ = controller?.actions.moveSearchMatch(false)
        default:
            NSSound.beep()
        }
    }

    /// Edit ▸ Find's items send this (NSTextView's selector); their tags
    /// are `NSTextFinder.Action`'s.
    @objc func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return !selectedRowIndexes.isEmpty
        case #selector(performTextFinderAction(_:)), #selector(performFindPanelAction(_:)):
            let action = NSTextFinder.Action(rawValue: item.tag)
            return action == .nextMatch || action == .previousMatch
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.appearanceDidChange()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            controller?.appearanceDidChange()
        }
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        controller?.dragExited()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        controller?.dragExited()
    }
}
