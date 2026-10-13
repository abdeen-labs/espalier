// A commit's (or the working copy's) changed files in History's details: a
// column of rows beside the diff, as desktop's commit view has, each with the
// status badge, the name, its folder, and the lines added and removed. The
// list is an `NSTableView`, so it works as any Mac list does: the arrow keys,
// Home and End, Page Up and Page Down, and typing a name; Return or a double
// click opens the file, and the files' context menu shows on a secondary
// click, or on the selected file with ⇧F10 (`KeyboardContextMenu`).

import AppKit
import EspalierSupport
import GitKit
import SwiftUI

/// A changed file, as its row shows it.
nonisolated struct HistoryFileContent: Sendable, Equatable, Identifiable {
    var file: CommittedFileRowContent
    /// Lines added and deleted; nil when unknown or binary.
    var added: Int?
    var deleted: Int?

    var id: String {
        file.id
    }

    /// What VoiceOver reads: "Loader.swift, Modified, in Sources/App, 10
    /// added lines, 2 removed lines".
    var accessibilityLabel: String {
        var parts = [file.fileName, file.status.title]
        if let oldPath = file.oldPath {
            parts.append("from \(oldPath)")
        } else if !file.directory.isEmpty {
            parts.append("in \(file.directory)")
        }
        if let added, added > 0 {
            parts.append(added == 1 ? "1 added line" : "\(formatCount(added)) added lines")
        }
        if let deleted, deleted > 0 {
            parts.append(deleted == 1 ? "1 removed line" : "\(formatCount(deleted)) removed lines")
        }
        return parts.joined(separator: ", ")
    }
}

extension HistoryFileContent {
    /// A commit's file, with its counts from the changeset.
    init(_ file: CommittedFileChange, in changeset: ChangesetData) {
        let counts = changeset.lineCounts[file.id]
        self.init(file: CommittedFileRowContent(file), added: counts?.added, deleted: counts?.deleted)
    }
}

/// What the file list's controls do.
struct HistoryFilesActions {
    var select: (String?) -> Void = { _ in }
    /// Double click or Return; nil when files don't open.
    var open: ((String) -> Void)?
    /// A file's context menu; nil offers none.
    var menu: ((String) -> MenuContent?)?
}

/// The files beside the diff: the table in SwiftUI.
struct HistoryFileList: NSViewRepresentable {
    let files: [HistoryFileContent]
    let selection: String?
    var actions = HistoryFilesActions()
    /// Focuses the list when it changes (Return in the commit list).
    var focusRequest = 0

    func makeCoordinator() -> HistoryFileListController {
        HistoryFileListController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(files: files, selection: selection, actions: actions, focusRequest: focusRequest)
    }
}

/// The file list's table: its data source and delegate, and the selection
/// it keeps in step with the model's.
final class HistoryFileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let tableView = HistoryFileTableView(frame: .zero)
    let scrollView = NSScrollView(frame: .zero)
    private(set) var files: [HistoryFileContent] = []
    var actions = HistoryFilesActions()
    /// The file the model has selected.
    private var selection: String?
    /// Set while the table's selection is changed to match the model's.
    private var isApplyingSelection = false
    /// The last focus request seen; nil before the first update.
    private var focusRequest: Int?

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // Rows draw their own selection (`HistoryFileRowView`).
        tableView.style = .plain
        tableView.rowHeight = Metrics.FileList.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = Palette.background
        tableView.focusRingType = .none
        tableView.setAccessibilityLabel("Changed Files")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.controller = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        // No bouncing past the edges.
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.background
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Metrics.grid, left: 0, bottom: Metrics.grid, right: 0)
    }

    // MARK: Updating

    /// Shows `files` with `selection` selected, taking focus when
    /// `focusRequest` changed since the last update.
    func update(files: [HistoryFileContent], selection: String?, actions: HistoryFilesActions, focusRequest: Int) {
        self.actions = actions
        self.selection = selection
        if files != self.files {
            self.files = files
            isApplyingSelection = true
            tableView.reloadData()
            isApplyingSelection = false
        }
        syncSelection(scrolls: true)
        if let previous = self.focusRequest, previous != focusRequest {
            tableView.window?.makeFirstResponder(tableView)
        }
        self.focusRequest = focusRequest
    }

    /// Selects in the table the file the model has selected.
    private func syncSelection(scrolls: Bool) {
        let row = selection.flatMap { id in files.firstIndex { $0.id == id } }
        let rows = row.map { IndexSet(integer: $0) } ?? IndexSet()
        guard rows != tableView.selectedRowIndexes else {
            return
        }
        isApplyingSelection = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isApplyingSelection = false
        if scrolls, let row {
            tableView.scrollRowToVisible(row)
        }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        files.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard files.indices.contains(row) else {
            return nil
        }
        if let cell = tableView.makeView(withIdentifier: HistoryFileCellView.identifier, owner: self) as? HistoryFileCellView {
            cell.configure(files[row])
            return cell
        }
        return HistoryFileCellView(content: files[row])
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = tableView.makeView(withIdentifier: HistoryFileRowView.identifier, owner: self) as? HistoryFileRowView ?? HistoryFileRowView(frame: .zero)
        rowView.isContextMenuTarget = self.tableView.contextMenuTarget.isTarget(row)
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else {
            return
        }
        let row = tableView.selectedRow
        guard files.indices.contains(row) else {
            // A click below the files keeps the file shown.
            syncSelection(scrolls: false)
            return
        }
        selection = files[row].id
        actions.select(files[row].id)
    }

    /// Typing selects the first file whose name starts with what's typed.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        files.indices.contains(row) ? files[row].file.fileName : nil
    }

    // MARK: Opening and menus

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard files.indices.contains(row) else {
            return
        }
        actions.open?(files[row].id)
    }

    /// Return: opens the selected file. Returns whether there was one to
    /// open.
    func openSelection() -> Bool {
        let row = tableView.selectedRow
        guard files.indices.contains(row), let open = actions.open else {
            return false
        }
        open(files[row].id)
        return true
    }

    /// The context menu for the file in `row`.
    func menu(forRow row: Int) -> MenuContent? {
        guard files.indices.contains(row) else {
            return nil
        }
        return actions.menu?(files[row].id)
    }
}

/// The file list's `NSTableView`: Return opens the selected file, and a
/// secondary click (or ⇧F10) shows a file's menu.
final class HistoryFileTableView: NSTableView, ContextMenuContentProviding {
    weak var controller: HistoryFileListController?
    /// The row whose context menu is open.
    lazy var contextMenuTarget = TableContextMenuTarget(table: self)

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) }
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if modifiers.isEmpty, key == 0x0D || key == 0x03, controller?.openSelection() == true {
            return
        }
        super.keyDown(with: event)
    }

    func contextMenuContent(at point: CGPoint) -> MenuContent? {
        controller?.menu(forRow: row(at: point))
    }

    func markContextMenuTarget(at point: CGPoint) -> (() -> Void)? {
        contextMenuTarget.mark(row(at: point))
    }
}

/// A file's row as the table draws it: the selection in the row's rounded
/// shape, and the ring while its context menu is open
/// (`HistoryRowDrawing`).
final class HistoryFileRowView: NSTableRowView, ContextMenuTargetRowView {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryFileRowView")

    /// Whether the row's context menu is open: it shows the ring.
    var isContextMenuTarget = false {
        didSet {
            if isContextMenuTarget != oldValue {
                needsDisplay = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Palette.accentSoft.setFill()
        HistoryRowDrawing.selectionPath(in: bounds, isFlipped: isFlipped, joinsAbove: false, joinsBelow: false).fill()
        SelectionBarDrawing.draw(in: HistoryRowDrawing.selectionRect(in: bounds))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isContextMenuTarget {
            HistoryRowDrawing.drawContextTarget(in: bounds, isFlipped: isFlipped)
        }
    }

    /// Selected text keeps its colors on `accent soft`.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }
}

/// A file's cell: the SwiftUI row, hosted. The cell is what VoiceOver
/// reads, and its Show Menu shows the file's menu.
final class HistoryFileCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryFileCell")

    private let host: NSHostingView<AnyView>
    private(set) var content: HistoryFileContent

    init(content: HistoryFileContent) {
        self.content = content
        host = NSHostingView(rootView: Self.row(content))
        super.init(frame: .zero)
        identifier = Self.identifier
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `content`.
    func configure(_ content: HistoryFileContent) {
        guard content != self.content else {
            return
        }
        self.content = content
        host.rootView = Self.row(content)
    }

    private static func row(_ content: HistoryFileContent) -> AnyView {
        AnyView(HistoryFileRow(content: content).accessibilityHidden(true).lookFont())
    }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    override func accessibilityLabel() -> String? {
        content.accessibilityLabel
    }

    /// VoiceOver's Show Menu: the menu a secondary click on the file shows.
    override func accessibilityPerformShowMenu() -> Bool {
        KeyboardContextMenu.showMenu(of: self)
    }
}

/// A file's row: the status badge, the name, its folder (so two files of
/// one name tell apart), and its counts.
struct HistoryFileRow: View {
    let content: HistoryFileContent

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            StatusGlyph(content.file.status)
            Text(content.file.fileName)
                .font(Typography.row.weight(.medium))
                .foregroundStyle(.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !content.file.directory.isEmpty {
                Text(content.file.directory)
                    .font(Typography.secondary)
                    .foregroundStyle(.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Metrics.grid)
            HistoryLineCounts(added: content.added, deleted: content.deleted)
        }
        .padding(.horizontal, Metrics.CommitRow.selectionInset + Metrics.insetSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tooltip(content.file.tooltip)
    }
}

/// "+10 −2" in SF Mono, in the diff's colors; zero counts left out.
struct HistoryLineCounts: View {
    let added: Int?
    let deleted: Int?

    var body: some View {
        HStack(spacing: Metrics.grid) {
            if let added, added > 0 {
                Text("+\(formatCount(added))")
                    .foregroundStyle(Color(espalier: DiffColors.addedMarker))
            }
            if let deleted, deleted > 0 {
                Text("−\(formatCount(deleted))")
                    .foregroundStyle(Color(espalier: DiffColors.deletedMarker))
            }
        }
        .font(Typography.count)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added ?? 0) added lines, \(deleted ?? 0) removed lines")
    }
}

/// The label over the files: "CHANGED FILES 3", and the lines added and
/// removed, in a row as high as the list's header. The label is always
/// whole; the line counts show when there's room for them.
struct CommitFilesHeader: View {
    let summary: CommitFilesSummary

    var body: some View {
        HStack(spacing: Metrics.insetSmall) {
            SectionLabel("Changed Files", count: summary.fileCount)
                .fixedSize()
                .accessibilityLabel(summary.title)
            Spacer(minLength: Metrics.grid)
            if summary.linesAdded > 0 || summary.linesDeleted > 0 {
                // Shown whole or not at all: a narrow column leaves the
                // room to the label.
                ViewThatFits(in: .horizontal) {
                    HistoryLineCounts(added: summary.linesAdded, deleted: summary.linesDeleted)
                    Color.clear
                        .frame(width: 0, height: 0)
                }
            }
        }
        .padding(.horizontal, Metrics.HistoryHeader.horizontalPadding)
        .frame(height: Metrics.HistoryHeader.height)
    }
}

extension HistoryFileTableView: LookChangeObserving {
    /// The rows' height and the background follow the look.
    func lookDidChange() {
        rowHeight = Metrics.FileList.rowHeight
        backgroundColor = Palette.background
        enclosingScrollView?.backgroundColor = Palette.background
    }
}
