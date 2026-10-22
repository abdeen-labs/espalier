// The simple list's table in SwiftUI (an `NSTableView` behind
// `NSViewRepresentable`, as the graph's is, for lists of every commit), and
// the table's own keys: → and ← expand and collapse a merge, Return opens
// the selected commit's files, Esc stops loading, End loads the rest, and
// keyboard reorder's ↑↓, Return, and Esc.

import AppKit
import EspalierCore
import SwiftUI

/// The simple list's table.
struct SimpleListTableView: NSViewRepresentable {
    let history: HistoryModel
    /// The outline shown (read here so the view updates with it).
    let outline: SimpleHistoryOutline
    /// The history's list the outline is of.
    let listGeneration: UInt64
    let isLoadingMore: Bool
    let presentation: SimpleListPresentation
    let selection: [String]
    /// The keyboard reorder's insertion point (a history row), while
    /// reordering.
    let reorderInsertionRow: Int?
    let actions: SimpleListActions

    @Environment(\.avatarLoader) private var avatarLoader
    @Environment(\.dateTimeFormatting) private var dateTimeFormatting
    @Environment(\.numberFormat) private var numberFormat
    @Environment(\.timeZone) private var timeZone

    init(history: HistoryModel, presentation: SimpleListPresentation, selection: [String], reorderInsertionRow: Int?, actions: SimpleListActions) {
        self.history = history
        outline = history.simpleOutline
        listGeneration = history.graphChange.reloadGeneration
        isLoadingMore = history.isLoadingMore
        self.presentation = presentation
        self.selection = selection
        self.reorderInsertionRow = reorderInsertionRow
        self.actions = actions
    }

    func makeCoordinator() -> SimpleListController {
        SimpleListController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let controller = context.coordinator
        controller.actions = actions
        controller.avatarLoader = avatarLoader
        controller.dateFormatting = dateTimeFormatting
        controller.timeZone = timeZone
        controller.numberFormat = numberFormat
        controller.update(history: history, presentation: presentation, selection: selection, reorderInsertionRow: reorderInsertionRow)
    }
}

/// The simple list's `NSTableView`: its keys, the merges' chevrons, and the
/// context menu.
final class SimpleNSTableView: NSTableView, ContextMenuContentProviding {
    weak var controller: SimpleListController?
    /// The row whose context menu is open.
    lazy var contextMenuTarget = TableContextMenuTarget(table: self)
    /// Whether keyboard reorder is on: ↑↓ move the insertion point, Return
    /// confirms, Esc cancels.
    var isReordering = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command]).isEmpty,
           controller?.click(at: point) == true {
            return
        }
        super.mouseDown(with: event)
    }

    func contextMenuContent(at point: CGPoint) -> MenuContent? {
        controller?.menu(forClickedRow: row(at: point))
    }

    func markContextMenuTarget(at point: CGPoint) -> (() -> Void)? {
        contextMenuTarget.mark(row(at: point))
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
        } else if modifiers.isEmpty, let row = selectedRowIndexes.count == 1 ? selectedRowIndexes.first : nil {
            switch key {
            case 0x0D, 0x03:
                controller?.activateSelection()
                return
            case NSRightArrowFunctionKey:
                controller?.setExpanded(true, atTableRow: row)
                return
            case NSLeftArrowFunctionKey:
                controller?.setExpanded(false, atTableRow: row)
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

    /// Find Next (⌘G) and Find Previous (⇧⌘G) move between search matches;
    /// Find (⌘F) focuses the toolbar's search.
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
        case .showFindInterface:
            controller?.actions.showFind()
        default:
            NSSound.beep()
        }
    }

    /// Edit ▸ Find's items send this (NSTextView's selector).
    @objc func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return !selectedRowIndexes.isEmpty
        case #selector(performTextFinderAction(_:)), #selector(performFindPanelAction(_:)):
            let action = NSTextFinder.Action(rawValue: item.tag)
            return action == .nextMatch || action == .previousMatch || action == .showFindInterface
        default:
            return super.validateUserInterfaceItem(item)
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
