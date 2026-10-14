// The Changes list: the changed files the filter shows, a conflicted file's
// state and buttons in its row while an operation or a stash restore waits
// on its conflicts; multiple selection; Space to include or exclude; ⌘C and
// ⌥⌘C to copy paths; ⌘⌫ to discard; Return or a double-click to open in the
// editor; type-select; and the context menu. `ChangesModel` holds the
// files, the selection, and the filter. The stash's files show in the same
// table, without checkboxes.
//
// The files are an AppKit table with fixed row heights: a SwiftUI `List`
// measures every row when a status replaces them (hundreds of milliseconds
// for 5,000 files), while the table configures only the rows on screen, so
// a status applies within budget (a frame for 5,000 files, 50 ms for
// 50,000).

import AppKit
import EspalierCore
import EspalierSupport
import GitKit
import SwiftUI

/// The changed files.
struct FileList: View {
    let repository: RepositoryModel
    @Environment(WindowContext.self) private var context

    var body: some View {
        let changes = repository.changes
        let files = FileList.listedFiles(repository)
        let controller = ChangesController(context: context, repository: repository)
        FileTable(
            files: .changes(files),
            selectedIDs: controller.selectedIDs,
            inclusion: changes.inclusionState(of:),
            isInclusionLocked: controller.isCommitting || controller.isRebaseConflicts,
            lineCounts: changes.lineCounts,
            conflicts: FileList.conflictRows(repository),
            conflictActions: { row in controller.conflictActions(for: row) },
            scope: FileTableScope(repository: ObjectIdentifier(repository), filter: changes.filter),
            actions: FileTableActions(
                select: { ids in changes.select(fileIDs: ids) },
                setIncluded: { ids, include in changes.setIncluded(ids, include) },
                toggle: { ids in controller.toggleInclusion(of: ids) },
                open: { ids in controller.openInEditor(Set(ids)) },
                menuItems: { ids in controller.menuItems(for: Set(ids)) },
                run: { command, ids in controller.run(command, on: Set(ids)) },
                copy: { ids in controller.copy(controller.relativePaths(controller.files(ids))) },
                focusChanged: { table in publishFocusedSelection(controller, table: table) }
            )
        )
        .overlay {
            // While the filter hides every file; without changes, the
            // right side says so.
            if files.isEmpty, !changes.workingDirectory.files.isEmpty, let message = NoMatchingFiles.message(for: changes.filter) {
                NoMatchingFiles(message: message) {
                    controller.clearFilters()
                }
            }
        }
        .onDisappear {
            context.state.setFocusedSelection(nil, owner: FileList.focusOwner)
        }
        .onChange(of: repository.gitState.generation) {
            // ChangesApply: a status pass applied → the list laid out.
            let interval = UISignposts.begin(.changesApply)
            DispatchQueue.main.async {
                UISignposts.end(.changesApply, interval)
            }
        }
    }

    /// Publishes the selection for Edit ▸ Delete (Discard) and Copy Path
    /// while `table` has focus (nil: it lost it); the closures read the
    /// selection when they run, and act only while the table is the key
    /// window's first responder.
    private func publishFocusedSelection(_ controller: ChangesController, table: ChangesTableView?) {
        let owner = FileList.focusOwner
        guard let table else {
            context.state.setFocusedSelection(nil, owner: owner)
            return
        }
        context.state.setFocusedSelection(
            FocusedSelection(
                owner: owner,
                deleteTitle: controller.discardTitle(count: max(controller.selectedIDs.count, 1)),
                delete: { controller.discard(controller.selectedFiles) },
                copyPath: { controller.copy(controller.absolutePaths(controller.selectedFiles)) },
                hasFocus: { [weak table] in table?.hasKeyboardFocus ?? false }
            ),
            owner: owner
        )
    }

    static let focusOwner = "changes"

    /// The conflicted files' states and buttons, by path: while an
    /// operation waits on conflicts, or a stash restore left some; empty
    /// otherwise.
    static func conflictRows(_ repository: RepositoryModel) -> [ExactString: ConflictFileRowContent] {
        guard repository.operations.conflictState != nil || repository.stash.conflictedRestore != nil,
              let content = ConflictsSectionContent.make(repository)
        else {
            return [:]
        }
        var rows: [ExactString: ConflictFileRowContent] = [:]
        for row in content.rows {
            rows[ExactString(row.path)] = row
        }
        return rows
    }

    /// The files the table lists: the filter's, conflicted ones included.
    static func listedFiles(_ repository: RepositoryModel) -> [WorkingDirectoryFileChange] {
        repository.changes.visibleFiles
    }
}

/// What the table's rows and keys do.
struct FileTableActions {
    /// The selection changed (IDs in the table's order).
    var select: ([String]) -> Void = { _ in }
    /// A row's checkbox.
    var setIncluded: ([String], Bool) -> Void = { _, _ in }
    /// Space.
    var toggle: ([String]) -> Void = { _ in }
    /// Return or a double-click.
    var open: ([String]) -> Void = { _ in }
    /// The context menu's items for the files a click applies to.
    var menuItems: ([String]) -> [FileMenuItem] = { _ in [] }
    /// Runs a context menu item.
    var run: (FileMenuCommand, [String]) -> Void = { _, _ in }
    /// ⌘C.
    var copy: ([String]) -> Void = { _ in }
    /// The table became first responder, or stopped being it (nil).
    var focusChanged: (ChangesTableView?) -> Void = { _ in }
}

/// What the table's rows are a list of. When it changes (another
/// repository, the filter, another stash) the rows change at once; within
/// it, a status's departing and arriving rows animate
/// (`FileTableCoordinator.RowChange`).
struct FileTableScope: Equatable {
    var repository: ObjectIdentifier?
    var filter: FileListFilter?
    /// What else the files belong to (the stash shown).
    var source: String?
}

/// The files a file table lists.
enum FileTableFiles {
    /// The working directory's changed files, each with its checkbox.
    case changes([WorkingDirectoryFileChange])
    /// Files that can only be looked at (a stash's): no checkboxes.
    case readOnly([CommittedFileChange])

    var count: Int {
        switch self {
        case .changes(let files): files.count
        case .readOnly(let files): files.count
        }
    }

    var isEmpty: Bool {
        count == 0
    }

    /// The ID of the file in `row`.
    func id(at row: Int) -> String {
        switch self {
        case .changes(let files): files[row].id
        case .readOnly(let files): files[row].id
        }
    }

    /// The path of the file in `row`.
    func path(at row: Int) -> String {
        switch self {
        case .changes(let files): files[row].path
        case .readOnly(let files): files[row].path
        }
    }

    /// Every file's ID, in order.
    var exactIDs: [ExactString] {
        switch self {
        case .changes(let files): files.map { ExactString($0.id) }
        case .readOnly(let files): files.map { ExactString($0.id) }
        }
    }

    /// The rows of the files with `ids`.
    func rows(of ids: Set<ExactString>) -> IndexSet {
        var rows = IndexSet()
        switch self {
        case .changes(let files):
            for (index, file) in files.enumerated() where ids.contains(ExactString(file.id)) {
                rows.insert(index)
            }
        case .readOnly(let files):
            for (index, file) in files.enumerated() where ids.contains(ExactString(file.id)) {
                rows.insert(index)
            }
        }
        return rows
    }
}

/// The changed files (or a stash's) in an AppKit table with fixed rows.
struct FileTable: NSViewRepresentable {
    var files: FileTableFiles
    /// The selected files' IDs.
    var selectedIDs: [String]
    /// A changed file's checkbox, as the changes model decides it.
    var inclusion: (WorkingDirectoryFileChange) -> FileInclusionState = { _ in FileInclusionState(value: nil, isEnabled: false, help: nil) }
    /// Whether checkboxes can't change now (a commit runs, a rebase waits on
    /// conflicts); a change reconfigures the rows.
    var isInclusionLocked = false
    /// The files' lines added and removed, by file ID, as loaded
    /// (`ChangesModel.lineCounts`); new counts reconfigure the rows.
    var lineCounts: [ExactString: FileLineCount] = [:]
    /// The conflicted files' states, by path (`FileList.conflictRows`).
    var conflicts: [ExactString: ConflictFileRowContent] = [:]
    /// What a conflicted file's buttons do.
    var conflictActions: (ConflictFileRowContent) -> ConflictFileRowActions = { _ in ConflictFileRowActions(isEditorAvailable: false) }
    var allowsMultipleSelection = true
    /// What VoiceOver calls the table.
    var tableLabel = "Changed files"
    var scope = FileTableScope()
    var actions = FileTableActions()

    func makeCoordinator() -> FileTableCoordinator {
        FileTableCoordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator, table: self)
    }

    /// The scroll view and table for `coordinator`, showing `table`.
    static func makeScrollView(coordinator: FileTableCoordinator, table: FileTable) -> NSScrollView {
        let tableView = ChangesTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // Rows inset and round their own selection (`FileTableRowView`).
        tableView.style = .plain
        tableView.focusRingType = .none
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.rowHeight = Metrics.FileList.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = table.allowsMultipleSelection
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = true
        tableView.backgroundColor = Palette.background
        tableView.setAccessibilityLabel(table.tableLabel)
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.coordinator = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(FileTableCoordinator.doubleClicked(_:))
        coordinator.tableView = tableView

        let scrollView = UnbouncedScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.background
        // A little room above the first row.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Metrics.grid, left: 0, bottom: Metrics.grid, right: 0)
        coordinator.update(table)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
}

/// The table's data source, delegate, and context menu.
final class FileTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var parent: FileTable
    weak var tableView: ChangesTableView?
    /// Whether the table's selection is being set from the model.
    private var isApplyingSelection = false
    /// The files the table's rows show, by ID, in order; nil for a list
    /// too long to animate.
    private(set) var shownIDs: [ExactString]?

    init(_ parent: FileTable) {
        self.parent = parent
    }

    var files: FileTableFiles {
        parent.files
    }

    /// Shows `table`'s files and selection: departing rows fade out as the
    /// rows below close the gap and arriving rows fade in, over 0.22 s,
    /// when that's a few rows of a list of at most 1,000; otherwise updates
    /// the row count at once. Then refills the rows the table has made in
    /// place (`reloadData` would make them all again), and selects the
    /// model's files where they are now.
    func update(_ table: FileTable) {
        let previousScope = parent.scope
        parent = table
        guard let tableView else {
            return
        }
        if tableView.allowsMultipleSelection != table.allowsMultipleSelection {
            tableView.allowsMultipleSelection = table.allowsMultipleSelection
        }
        if tableView.accessibilityLabel() != table.tableLabel {
            tableView.setAccessibilityLabel(table.tableLabel)
        }
        // Only a list short enough to animate keeps its IDs (a long one
        // costs nothing more to update).
        let ids = files.count <= Self.animatedFileLimit ? files.exactIDs : nil
        if previousScope == table.scope, let ids, let shownIDs, tableView.numberOfRows == shownIDs.count,
           Motion.animates(tableView), let change = Self.rowChange(from: shownIDs, to: ids) {
            applyAnimated(change, to: tableView)
        } else if tableView.numberOfRows != files.count {
            // Fewer rows drop selected rows past the end, which the table
            // reports as a selection change; the model's selection is
            // applied below instead.
            isApplyingSelection = true
            tableView.noteNumberOfRowsChanged()
            isApplyingSelection = false
        }
        shownIDs = ids
        tableView.enumerateAvailableRowViews { rowView, row in
            if let cell = rowView.view(atColumn: 0) as? FileRowView {
                configure(cell, row: row)
            }
        }
        applySelection(to: tableView)
        tableView.refreshHover()
    }

    // MARK: Rows arriving and departing

    /// The most files either list may have for a status to animate.
    static let animatedFileLimit = 1_000
    /// The most rows that may arrive and depart together for it to animate.
    static let animatedChangeLimit = 50

    /// The rows a status took away (by their old indexes) and brought (by
    /// their new ones); the rows that stay keep their order.
    struct RowChange: Equatable {
        var removed: IndexSet
        var inserted: IndexSet
    }

    /// How `old` became `new`, when it's only rows departing and arriving
    /// (none moving), at most 50 of them, in lists of at most 1,000 that
    /// aren't empty (committing everything shows the empty state without
    /// motion). Nil otherwise: the rows change at once.
    static func rowChange(from old: [ExactString], to new: [ExactString]) -> RowChange? {
        guard !old.isEmpty, !new.isEmpty, old.count <= animatedFileLimit, new.count <= animatedFileLimit, old != new else {
            return nil
        }
        let oldSet = Set(old)
        let newSet = Set(new)
        guard oldSet.count == old.count, newSet.count == new.count else {
            return nil
        }
        var removed = IndexSet()
        for (index, id) in old.enumerated() where !newSet.contains(id) {
            removed.insert(index)
        }
        var inserted = IndexSet()
        for (index, id) in new.enumerated() where !oldSet.contains(id) {
            inserted.insert(index)
        }
        guard removed.count + inserted.count <= animatedChangeLimit else {
            return nil
        }
        let keptOld = old.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        let keptNew = new.enumerated().filter { !inserted.contains($0.offset) }.map(\.element)
        guard keptOld == keptNew else {
            return nil
        }
        return RowChange(removed: removed, inserted: inserted)
    }

    /// Departing rows fade out while the rows below close the gap, and
    /// arriving rows fade in, in one 0.22 s group (AppKit's table runs a
    /// removal's fade and the gap's closing together). A departing row's
    /// cell stops answering first: a click on it does nothing.
    private func applyAnimated(_ change: RowChange, to tableView: NSTableView) {
        for row in change.removed {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileRowView)?.depart()
        }
        isApplyingSelection = true
        Motion.run(Motion.arrive, in: tableView) { animates in
            tableView.beginUpdates()
            if !change.removed.isEmpty {
                tableView.removeRows(at: change.removed, withAnimation: animates ? .effectFade : [])
            }
            if !change.inserted.isEmpty {
                tableView.insertRows(at: change.inserted, withAnimation: animates ? .effectFade : [])
            }
            tableView.endUpdates()
        }
        isApplyingSelection = false
    }

    /// Fills `cell` with the file in `row`.
    private func configure(_ cell: FileRowView, row: Int) {
        guard row < files.count else {
            return
        }
        cell.isDeparting = false
        switch files {
        case .changes(let changes):
            let file = changes[row]
            let conflict = parent.conflicts.isEmpty ? nil : parent.conflicts[ExactString(file.path)]
            cell.configure(
                FileRowContent(file, inclusion: parent.inclusion(file), lineCount: parent.lineCounts[ExactString(file.id)], conflict: conflict),
                repository: parent.scope.repository,
                conflictActions: conflict.map(parent.conflictActions)
            )
            let id = file.id
            cell.onIncludeChanged = { [weak self] include in
                self?.parent.actions.setIncluded([id], include)
            }
        case .readOnly(let committed):
            cell.configure(FileRowContent(readOnly: committed[row]), repository: parent.scope.repository)
            cell.onIncludeChanged = nil
        }
    }

    private func applySelection(to tableView: NSTableView) {
        let wanted = Set(parent.selectedIDs.map(ExactString.init))
        // The rows still selected hold the wanted files: nothing to do.
        let current = tableView.selectedRowIndexes
        let count = files.count
        if current.count == wanted.count, current.allSatisfy({ $0 < count && wanted.contains(ExactString(files.id(at: $0))) }) {
            return
        }
        let rows = wanted.isEmpty ? IndexSet() : files.rows(of: wanted)
        isApplyingSelection = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isApplyingSelection = false
        if let first = rows.first, rows.count == 1 {
            tableView.scrollRowToVisible(first)
        }
    }

    /// The IDs of the rows the user's action applies to: the selection when
    /// the clicked row is in it, else the clicked row.
    func ids(forClickedRow row: Int) -> [String] {
        guard let tableView, row >= 0, row < files.count else {
            return []
        }
        if tableView.selectedRowIndexes.contains(row) {
            return selectedIDs
        }
        return [files.id(at: row)]
    }

    var selectedIDs: [String] {
        guard let tableView else {
            return []
        }
        let count = files.count
        return tableView.selectedRowIndexes.compactMap { $0 < count ? files.id(at: $0) : nil }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        files.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < files.count else {
            return nil
        }
        let cell = tableView.makeView(withIdentifier: FileRowView.identifier, owner: nil) as? FileRowView ?? FileRowView()
        configure(cell, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = tableView.makeView(withIdentifier: FileTableRowView.identifier, owner: nil) as? FileTableRowView ?? FileTableRowView()
        rowView.isContextMenuTarget = self.tableView?.contextMenuTarget.isTarget(row) ?? false
        return rowView
    }

    /// A row scrolling in under the pointer shows its hover at once.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        let isHovered = row == self.tableView?.hoveredRow && !tableView.isRowSelected(row)
        (rowView as? FileTableRowView)?.setHovered(isHovered, animated: false)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // A selected row draws no hover.
        tableView?.refreshHover()
        guard !isApplyingSelection else {
            return
        }
        parent.actions.select(selectedIDs)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        row < files.count ? POSIXPath.basename(files.path(at: row)) : nil
    }

    @objc func doubleClicked(_ sender: NSTableView) {
        let ids = ids(forClickedRow: sender.clickedRow)
        if !ids.isEmpty {
            parent.actions.open(ids)
        }
    }

    // MARK: The context menu

    /// The menu for a click on `row`: for the selection when the row is in
    /// it, else for the row's file alone.
    func menuContent(forClickedRow row: Int) -> MenuContent? {
        let ids = ids(forClickedRow: row)
        guard !ids.isEmpty else {
            return nil
        }
        let run = parent.actions.run
        return FileMenuItem.menuContent(parent.actions.menuItems(ids)) { command in
            run(command, ids)
        }
    }
}

/// A row of the Changes table. A selected row is the accent's soft wash
/// in a rectangle inset 6 from the column's edges with radius 9, never
/// solid blue, so its text keeps its colors; selected neighbors join into
/// one shape. Overriding `drawBackground(in:)` makes AppKit draw the row,
/// selection included, through `draw(_:)`. The row draws no background of
/// its own: the table's shows through. Its hover is a wash of its own, in the selection's shape,
/// that fades in and out where the pointer is. While its context menu is
/// open it shows the accent ring in that shape.
final class FileTableRowView: NSTableRowView, ContextMenuTargetRowView {
    static let identifier = NSUserInterfaceItemIdentifier("Espalier.FileTableRow")

    /// Whether the row's context menu is open: it shows the ring.
    var isContextMenuTarget = false {
        didSet {
            if isContextMenuTarget != oldValue {
                needsDisplay = true
            }
        }
    }

    /// The hover wash, under the cells: in over 0.08 s, out over 0.15 s.
    fileprivate let hoverLayer: CALayer = {
        let layer = CALayer()
        layer.cornerRadius = Metrics.Radius.row
        layer.opacity = 0
        return layer
    }()

    /// Whether the row shows its hover.
    private(set) var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        Palette.accentSoft.setFill()
        selectionPath(in: bounds.insetBy(dx: FileRowMetrics.inset, dy: 0)).fill()
        SelectionBarDrawing.draw(in: bounds.insetBy(dx: FileRowMetrics.inset, dy: 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isContextMenuTarget {
            ContextTargetRingDrawing.stroke(in: bounds.insetBy(dx: FileRowMetrics.inset, dy: 0), radius: Metrics.Radius.row)
        }
    }

    /// The selection's shape: rounded, square where a selected neighbor
    /// continues it.
    private func selectionPath(in rect: CGRect) -> NSBezierPath {
        let radius = Metrics.Radius.row
        let top = isPreviousRowSelected ? 0 : radius
        let bottom = isNextRowSelected ? 0 : radius
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.appendArc(from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY + top), radius: top)
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.appendArc(from: CGPoint(x: rect.maxX, y: rect.maxY), to: CGPoint(x: rect.maxX - bottom, y: rect.maxY), radius: bottom)
        path.line(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.appendArc(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.maxY - bottom), radius: bottom)
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.appendArc(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.minX + top, y: rect.minY), radius: top)
        path.close()
        return path
    }

    /// The cells keep their colors on the soft selection.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }

    override var isPreviousRowSelected: Bool {
        didSet {
            needsDisplay = true
        }
    }

    override var isNextRowSelected: Bool {
        didSet {
            needsDisplay = true
        }
    }

    // MARK: Hover

    /// Shows or hides the hover: fading, or at once when `animated` is
    /// false (rows scrolling under the pointer, a row reused).
    func setHovered(_ hovered: Bool, animated: Bool) {
        guard hovered != isHovered else {
            return
        }
        isHovered = hovered
        installHoverLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(!(animated && Motion.animates(self)))
        CATransaction.setAnimationDuration(hovered ? Motion.hoverIn : Motion.hoverOut)
        CATransaction.setAnimationTimingFunction(Motion.timingFunction)
        hoverLayer.opacity = hovered ? 1 : 0
        CATransaction.commit()
    }

    /// Puts the hover under the row's cells the first time it shows.
    private func installHoverLayer() {
        guard let layer, hoverLayer.superlayer !== layer else {
            return
        }
        layer.insertSublayer(hoverLayer, at: 0)
        updateHoverColor()
        layoutHoverLayer()
    }

    private func layoutHoverLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = bounds.insetBy(dx: FileRowMetrics.inset, dy: 0)
        CATransaction.commit()
    }

    fileprivate func updateHoverColor() {
        var color = Palette.hover.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = Palette.hover.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.backgroundColor = color
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        if hoverLayer.superlayer != nil {
            layoutHoverLayer()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverColor()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHovered(false, animated: false)
    }
}

/// The table: Space includes or excludes, Return opens, ⌘C copies paths,
/// the context menu, and focus is published for Edit ▸ Delete.
final class ChangesTableView: NSTableView, ContextMenuContentProviding {
    weak var coordinator: FileTableCoordinator?
    /// The row whose context menu is open.
    lazy var contextMenuTarget = TableContextMenuTarget(table: self)

    // MARK: The context menu

    func contextMenuContent(at point: CGPoint) -> MenuContent? {
        coordinator?.menuContent(forClickedRow: row(at: point))
    }

    func markContextMenuTarget(at point: CGPoint) -> (() -> Void)? {
        contextMenuTarget.mark(row(at: point))
    }

    // MARK: Hover

    private var hoverArea: NSTrackingArea?

    /// The row under the pointer, or -1. Its row view shows its hover,
    /// unless it's selected.
    private(set) var hoveredRow = -1

    /// Hovers `row` (-1: none): the row it leaves fades its hover out and
    /// the row it enters fades its in, or at once when `animated` is false
    /// (rows scrolling under the pointer).
    private func setHoveredRow(_ row: Int, animated: Bool) {
        guard row != hoveredRow else {
            return
        }
        hoveredRow = row
        updateHoveredRows(animated: animated)
    }

    /// Shows the hover on the hovered row's view alone, unless it's
    /// selected.
    private func updateHoveredRows(animated: Bool) {
        enumerateAvailableRowViews { rowView, row in
            (rowView as? FileTableRowView)?.setHovered(row == hoveredRow && !isRowSelected(row), animated: animated)
        }
    }

    /// Finds the row under the pointer again and shows its hover at once:
    /// rows arrived, departed, or were selected.
    func refreshHover() {
        guard hoveredRow >= 0 else {
            return
        }
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hoveredRow = visibleRect.contains(point) ? row(at: point) : -1
        }
        updateHoveredRows(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil), animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(-1, animated: true)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        // The rows move under a pointer that doesn't: the hover moves with
        // them at once.
        if let window {
            updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), animated: false)
        }
    }

    private func updateHover(at point: CGPoint, animated: Bool) {
        setHoveredRow(visibleRect.contains(point) ? row(at: point) : -1, animated: animated)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        if modifiers.isEmpty, let coordinator {
            switch event.keyCode {
            case 49: // Space
                coordinator.parent.actions.toggle(coordinator.selectedIDs)
                return
            case 36, 76: // Return, Enter
                if !coordinator.selectedIDs.isEmpty {
                    coordinator.parent.actions.open(coordinator.selectedIDs)
                    return
                }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard let coordinator, !coordinator.selectedIDs.isEmpty else {
            NSSound.beep()
            return
        }
        coordinator.parent.actions.copy(coordinator.selectedIDs)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return !(coordinator?.selectedIDs.isEmpty ?? true)
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Whether the keys come here: the table is the key window's first
    /// responder.
    var hasKeyboardFocus: Bool {
        guard let window else {
            return false
        }
        return window.isKeyWindow && window.firstResponder === self
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            coordinator?.parent.actions.focusChanged(self)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            coordinator?.parent.actions.focusChanged(nil)
        }
        return resigned
    }
}


/// The list when the filter matches no file.
struct NoMatchingFiles: View {
    let message: String
    let onClear: () -> Void

    var body: some View {
        CenteredMessage("No Matching Files", systemImage: "line.3.horizontal.decrease", description: message) {
            Button("Clear Filters", action: onClear)
                .buttonStyle(.quiet)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the filter matched nothing for, or nil without a filter.
    static func message(for filter: FileListFilter) -> String? {
        guard filter.hasActiveFilters else {
            return nil
        }
        let hasText = !filter.text.isEmpty
        switch (hasText, filter.activeOptionCount > 0) {
        case (true, true): return "No changed files match “\(filter.text)” and the filter options."
        case (true, false): return "No changed files match “\(filter.text)”."
        default: return "No changed files match the filter options."
        }
    }
}

/// "2 hidden files will be committed.", with Show: the filter hides files
/// the commit includes.
struct HiddenChangesNote: View {
    let count: Int
    let numberFormat: NumberFormat
    let onShow: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.insetSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(espalier: Palette.warning))
                .accessibilityLabel("Warning")
            // The note takes the room the button leaves before it wraps.
            Text(text)
                .font(Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Show", action: onShow)
                .buttonStyle(.quiet)
                .controlSize(.small)
                .tooltip("Show the files the commit includes")
        }
        .padding(.horizontal, FileRowMetrics.contentInset)
        .padding(.vertical, Metrics.insetSmall)
        .accessibilityElement(children: .contain)
    }

    var text: String {
        count == 1 ? "1 hidden file will be committed." : "\(formatNumber(Double(count), numberFormat)) hidden files will be committed."
    }
}

// MARK: - Acting on changed files

/// The Changes list's intents, through the window: include and exclude,
/// discard, ignore, copy paths, open, and a conflicted file's side.
@MainActor
struct ChangesController {
    let context: WindowContext
    let repository: RepositoryModel

    var changes: ChangesModel {
        repository.changes
    }

    /// The selected files' IDs, in the list's order.
    var selectedIDs: [String] {
        if case .workingDirectory(let ids) = changes.selection {
            return ids
        }
        return []
    }

    /// The selected files.
    var selectedFiles: [WorkingDirectoryFileChange] {
        files(selectedIDs)
    }

    /// The files with `ids`, in the list's order.
    func files(_ ids: some Collection<String>) -> [WorkingDirectoryFileChange] {
        let wanted = Set(ids.map(ExactString.init))
        return changes.workingDirectory.files.filter { wanted.contains(ExactString($0.id)) }
    }

    /// Whether a rebase waits on conflicts.
    var isRebaseConflicts: Bool {
        if case .rebase? = repository.operations.conflictState { true } else { false }
    }

    var isCommitting: Bool {
        repository.localOperation?.kind == .commit
    }

    // MARK: Including

    /// Space: each file is included unless it's included in full, then
    /// excluded. Not while committing or in a rebase's conflicts.
    func toggleInclusion(of ids: [String]) {
        guard !isCommitting, !isRebaseConflicts else {
            return
        }
        let files = files(ids)
        let include = files.filter { $0.selection.getSelectionType() == .none }.map(\.id)
        let exclude = files.filter { $0.selection.getSelectionType() != .none }.map(\.id)
        if !include.isEmpty {
            changes.setIncluded(include, true)
        }
        if !exclude.isEmpty {
            changes.setIncluded(exclude, false)
        }
    }

    // MARK: The context menu

    /// The items for the files a click applies to; for one conflicted
    /// file, its sides to pick (or Undo) after them.
    func menuItems(for ids: Set<String>) -> [FileMenuItem] {
        guard !isCommitting else {
            return []
        }
        let files = files(ids)
        var items = FileContextMenuContent.items(
            for: files,
            ignoreItems: repository.gitIgnoreMenuItems(for: files.map(\.path)),
            editorTitle: context.app.integrations.editorLabel.map { "Open in \($0)" },
            asksBeforeDiscarding: context.app.preferences.confirmDiscardChanges,
            isRebaseConflicts: isRebaseConflicts
        )
        if files.count == 1, let file = files.first, let conflict = FileList.conflictRows(repository)[ExactString(file.path)] {
            items += FileContextMenuContent.conflictItems(for: conflict)
        }
        return items
    }

    func run(_ command: FileMenuCommand, on ids: Set<String>) {
        let files = files(ids)
        guard let first = files.first else {
            return
        }
        switch command {
        case .discard:
            discard(isRebaseConflicts ? [first] : files)
        case .ignore(let action):
            Task {
                await context.presenter.perform { _ throws(OperationError) in
                    try await repository.ignore(action)
                }
            }
        case .include:
            changes.setIncluded(files.map(\.id), true)
        case .exclude:
            changes.setIncluded(files.map(\.id), false)
        case .copyPaths:
            copy(absolutePaths(isRebaseConflicts ? [first] : files))
        case .copyRelativePaths:
            copy(relativePaths(isRebaseConflicts ? [first] : files))
        case .showInFinder:
            context.actions.perform(.showInFinder(path: absolutePath(first)))
        case .openInEditor:
            context.actions.perform(.openInEditor(path: absolutePath(first)))
        case .openWithDefaultProgram:
            context.actions.perform(.openWithDefaultProgram(path: absolutePath(first)))
        case .resolve(let resolution):
            repository.operations.setManualResolution(resolution, forPath: first.path)
        }
    }

    /// Return or a double-click: the first file in the editor, unless it's
    /// deleted.
    func openInEditor(_ ids: Set<String>) {
        guard let file = files(ids).first, file.status.kind != .deleted else {
            return
        }
        context.actions.perform(.openInEditor(path: absolutePath(file)))
    }

    // MARK: Conflicts

    /// What a conflicted file's buttons do: open it, show it, pick a side.
    func conflictActions(for row: ConflictFileRowContent) -> ConflictFileRowActions {
        let integrations = context.app.integrations
        let path = POSIXPath.join(repository.record.path, row.path)
        let actions = context.actions
        let operations = repository.operations
        return ConflictFileRowActions(
            editorName: integrations.editorLabel,
            isEditorAvailable: integrations.isEditorAvailable,
            openInEditor: { actions.perform(.openInEditor(path: path)) },
            openWithDefaultProgram: { actions.perform(.openWithDefaultProgram(path: path)) },
            showInFinder: { actions.perform(.showInFinder(path: path)) },
            choose: { resolution in operations.setManualResolution(resolution, forPath: row.path) }
        )
    }

    // MARK: Discarding

    /// Discards the files' changes through the presenter (which asks).
    func discard(_ files: [WorkingDirectoryFileChange]) {
        guard !files.isEmpty else {
            return
        }
        Task {
            await context.presenter.perform { answers throws(OperationError) in
                try await repository.changes.discard(files, confirmed: answers.confirmed)
            }
        }
    }

    /// Edit ▸ Delete's title for the selection.
    func discardTitle(count: Int) -> String {
        FileContextMenuContent.discardItem(count: count, asksFirst: context.app.preferences.confirmDiscardChanges || count > 1).title
    }

    // MARK: Paths

    func absolutePath(_ file: WorkingDirectoryFileChange) -> String {
        POSIXPath.join(repository.record.path, file.path)
    }

    /// The files' absolute paths, one per line (Copy File Path).
    func absolutePaths(_ files: [WorkingDirectoryFileChange]) -> String {
        files.map(absolutePath).joined(separator: "\n")
    }

    /// The files' paths in the repository, one per line (Copy Relative File
    /// Path).
    func relativePaths(_ files: [WorkingDirectoryFileChange]) -> String {
        files.map { POSIXPath.normalize($0.path) }.joined(separator: "\n")
    }

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: The filter

    /// Clears the filter: the toolbar's text and every option.
    func clearFilters() {
        context.state.searchText = ""
        changes.filter = FileListFilter()
    }

    /// Shows only the files the commit includes.
    func showIncludedFiles() {
        context.state.searchText = ""
        changes.filter = FileListFilter(includedInCommit: true)
    }
}

extension ChangesTableView: LookChangeObserving {
    /// The rows' height and the background follow the look.
    func lookDidChange() {
        rowHeight = Metrics.FileList.rowHeight
        backgroundColor = Palette.background
        enclosingScrollView?.backgroundColor = Palette.background
    }
}

extension FileTableRowView: LookChangeObserving {
    /// The hover wash takes the look's shape and color.
    func lookDidChange() {
        hoverLayer.cornerRadius = Metrics.Radius.row
        updateHoverColor()
    }
}
