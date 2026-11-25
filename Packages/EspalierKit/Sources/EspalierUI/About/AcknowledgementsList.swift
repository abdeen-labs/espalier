// The Acknowledgements window's sidebar: the components under their groups'
// labels, one selected. An AppKit table in an `UnbouncedScrollView`, so a
// flick never shows it past its ends (the overscroll bug, CLAUDE.md).

import AppKit
import SwiftUI

extension Metrics {
    /// The Acknowledgements sidebar's rows.
    enum AcknowledgementsList {
        /// A component's row: a list row and the point above and below it.
        static let rowHeight: CGFloat = Metrics.ListRow.height + 2
        /// The text's inset from the table's sides.
        static let textInset: CGFloat = Metrics.ListRow.inset + Metrics.ListRow.horizontalPadding
    }
}

/// The components by group, the selected one in the list selection. The up
/// and down arrows move through the components, and typing a name selects it.
struct AcknowledgementsList: NSViewRepresentable {
    /// A row: a group's label, or a component.
    enum Row: Equatable {
        case group(String)
        case component(id: String, name: String)
    }

    let rows: [Row]
    @Binding var selection: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = AcknowledgementsTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("component"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // Rows inset and round their own selection (`AcknowledgementRowView`).
        tableView.style = .plain
        tableView.focusRingType = .none
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = true
        tableView.backgroundColor = .clear
        tableView.setAccessibilityLabel("Components")
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.coordinator = context.coordinator
        context.coordinator.tableView = tableView

        // The sidebar's fill is behind the scroll view, under the title bar
        // too.
        let scrollView = UnbouncedScrollView(fadesEdges: false)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        context.coordinator.update(self)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    /// The table's data source and delegate.
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var parent: AcknowledgementsList
        weak var tableView: AcknowledgementsTableView?
        /// Whether the table's selection is being set from the binding.
        private var isApplyingSelection = false

        init(_ parent: AcknowledgementsList) {
            self.parent = parent
        }

        private var rows: [Row] {
            parent.rows
        }

        /// Shows `list`'s rows and selects its selection's row.
        func update(_ list: AcknowledgementsList) {
            let rowsChanged = list.rows != parent.rows
            parent = list
            guard let tableView else {
                return
            }
            if rowsChanged {
                isApplyingSelection = true
                tableView.reloadData()
                isApplyingSelection = false
            }
            applySelection(to: tableView)
        }

        /// Whether `row` is a component: a group's label can't be selected.
        func isSelectable(_ row: Int) -> Bool {
            guard rows.indices.contains(row), case .component = rows[row] else {
                return false
            }
            return true
        }

        /// The row of the binding's component, or nil with none selected.
        private var selectedRow: Int? {
            guard let selection = parent.selection else {
                return nil
            }
            return rows.firstIndex { row in
                if case .component(let id, _) = row {
                    return id == selection
                }
                return false
            }
        }

        private func applySelection(to tableView: NSTableView) {
            let indexes = selectedRow.map { IndexSet(integer: $0) } ?? IndexSet()
            guard tableView.selectedRowIndexes != indexes else {
                return
            }
            isApplyingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if case .group = rows[row] {
                return AcknowledgementCellView.groupHeight
            }
            return Metrics.AcknowledgementsList.rowHeight
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: AcknowledgementCellView.identifier, owner: nil) as? AcknowledgementCellView
                ?? AcknowledgementCellView()
            cell.configure(rows[row])
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            tableView.makeView(withIdentifier: AcknowledgementRowView.identifier, owner: nil) as? AcknowledgementRowView
                ?? AcknowledgementRowView()
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            isSelectable(row)
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            if case .component(_, let name) = rows[row] {
                return name
            }
            return nil
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else {
                return
            }
            let row = tableView.selectedRow
            guard rows.indices.contains(row), case .component(let id, _) = rows[row] else {
                // A click below the rows selects nothing: the component
                // shown stays selected.
                applySelection(to: tableView)
                return
            }
            if parent.selection != id {
                parent.selection = id
            }
        }
    }
}

/// The sidebar's table.
final class AcknowledgementsTableView: NSTableView {
    weak var coordinator: AcknowledgementsList.Coordinator?

    /// The arrows move through the components, past the groups' labels.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let isArrow = event.keyCode == KeyCode.upArrow || event.keyCode == KeyCode.downArrow
        guard modifiers.isEmpty, isArrow, let coordinator else {
            super.keyDown(with: event)
            return
        }
        let step = event.keyCode == KeyCode.downArrow ? 1 : -1
        var row = selectedRow + step
        while row >= 0, row < numberOfRows, !coordinator.isSelectable(row) {
            row += step
        }
        guard row >= 0, row < numberOfRows else {
            return
        }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // A group's first component shows with its label.
        if row > 0, !coordinator.isSelectable(row - 1) {
            scrollRowToVisible(row - 1)
        }
        scrollRowToVisible(row)
    }
}

extension AcknowledgementsTableView: LookChangeObserving {
    /// The rows' fonts, colors, and heights follow the look.
    func lookDidChange() {
        let selected = selectedRowIndexes
        reloadData()
        selectRowIndexes(selected, byExtendingSelection: false)
    }
}

/// A row: it draws a selected component's rounded selection, inset from
/// the table's sides.
final class AcknowledgementRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("Espalier.AcknowledgementRow")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool {
        false
    }

    /// The text keeps its color on the selection.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        Palette.accentSoft.setFill()
        let rect = bounds.insetBy(dx: Metrics.ListRow.inset, dy: 1)
        NSBezierPath(roundedRect: rect, xRadius: Metrics.Radius.row, yRadius: Metrics.Radius.row).fill()
    }
}

/// A row's text: a component's name, or a group's label in the theme's
/// section label style.
final class AcknowledgementCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("Espalier.AcknowledgementCell")

    private let label = NSTextField(labelWithString: "")
    private var isGroup = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    /// A group label's font: the theme's section label size and weight in
    /// its text face.
    private static var groupFont: NSFont {
        let style = Theme.current.sectionLabel
        let font = Theme.current.fonts.text
        return font.face.font(size: style.size * font.scale, weight: NSFont.Weight(style.weight).axisValue)
    }

    /// A group label's row: the label under the space that sets its group
    /// apart, over a little before its components.
    static var groupHeight: CGFloat {
        Metrics.PaletteList.sectionTopPadding + ceil(AppKitTypography.layoutLineHeight(of: groupFont)) + Metrics.PaletteList.sectionBottomPadding
    }

    func configure(_ row: AcknowledgementsList.Row) {
        switch row {
        case .group(let title):
            isGroup = true
            let style = Theme.current.sectionLabel
            label.attributedStringValue = NSAttributedString(
                string: style.isUppercase ? title.uppercased() : title,
                attributes: [
                    .font: Self.groupFont,
                    .foregroundColor: Palette.text2,
                    .kern: style.size * style.tracking,
                ]
            )
            setAccessibilityRole(.staticText)
        case .component(_, let name):
            isGroup = false
            label.stringValue = name
            label.font = AppKitTypography.row
            label.textColor = Palette.text
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = Metrics.AcknowledgementsList.textInset
        let height = ceil(label.intrinsicContentSize.height)
        let y = isGroup ? bounds.height - Metrics.PaletteList.sectionBottomPadding - height : ((bounds.height - height) / 2).rounded()
        label.frame = NSRect(x: inset, y: y, width: max(0, bounds.width - inset * 2), height: height)
    }
}
