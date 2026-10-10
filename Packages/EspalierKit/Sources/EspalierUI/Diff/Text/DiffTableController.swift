// The controller of the diff table. It owns the AppKit table, builds the
// `DiffDocument` off the main actor whenever the diff or a setting that
// shapes rows changes, computes row heights with monospace arithmetic, and
// handles the mouse and keyboard. While a new document builds, the previous
// one stays on screen.

import AppKit
import EspalierCore
import EspalierSupport
import GitKit
import os
import SwiftUI

/// What the diff table shows.
struct DiffTableContent {
    /// The file the diff is of (`FileChange.id`); a new file scrolls to the
    /// top and clears the selection.
    var fileID: String
    /// The diff shown: the file's, expanded where the user expanded it.
    var diff: TextDiff
    var isSplit: Bool
    var wrapsLines: Bool
    var tabSize: Int
    var fontSize: CGFloat
    /// Tint conflict markers and the sides between them.
    var detectsConflictMarkers: Bool
    /// The file's contents are loaded and can expand the diff.
    var canExpand: Bool
    /// The diff has expanded lines ("Collapse Expanded Lines").
    var hasExpandedLines: Bool
    /// Staging lines (Changes only).
    var staging: StagingState?
    /// Syntax tokens, and a generation bumped when they change.
    var tokens: FileTokens
    var tokensGeneration: Int
    /// False while the next diff loads: input is ignored.
    var isInteractive: Bool

    init(
        fileID: String,
        diff: TextDiff,
        isSplit: Bool = false,
        wrapsLines: Bool = true,
        tabSize: Int = 4,
        fontSize: CGFloat = Metrics.Diff.codeFontSize,
        detectsConflictMarkers: Bool = false,
        canExpand: Bool = false,
        hasExpandedLines: Bool = false,
        staging: StagingState? = nil,
        tokens: FileTokens = .none,
        tokensGeneration: Int = 0,
        isInteractive: Bool = true
    ) {
        self.fileID = fileID
        self.diff = diff
        self.isSplit = isSplit
        self.wrapsLines = wrapsLines
        self.tabSize = tabSize
        self.fontSize = fontSize
        self.detectsConflictMarkers = detectsConflictMarkers
        self.canExpand = canExpand
        self.hasExpandedLines = hasExpandedLines
        self.staging = staging
        self.tokens = tokens
        self.tokensGeneration = tokensGeneration
        self.isInteractive = isInteractive
    }

    /// What the document is built from.
    var documentInput: DiffDocumentInput {
        DiffDocumentInput(
            hunks: diff.hunks,
            maxLineNumber: diff.maxLineNumber,
            isSplit: isSplit,
            canExpand: canExpand,
            tabSize: tabSize,
            detectsConflictMarkers: detectsConflictMarkers
        )
    }

    /// Whether `other` needs a new document.
    func needsNewDocument(comparedTo other: DiffTableContent) -> Bool {
        fileID != other.fileID || isSplit != other.isSplit || tabSize != other.tabSize
            || canExpand != other.canExpand || detectsConflictMarkers != other.detectsConflictMarkers
            || !textDiffEquals(diff, other.diff)
    }
}

/// What the table's gestures ask for.
struct DiffTableActions {
    /// Expands a hunk up or down.
    var expandHunk: @MainActor (Int, DiffExpansionKind) -> Void = { _, _ in }
    /// "Expand Whole File".
    var expandWholeFile: @MainActor () -> Void = {}
    /// "Collapse Expanded Lines".
    var collapseExpandedLines: @MainActor () -> Void = {}
    /// The first rows of a file's diff were drawn (the `DiffOpen` signpost).
    var didPaint: @MainActor (String) -> Void = { _ in }
    /// Staging lines, in Changes.
    var staging: StagingActions?
}


/// The diff table's controller: the table's data source and delegate.
@MainActor
final class DiffTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView: NSScrollView
    let tableView: DiffTableView
    var actions = DiffTableActions()
    /// Builds documents on the main actor (snapshots and tests).
    var buildsSynchronously = false

    private(set) var content: DiffTableContent?
    /// The content of the document shown (it lags `content` while a new
    /// document builds).
    private(set) var shownContent: DiffTableContent?
    private(set) var document = DiffDocument.empty
    private var buildTask: Task<Void, Never>?
    private var buildGeneration = 0

    // MARK: Layout

    private(set) var font = DiffFontMetrics(fontSize: Metrics.Diff.codeFontSize) {
        didSet {
            codeFont = AppKitTypography.code(size: font.fontSize)
        }
    }
    /// The code font at the current size.
    private(set) var codeFont = AppKitTypography.code(size: Metrics.Diff.codeFontSize)
    /// Text prepared for drawing.
    let textCache = DiffTextCache()
    /// Increase Contrast is on: markers go bold.
    private(set) var increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    private(set) var geometry: DiffRowGeometry
    private(set) var rowHeights: [CGFloat] = []
    /// The width rows are wrapped for (lags during live resize).
    private var layoutWidth: CGFloat = 0
    private var relayoutTask: Task<Void, Never>?
    private var lineLayouts: [LayoutKey: LineLayout] = [:]
    private var intraLineChanges: [Int: IntraLineChange] = [:]
    private var intraLineMisses = Set<Int>()

    private struct LayoutKey: Hashable {
        let line: Int
        let columnsPerLine: Int
    }

    // MARK: Interaction state

    /// The text selection.
    var textSelection: DiffTextSelection? {
        didSet {
            if textSelection != oldValue {
                redrawVisibleRows()
            }
        }
    }
    /// The keyboard's line cursor: the rows from `anchor` to `head`.
    private(set) var cursor: (anchor: Int, head: Int)?
    /// The block whose handle the pointer is over.
    private(set) var hoveredBlock: Int?
    /// The hunk header button the pointer is over.
    private(set) var hoveredButton: (hunk: Int, button: DiffHunkButton)?
    /// A drag down the gutter: the original diff's indexes from and to,
    /// and whether it includes or excludes them.
    private(set) var gutterDrag: (column: DiffColumn, from: Int, to: Int, include: Bool)?
    /// How far the text is scrolled sideways when lines don't wrap.
    private(set) var textScrollX: CGFloat = 0
    /// The longest line's width, for sideways scrolling.
    private var maximumTextWidth: CGFloat = 0

    /// Find, through the system find bar.
    private(set) lazy var findClient = DiffFindClient(controller: self)
    private(set) lazy var textFinder: NSTextFinder = {
        let finder = NSTextFinder()
        hasTextFinder = true
        finder.client = findClient
        finder.findBarContainer = scrollView
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = true
        return finder
    }()

    /// Whether `textFinder` was made (tearing down doesn't make it).
    private var hasTextFinder = false

    /// The popover offering to show whitespace changes, and where it was
    /// asked for.
    private var whitespaceHint: NSPopover?
    private(set) var whitespaceHintPoint: CGPoint?

    override init() {
        let tableView = DiffTableView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        self.tableView = tableView
        scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        geometry = DiffRowGeometry(
            width: 600, isSplit: false, showsStaging: false, digits: 3,
            font: DiffFontMetrics(fontSize: Metrics.Diff.codeFontSize)
        )
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.focusRingType = .none
        tableView.backgroundColor = Palette.background
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = font.lineHeight
        tableView.allowsTypeSelect = false
        tableView.controller = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Diff")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.background
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        tableView.sizeLastColumnToFit()
    }

    /// The view went away: stops work in flight.
    func tearDown() {
        buildTask?.cancel()
        relayoutTask?.cancel()
        whitespaceHint?.close()
        // The find bar outlives this controller (the scroll view keeps it)
        // but doesn't retain its client: after a search, removing the
        // scroll view would ask the freed client for its matches and crash.
        if hasTextFinder {
            textFinder.cancelFindIndicator()
            textFinder.findBarContainer = nil
            textFinder.client = nil
        }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: Updating

    /// Shows `content`: rebuilds the document when the diff or a setting
    /// that shapes rows changed, recomputes heights when the font or
    /// wrapping changed, and otherwise redraws the visible rows.
    func apply(_ content: DiffTableContent) {
        let previous = self.content
        self.content = content

        let fontChanged = font.fontSize != content.fontSize
        if fontChanged {
            font = DiffFontMetrics(fontSize: content.fontSize)
        }

        if previous == nil || content.needsNewDocument(comparedTo: previous!) {
            buildDocument(for: content)
            return
        }
        guard let shown = shownContent else {
            return
        }
        // The document is current: settings that don't shape rows.
        let stagingShapeChanged = (shown.staging != nil) != (content.staging != nil)
        // Lines included or left out: the rows on screen whose number
        // cells or hunk checkbox change crossfade over 0.12 s.
        let fadingRows = stagingShapeChanged || shown.staging == content.staging
            ? []
            : rowsChangingInclusion(from: shown.staging, to: content.staging)
        defer {
            crossfade(rows: fadingRows, duration: Motion.mark)
        }
        shownContent = content
        if fontChanged || stagingShapeChanged || shown.wrapsLines != content.wrapsLines {
            relayout(force: true)
        }
        if shown.tokensGeneration != content.tokensGeneration || fontChanged {
            textCache.reset()
        }
        if shown.tokensGeneration != content.tokensGeneration || shown.staging != content.staging
            || shown.hasExpandedLines != content.hasExpandedLines || fontChanged || stagingShapeChanged {
            redrawVisibleRows()
        }
        if shown.wrapsLines != content.wrapsLines {
            textScrollX = 0
        }
    }

    /// Waits for the document being built (tests).
    func documentIdle() async {
        await buildTask?.value
    }

    private func buildDocument(for content: DiffTableContent) {
        buildGeneration &+= 1
        let generation = buildGeneration
        let input = content.documentInput
        buildTask?.cancel()
        if buildsSynchronously {
            install(DiffDocument(input: input), for: content)
            return
        }
        buildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let document = DiffDocument(input: input)
            await MainActor.run { [weak self] in
                guard let self, self.buildGeneration == generation, let content = self.content else {
                    return
                }
                self.install(document, for: content)
            }
        }
    }

    /// Shows a new document. The same file's expanded lines slide down into
    /// place (0.22 s, up to 100 lines, when the table can insert them
    /// rather than reload); Unified ↔ Split crossfades over 0.15 s.
    private func install(_ document: DiffDocument, for content: DiffTableContent) {
        let isNewFile = shownContent?.fileID != content.fileID
        let keepsScroll = !isNewFile
        let scrollOrigin = scrollView.contentView.bounds.origin
        let animates = !isNewFile && Motion.animates(tableView)
        let switchesLayout = shownContent.map { $0.isSplit != content.isSplit } ?? false
        let canInsert = shownContent.map { $0.wrapsLines == content.wrapsLines && (($0.staging == nil) == (content.staging == nil)) } ?? false
        let expansion = animates && !switchesLayout && canInsert ? Self.expansion(from: self.document, to: document) : nil

        textFinder.noteClientStringWillChange()
        self.document = document
        shownContent = content
        findClient.invalidate()
        textCache.reset()
        lineLayouts.removeAll()
        intraLineChanges.removeAll()
        intraLineMisses.removeAll()
        hoveredBlock = nil
        hoveredButton = nil
        gutterDrag = nil
        if isNewFile {
            textSelection = nil
            cursor = nil
            textScrollX = 0
        } else {
            clampInteractionState()
        }
        pendingPaintFileID = content.fileID
        if let expansion {
            insertExpandedRows(expansion)
        } else {
            if animates, switchesLayout {
                Motion.crossfade(scrollView.layer, duration: Motion.leave)
            }
            relayout(force: true, reload: true)
        }
        if keepsScroll {
            tableView.scroll(scrollOrigin)
        } else {
            tableView.scroll(.zero)
        }
    }

    // MARK: Expansion's motion

    /// How expanding changed the rows: a hunk header that went away (two
    /// hunks joined) and the lines revealed. Nil unless it's that and at
    /// most 100 rows: the table then reloads.
    struct ExpansionChange: Equatable {
        var removed: IndexSet
        var inserted: IndexSet
    }

    /// What a row shows, for matching rows across documents: a hunk header
    /// matches any other (expanding changes its range), a line its numbers.
    private struct RowKey: Equatable {
        var kind: UInt8
        var before: Int
        var after: Int

        init(_ row: DocumentRow, in document: DiffDocument) {
            kind = row.kind.rawValue
            guard row.kind != .hunk else {
                before = -1
                after = -1
                return
            }
            // A line's numbers, old and new, are unique within a file's
            // diff.
            func key(_ index: Int32) -> Int {
                guard index >= 0 else {
                    return -1
                }
                let line = document.lines[Int(index)]
                return line.oldNumber &* 1_000_003 &+ line.newNumber
            }
            before = key(row.before)
            after = key(row.after)
        }
    }

    /// The rows expanding `old` into `new` inserted (and the one header it
    /// may have joined away), when that's all that changed and no more
    /// than 100 rows came in.
    static func expansion(from old: DiffDocument, to new: DiffDocument) -> ExpansionChange? {
        let oldCount = old.rows.count
        let newCount = new.rows.count
        guard newCount > oldCount, newCount - oldCount <= 101, old.isSplit == new.isSplit else {
            return nil
        }
        var prefix = 0
        while prefix < oldCount, prefix < newCount,
              RowKey(old.rows[prefix], in: old) == RowKey(new.rows[prefix], in: new) {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldCount - prefix, suffix < newCount - prefix,
              RowKey(old.rows[oldCount - 1 - suffix], in: old) == RowKey(new.rows[newCount - 1 - suffix], in: new) {
            suffix += 1
        }
        let removed = prefix..<(oldCount - suffix)
        let inserted = prefix..<(newCount - suffix)
        guard removed.count <= 1, removed.allSatisfy({ old.rows[$0].kind == .hunk }),
              (1...100).contains(inserted.count)
        else {
            return nil
        }
        return ExpansionChange(removed: IndexSet(integersIn: removed), inserted: IndexSet(integersIn: inserted))
    }

    /// Lays out the new document and inserts its revealed rows, sliding
    /// down from the row above over 0.22 s, as the rows below make room.
    private func insertExpandedRows(_ change: ExpansionChange) {
        let width = max(scrollView.contentView.bounds.width, 200)
        geometry = DiffRowGeometry(
            width: width,
            isSplit: document.isSplit,
            showsStaging: shownContent?.staging != nil,
            digits: document.lineNumberDigits,
            font: font
        )
        layoutWidth = width
        lineLayouts.removeAll()
        textCache.reset()
        computeRowHeights(wraps: shownContent?.wrapsLines ?? true)
        Motion.run(Motion.arrive, in: tableView) { animates in
            tableView.beginUpdates()
            if !change.removed.isEmpty {
                tableView.removeRows(at: change.removed, withAnimation: animates ? .effectFade : [])
            }
            tableView.insertRows(at: change.inserted, withAnimation: animates ? .slideDown : [])
            tableView.endUpdates()
        }
        // Rows keep their views as they move: tell each its new row.
        tableView.enumerateAvailableRowViews { view, row in
            (view as? DiffRowView)?.row = row
            view.needsDisplay = true
        }
    }

    /// Keeps the selection and cursor inside the new document.
    private func clampInteractionState() {
        let count = document.rowCount
        if let selection = textSelection, selection.end.row >= count {
            textSelection = nil
        }
        if let cursor, max(cursor.anchor, cursor.head) >= count {
            self.cursor = nil
        }
    }

    // MARK: Layout

    @objc private func clipViewFrameDidChange(_ notification: Notification) {
        scheduleRelayout()
    }

    @objc private func displayOptionsDidChange(_ notification: Notification) {
        increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        textCache.reset()
        redrawVisibleRows()
    }

    /// Recomputes heights for the new width: at once for small documents,
    /// after live resize, and coalesced for large ones.
    func scheduleRelayout() {
        let width = scrollView.contentView.bounds.width
        guard width != layoutWidth else {
            return
        }
        if scrollView.inLiveResize {
            return
        }
        if document.rowCount > 20_000 {
            relayoutTask?.cancel()
            relayoutTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else {
                    return
                }
                self?.relayout(force: false)
            }
            return
        }
        relayout(force: false)
    }

    /// Live resize ended: wrap for the final width.
    func liveResizeDidEnd() {
        relayout(force: false)
    }

    /// Computes the geometry and every row's height for the current width,
    /// and reloads or notes the heights that changed.
    func relayout(force: Bool, reload: Bool = false) {
        let width = max(scrollView.contentView.bounds.width, 200)
        let content = shownContent
        let newGeometry = DiffRowGeometry(
            width: width,
            isSplit: document.isSplit,
            showsStaging: content?.staging != nil,
            digits: document.lineNumberDigits,
            font: font
        )
        let columnsChanged = newGeometry.columnsPerLine(.before) != geometry.columnsPerLine(.before)
            || newGeometry.columnsPerLine(.after) != geometry.columnsPerLine(.after)
        guard force || reload || newGeometry != geometry else {
            return
        }
        geometry = newGeometry
        layoutWidth = width
        if columnsChanged || force {
            lineLayouts.removeAll()
            textCache.reset()
        }
        let wraps = content?.wrapsLines ?? true
        let heightsChange = force || reload || (wraps && columnsChanged)
        if heightsChange {
            computeRowHeights(wraps: wraps)
        }
        if reload {
            tableView.reloadData()
            tableView.layoutSubtreeIfNeeded()
        } else if heightsChange, document.rowCount > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<document.rowCount))
            }
        }
        redrawVisibleRows()
    }

    /// Every row's height: one visual line per row unless lines wrap, then
    /// ⌈columns ÷ columns per line⌉ lines (the taller half, split).
    private func computeRowHeights(wraps: Bool) {
        let lineHeight = font.lineHeight
        let columnsBefore = geometry.columnsPerLine(.before)
        let columnsAfter = geometry.columnsPerLine(.after)
        var heights = [CGFloat](repeating: lineHeight, count: document.rowCount)
        var widest = 0
        for (index, row) in document.rows.enumerated() {
            switch row.kind {
            case .hunk:
                heights[index] = lineHeight + DiffTableMetrics.hunkRowExtraHeight
            case .noNewline:
                continue
            case .context, .added, .deleted, .modified:
                var lines = 1
                if document.isSplit {
                    if let line = row.line(.before) {
                        widest = max(widest, document.lines[line].info.columns)
                        if wraps {
                            lines = max(lines, visualLineCount(line, columnsPerLine: columnsBefore))
                        }
                    }
                    if let line = row.line(.after) {
                        widest = max(widest, document.lines[line].info.columns)
                        if wraps {
                            lines = max(lines, visualLineCount(line, columnsPerLine: columnsAfter))
                        }
                    }
                } else if let line = row.unifiedLine {
                    widest = max(widest, document.lines[line].info.columns)
                    if wraps {
                        lines = visualLineCount(line, columnsPerLine: columnsBefore)
                    }
                }
                heights[index] = CGFloat(lines) * lineHeight
            }
        }
        rowHeights = heights
        maximumTextWidth = CGFloat(widest) * font.characterWidth
        if !wraps {
            clampTextScroll()
        }
    }

    private func visualLineCount(_ line: Int, columnsPerLine: Int) -> Int {
        let info = document.lines[line].info
        if let count = info.visualLineCount(columnsPerLine: columnsPerLine) {
            return count
        }
        return layout(ofLine: line, columnsPerLine: columnsPerLine).visualLineCount
    }

    /// A line laid out at a number of columns (cached).
    func layout(ofLine line: Int, columnsPerLine: Int) -> LineLayout {
        let key = LayoutKey(line: line, columnsPerLine: columnsPerLine)
        if let layout = lineLayouts[key] {
            return layout
        }
        let documentLine = document.lines[line]
        let layout = LineLayout(
            documentLine.text,
            skippingFirstScalar: documentLine.hasMarker,
            info: documentLine.info,
            tabSize: document.tabSize,
            columnsPerLine: columnsPerLine
        )
        if lineLayouts.count > 4_000 {
            lineLayouts.removeAll(keepingCapacity: true)
        }
        lineLayouts[key] = layout
        return layout
    }

    /// The columns per visual line a side's text gets now.
    func columnsPerLine(_ column: DiffColumn) -> Int {
        (shownContent?.wrapsLines ?? true) ? geometry.columnsPerLine(document.isSplit ? column : .before) : Int.max
    }

    /// A line's layout on a side as drawn now.
    func layout(ofLine line: Int, side: DiffColumn) -> LineLayout {
        layout(ofLine: line, columnsPerLine: columnsPerLine(side))
    }

    /// The intra-line change of a paired line, computed on first use.
    func intraLineChange(ofLine line: Int) -> IntraLineRange? {
        let documentLine = document.lines[line]
        guard documentLine.partner >= 0 else {
            return nil
        }
        let deleted = documentLine.type == .delete ? line : documentLine.partner
        let added = documentLine.type == .delete ? documentLine.partner : line
        if intraLineMisses.contains(deleted) {
            return nil
        }
        let change: IntraLineChange
        if let cached = intraLineChanges[deleted] {
            change = cached
        } else {
            guard let computed = EspalierUI.intraLineChange(deleted: document.lines[deleted], added: document.lines[added]) else {
                intraLineMisses.insert(deleted)
                return nil
            }
            intraLineChanges[deleted] = computed
            change = computed
        }
        let range = documentLine.type == .delete ? change.before : change.after
        return range.length > 0 ? range : nil
    }

    // MARK: Sideways scrolling (lines that don't wrap)

    /// Scrolls the text sideways by `delta` points.
    func scrollText(by delta: CGFloat) {
        guard shownContent?.wrapsLines == false else {
            return
        }
        let previous = textScrollX
        textScrollX += delta
        clampTextScroll()
        if textScrollX != previous {
            redrawVisibleRows()
        }
    }

    private func clampTextScroll() {
        let visible = geometry.half(.before).text.upperBound - geometry.half(.before).text.lowerBound
        let maximum = max(maximumTextWidth - visible + font.characterWidth * 2, 0)
        textScrollX = min(max(textScrollX, 0), maximum)
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        document.rowCount
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeights.indices.contains(row) ? rowHeights[row] : font.lineHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("DiffRow")
        let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffRowView) ?? DiffRowView()
        view.identifier = identifier
        view.controller = self
        view.row = row
        view.needsDisplay = true
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    // MARK: Drawing

    /// The file whose first rows haven't been drawn yet.
    private var pendingPaintFileID: String?

    /// A row view drew (the first one after a new file's document ends the
    /// `DiffOpen` interval).
    func rowDidDraw() {
        if let fileID = pendingPaintFileID {
            pendingPaintFileID = nil
            actions.didPaint(fileID)
        }
    }

    /// Marks the visible rows for redrawing.
    func redrawVisibleRows() {
        tableView.enumerateAvailableRowViews { view, _ in
            view.needsDisplay = true
        }
    }

    // MARK: Drawing's motion

    /// The rows on screen whose staging marks differ between `old` and
    /// `new` (a line's number cells, a hunk's checkbox); none when motion
    /// doesn't run.
    private func rowsChangingInclusion(from old: StagingState?, to new: StagingState?) -> [Int] {
        guard let old, let new, Motion.animates(tableView) else {
            return []
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        var rows: [Int] = []
        for row in visible.location..<(visible.location + visible.length) where document.rows.indices.contains(row) {
            let documentRow = document.rows[row]
            if documentRow.kind == .hunk {
                let hunk = document.hunks[Int(documentRow.hunk)]
                if inclusion(ofHunk: hunk, staging: old) != inclusion(ofHunk: hunk, staging: new) {
                    rows.append(row)
                }
                continue
            }
            for column in [DiffColumn.before, .after] {
                guard let line = documentRow.line(column), document.lines[line].isChange else {
                    continue
                }
                let number = document.lines[line].diffLineNumber
                if number >= 0, old.selection.isSelected(number) != new.selection.isSelected(number) {
                    rows.append(row)
                    break
                }
            }
        }
        return rows
    }

    /// Crossfades `rows`' next drawing over `duration` (a transition on
    /// each row's layer, only for rows on screen).
    private func crossfade(rows: [Int], duration: TimeInterval) {
        for row in rows {
            guard let view = tableView.rowView(atRow: row, makeIfNecessary: false) else {
                continue
            }
            Motion.crossfade(view.layer, duration: duration)
            view.needsDisplay = true
        }
    }

    /// The rows the pointer's hover draws on: a block's handle, a hunk
    /// header's button.
    private func hoverRows(block: Int?, buttonHunk: Int?) -> [Int] {
        var rows: [Int] = []
        if let block, document.blocks.indices.contains(block) {
            rows.append(contentsOf: document.blocks[block].rows)
        }
        if let buttonHunk, document.hunks.indices.contains(buttonHunk) {
            rows.append(document.hunks[buttonHunk].row)
        }
        return rows
    }

    /// Whether the table shows its selection as active.
    var isFocused: Bool {
        guard let window = tableView.window else {
            return false
        }
        return window.firstResponder === tableView && window.isKeyWindow
    }

    /// Whether a line is included in the commit, as drawn (with a drag in
    /// progress applied).
    func isIncluded(line: Int) -> Bool? {
        guard let staging = shownContent?.staging else {
            return nil
        }
        let documentLine = document.lines[line]
        guard documentLine.isChange, documentLine.diffLineNumber >= 0 else {
            return nil
        }
        let number = documentLine.diffLineNumber
        if let drag = gutterDrag, number >= min(drag.from, drag.to), number <= max(drag.from, drag.to) {
            return drag.include
        }
        return staging.selection.isSelected(number)
    }

    /// How much of a hunk the commit includes.
    func inclusion(ofHunk hunk: DocumentHunk) -> DiffSelectionType? {
        inclusion(ofHunk: hunk, staging: shownContent?.staging)
    }

    /// How much of a hunk `staging` includes.
    private func inclusion(ofHunk hunk: DocumentHunk, staging: StagingState?) -> DiffSelectionType? {
        guard let staging else {
            return nil
        }
        var lines = Set<Int>()
        for row in hunk.rows where document.rows[row].isChange {
            for column in [DiffColumn.before, .after] {
                if let line = document.rows[row].line(column), document.lines[line].isChange, document.lines[line].diffLineNumber >= 0 {
                    lines.insert(line)
                }
            }
        }
        guard !lines.isEmpty else {
            return nil
        }
        let selected = lines.filter { staging.selection.isSelected(document.lines[$0].diffLineNumber) }.count
        if selected == lines.count {
            return .all
        }
        return selected == 0 ? DiffSelectionType.none : .partial
    }

    // MARK: Hit-testing

    /// The row at a point in the table, if any.
    func row(at point: CGPoint) -> Int? {
        let row = tableView.row(at: point)
        return row >= 0 ? row : nil
    }

    /// What a point in the table is over.
    func hit(at point: CGPoint) -> DiffHit {
        guard let row = row(at: point), document.rows.indices.contains(row) else {
            return .none
        }
        let rect = tableView.rect(ofRow: row)
        let documentRow = document.rows[row]
        let x = point.x
        if documentRow.kind == .hunk {
            let hunk = Int(documentRow.hunk)
            let documentHunk = document.hunks[hunk]
            let buttons = DiffHunkButton.buttons(for: documentHunk.expansionType)
            for (button, buttonRect) in zip(buttons, geometry.expansionButtonRects(count: buttons.count, rowHeight: rect.height)) {
                if x >= buttonRect.minX, x < buttonRect.maxX {
                    return .expansion(hunk: hunk, kind: button)
                }
            }
            if documentHunk.changedDiffLines != nil, let checkbox = geometry.hunkCheckbox,
               x >= (geometry.handle?.lowerBound ?? checkbox.lowerBound), x < checkbox.upperBound {
                return .hunkCheckbox(hunk: hunk)
            }
            return .hunkHeader(hunk: hunk)
        }
        if documentRow.kind == .noNewline {
            return .none
        }
        if let handle = geometry.handle, x >= handle.lowerBound, x < handle.upperBound, documentRow.block >= 0 {
            return .handle(row: row, block: Int(documentRow.block))
        }
        let side = geometry.column(atX: x)
        let half = geometry.half(side)
        if x < half.marker.lowerBound {
            let gutterSide: DiffColumn = document.isSplit ? side : .before
            if document.changedLine(ofRow: row, column: gutterSide) != nil {
                return .gutter(row: row, column: gutterSide)
            }
            if !document.isSplit, documentRow.isChange {
                return .gutter(row: row, column: .before)
            }
            return .inertGutter(row: row)
        }
        let textSide: DiffColumn = document.isSplit ? side : .before
        guard let line = document.textLine(ofRow: row, column: textSide) else {
            return .none
        }
        let layout = layout(ofLine: line, side: textSide)
        let visualLine = Int(((point.y - rect.minY) / font.lineHeight).rounded(.down))
        let column = geometry.textColumn(atX: x, side: textSide, scrollX: textScrollX)
        let offset = layout.offset(atVisualLine: visualLine, column: column)
        return .text(row: row, column: textSide, offset: offset)
    }

    /// The text position nearest a point, on a side, for extending a
    /// selection (rows without text on that side keep searching up).
    func textPosition(at point: CGPoint, column: DiffColumn) -> DiffTextPosition? {
        guard document.rowCount > 0 else {
            return nil
        }
        var row: Int
        if point.y < 0 {
            return DiffTextPosition(row: 0, offset: 0)
        }
        if let hitRow = self.row(at: point) {
            row = hitRow
        } else {
            row = document.rowCount - 1
            if let line = document.textLine(ofRow: row, column: column) {
                return DiffTextPosition(row: row, offset: document.lines[line].info.utf16Count)
            }
        }
        guard let line = document.textLine(ofRow: row, column: column) else {
            // A row with no text on this side: its start (for rows below the
            // anchor, the selection then ends before it).
            return DiffTextPosition(row: row, offset: 0)
        }
        let rect = tableView.rect(ofRow: row)
        let layout = layout(ofLine: line, side: column)
        let visualLine = Int(((point.y - rect.minY) / font.lineHeight).rounded(.down))
        let textColumn = geometry.textColumn(atX: point.x, side: column, scrollX: textScrollX)
        return DiffTextPosition(row: row, offset: layout.offset(atVisualLine: visualLine, column: textColumn))
    }

    // MARK: Mouse

    /// The mouse went down: starts a gutter drag, a text selection, or
    /// clicks a hunk header's control. Returns how to track the drag.
    func mouseDown(at point: CGPoint, clickCount: Int, extendsSelection: Bool) -> DiffDrag {
        guard shownContent?.isInteractive ?? false else {
            return .none
        }
        let hit = hit(at: point)
        switch hit {
        case .expansion(let hunk, let button):
            expand(hunk: hunk, button: button)
            return .none
        case .hunkCheckbox(let hunk):
            guard let range = document.hunks[hunk].changedDiffLines else {
                return .none
            }
            if showWhitespaceHintIfNeeded(at: point) {
                return .none
            }
            guard shownContent?.staging?.canSelectLines == true else {
                return .none
            }
            actions.staging?.toggleLines(.range(range))
            return .none
        case .handle(_, let block):
            if showWhitespaceHintIfNeeded(at: point) {
                return .none
            }
            guard shownContent?.staging?.canSelectLines == true else {
                return .none
            }
            actions.staging?.toggleLines(.block(containing: document.blocks[block].diffLines.lowerBound))
            return .none
        case .gutter(let row, let column):
            guard shownContent?.staging != nil else {
                return beginCursorClick(row: row)
            }
            if showWhitespaceHintIfNeeded(at: point) {
                return .none
            }
            guard shownContent?.staging?.canSelectLines == true,
                  let line = document.changedLine(ofRow: row, column: column),
                  let included = isIncluded(line: line)
            else {
                return .none
            }
            let number = document.lines[line].diffLineNumber
            gutterDrag = (column, number, number, !included)
            redrawVisibleRows()
            return .gutter
        case .inertGutter(let row):
            return beginCursorClick(row: row)
        case .text(let row, let column, let offset):
            tableView.window?.makeFirstResponder(tableView)
            setCursor(row: row, extending: false, redraw: false)
            if clickCount >= 3 {
                textSelection = document.lineSelection(row: row, column: column)
            } else if clickCount == 2 {
                textSelection = document.wordSelection(row: row, column: column, offset: offset)
            } else if extendsSelection, var selection = textSelection, selection.column == column {
                selection.head = DiffTextPosition(row: row, offset: offset)
                textSelection = selection
            } else {
                let position = DiffTextPosition(row: row, offset: offset)
                textSelection = DiffTextSelection(column: column, anchor: position, head: position)
            }
            return .text(column)
        case .hunkHeader, .none:
            tableView.window?.makeFirstResponder(tableView)
            textSelection = nil
            return .none
        }
    }

    private func beginCursorClick(row: Int) -> DiffDrag {
        tableView.window?.makeFirstResponder(tableView)
        textSelection = nil
        setCursor(row: row, extending: false)
        return .none
    }

    /// The mouse moved with the button down.
    func mouseDragged(to point: CGPoint, drag: DiffDrag) {
        switch drag {
        case .gutter:
            guard var current = gutterDrag, document.rowCount > 0 else {
                return
            }
            let row = self.row(at: point) ?? (point.y < 0 ? 0 : document.rowCount - 1)
            // Split, the side under the pointer.
            let column = document.isSplit ? geometry.column(atX: point.x) : current.column
            if let line = document.changedLine(ofRow: row, column: column) {
                let number = document.lines[line].diffLineNumber
                if number >= 0, number != current.to {
                    current.to = number
                    gutterDrag = current
                    redrawVisibleRows()
                }
            }
        case .text(let column):
            guard var selection = textSelection, let position = textPosition(at: point, column: column) else {
                return
            }
            if !(shownContent?.wrapsLines ?? true) {
                let text = geometry.half(column).text
                if point.x > text.upperBound {
                    scrollText(by: font.characterWidth)
                } else if point.x < text.lowerBound, textScrollX > 0 {
                    scrollText(by: -font.characterWidth)
                }
            }
            selection.head = position
            textSelection = selection
        case .none:
            break
        }
    }

    /// The mouse went up: a gutter drag applies its lines.
    func mouseUp(drag: DiffDrag) {
        guard case .gutter = drag, let gutterDrag else {
            return
        }
        self.gutterDrag = nil
        let lower = min(gutterDrag.from, gutterDrag.to)
        let upper = max(gutterDrag.from, gutterDrag.to)
        let lines: DiffLines = lower == upper ? .line(lower) : .range(lower...upper)
        actions.staging?.setLines(lines, gutterDrag.include)
        redrawVisibleRows()
    }

    /// The pointer moved: updates the hovered block and button.
    func mouseMoved(to point: CGPoint?) {
        var block: Int?
        var button: (hunk: Int, button: DiffHunkButton)?
        var toolTip: String?
        if let point {
            switch hit(at: point) {
            case .handle(_, let hovered):
                block = hovered
            case .gutter(let row, _):
                if shownContent?.staging != nil, document.rows[row].block >= 0 {
                    block = Int(document.rows[row].block)
                }
            case .expansion(let hunk, let kind):
                button = (hunk, kind)
                toolTip = kind.title
            default:
                break
            }
        }
        if shownContent?.staging == nil || gutterDrag != nil {
            block = nil
        }
        let changed = block != hoveredBlock || button?.hunk != hoveredButton?.hunk || button?.button != hoveredButton?.button
        // The handle and a hunk button's hover fade out over 0.15 s and in
        // over 0.08 s.
        let fadesHover = changed && Motion.animates(tableView)
        let leaving = fadesHover ? hoverRows(block: hoveredBlock, buttonHunk: hoveredButton?.hunk) : []
        hoveredBlock = block
        hoveredButton = button
        if tableView.toolTip != toolTip {
            tableView.toolTip = toolTip
        }
        if changed {
            redrawVisibleRows()
        }
        if fadesHover {
            crossfade(rows: leaving, duration: Motion.hoverOut)
            crossfade(rows: hoverRows(block: block, buttonHunk: button?.hunk), duration: Motion.hoverIn)
        }
    }

    /// Whether the cursor over a point is an I-beam (text).
    func showsTextCursor(at point: CGPoint) -> Bool {
        if case .text = hit(at: point) {
            return true
        }
        return false
    }

    // MARK: Expansion

    private func expand(hunk: Int, button: DiffHunkButton) {
        let documentHunk = document.hunks[hunk]
        let (index, kind) = button.expansion(ofHunk: documentHunk.index)
        guard index >= 0 else {
            return
        }
        actions.expandHunk(index, kind)
        announce("Expanded")
    }

    /// Asks VoiceOver to say `message`.
    func announce(_ message: String) {
        NSAccessibility.post(
            element: tableView,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    /// Whether "Expand Whole File" can expand anything (not when the diff
    /// is one hunk that can't expand).
    var canExpandWholeFile: Bool {
        guard let content = shownContent, content.canExpand, !content.hasExpandedLines else {
            return false
        }
        let hunks = content.diff.hunks
        return hunks.count != 1 || hunks[0].expansionType != .none
    }

    // MARK: Whitespace hint

    /// While whitespace is hidden, a click on the gutter offers to show it
    /// (the "Show whitespace changes?" popover).
    private func showWhitespaceHintIfNeeded(at point: CGPoint) -> Bool {
        guard let staging = shownContent?.staging, staging.hidesWhitespace else {
            return false
        }
        showWhitespaceHint(at: point)
        return true
    }

    func showWhitespaceHint(at point: CGPoint) {
        whitespaceHint?.close()
        whitespaceHintPoint = point
        guard tableView.window != nil else {
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(rootView: WhitespaceHintView(
            onNo: { [weak popover] in popover?.close() },
            onYes: { [weak self, weak popover] in
                popover?.close()
                self?.actions.staging?.showWhitespaceChanges()
            }
        ))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        let anchor = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
        popover.show(relativeTo: anchor, of: tableView, preferredEdge: .maxX)
        whitespaceHint = popover
    }

    // MARK: Keyboard

    /// Moves the line cursor to `row` (extending the range with Shift).
    func setCursor(row: Int, extending: Bool, redraw: Bool = true) {
        guard document.rows.indices.contains(row) else {
            return
        }
        if extending, let cursor {
            self.cursor = (cursor.anchor, row)
        } else {
            cursor = (row, row)
        }
        tableView.scrollRowToVisible(row)
        if redraw {
            redrawVisibleRows()
        }
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) {
            NSAccessibility.post(element: rowView, notification: .focusedUIElementChanged)
        }
    }

    /// The rows under the cursor.
    var cursorRows: ClosedRange<Int>? {
        guard let cursor else {
            return nil
        }
        return min(cursor.anchor, cursor.head)...max(cursor.anchor, cursor.head)
    }

    /// Handles a key; false to let the table handle it.
    func keyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let option = modifiers.contains(.option)
        let shift = modifiers.contains(.shift)
        guard let characters = event.charactersIgnoringModifiers, let key = characters.unicodeScalars.first else {
            return false
        }
        switch Int(key.value) {
        case NSUpArrowFunctionKey:
            if option {
                moveToHunk(forward: false)
            } else {
                moveCursor(by: -1, extending: shift)
            }
            return true
        case NSDownArrowFunctionKey:
            if option {
                moveToHunk(forward: true)
            } else {
                moveCursor(by: 1, extending: shift)
            }
            return true
        case 0x20:
            guard shownContent?.isInteractive == true else {
                return true
            }
            if option {
                toggleCursorBlock()
            } else {
                toggleCursorLines()
            }
            return true
        case 0x1B:
            textSelection = nil
            return true
        default:
            return false
        }
    }

    private func moveCursor(by delta: Int, extending: Bool) {
        guard document.rowCount > 0 else {
            return
        }
        let start = cursor?.head ?? (delta > 0 ? -1 : document.rowCount)
        guard let row = document.cursorRow(from: start + delta, forward: delta > 0) else {
            return
        }
        textSelection = nil
        setCursor(row: row, extending: extending)
    }

    private func moveToHunk(forward: Bool) {
        let current = cursor?.head ?? (forward ? -1 : document.rowCount)
        let hunkRows = document.hunks.map(\.row)
        let target = forward ? hunkRows.first { $0 > current } : hunkRows.last { $0 < current - 1 }
        guard let target, let row = document.cursorRow(from: target + 1, forward: true) ?? document.cursorRow(from: target, forward: false) else {
            return
        }
        textSelection = nil
        setCursor(row: row, extending: false)
        tableView.scrollRowToVisible(target)
    }

    /// Space: toggles the lines under the cursor.
    private func toggleCursorLines() {
        guard let rows = cursorRows else {
            return
        }
        guard let staging = shownContent?.staging else {
            return
        }
        if staging.hidesWhitespace {
            let rect = tableView.rect(ofRow: rows.lowerBound)
            showWhitespaceHint(at: CGPoint(x: geometry.before.gutter.upperBound, y: rect.midY))
            return
        }
        guard staging.canSelectLines else {
            return
        }
        let numbers = rows.flatMap { document.diffLines(ofRow: $0) }
        guard let first = numbers.min(), let last = numbers.max() else {
            return
        }
        actions.staging?.toggleLines(first == last ? .line(first) : .range(first...last))
    }

    /// Option-Space: toggles the block under the cursor.
    private func toggleCursorBlock() {
        guard let row = cursor?.head, let block = document.block(ofRow: row), let staging = shownContent?.staging else {
            return
        }
        if staging.hidesWhitespace {
            let rect = tableView.rect(ofRow: row)
            showWhitespaceHint(at: CGPoint(x: geometry.before.gutter.upperBound, y: rect.midY))
            return
        }
        guard staging.canSelectLines else {
            return
        }
        actions.staging?.toggleLines(.block(containing: block.diffLines.lowerBound))
    }

    // MARK: Copy and select all

    /// Whether Copy has something to copy.
    var canCopy: Bool {
        if let textSelection, !textSelection.isEmpty {
            return true
        }
        return cursorRows != nil
    }

    /// Copies the selected text, or with none the lines under the cursor,
    /// to `pasteboard` (tests pass their own).
    func copySelection(to pasteboard: NSPasteboard = .general) {
        let text: String
        if let textSelection, !textSelection.isEmpty {
            text = document.text(of: textSelection)
        } else if let rows = cursorRows {
            text = document.text(ofRows: rows)
        } else {
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Selects one side's whole text: the side last selected in.
    func selectAll() {
        let column = textSelection?.column ?? .before
        textSelection = document.selectAll(column)
    }

    // MARK: Context menus

    /// The menu for a right-click: the gutter's discard item on a changed
    /// line or block in Changes, the expansion items on a hunk header, and
    /// Copy, Select All, and the expansion items on the text.
    func menu(at point: CGPoint) -> NSMenu? {
        guard shownContent?.isInteractive ?? false else {
            return nil
        }
        let hit = hit(at: point)
        switch hit {
        case .gutter(let row, let column):
            guard let staging = shownContent?.staging else {
                // A read-only diff's gutter has the text's menu.
                return textMenu()
            }
            guard staging.canDiscard || staging.hidesWhitespace else {
                return nil
            }
            if staging.hidesWhitespace {
                showWhitespaceHint(at: point)
                return nil
            }
            guard let line = document.changedLine(ofRow: row, column: column) else {
                return nil
            }
            return discardMenu(.line(document.lines[line].diffLineNumber))
        case .handle(_, let block):
            guard let staging = shownContent?.staging, staging.canDiscard || staging.hidesWhitespace else {
                return nil
            }
            if staging.hidesWhitespace {
                showWhitespaceHint(at: point)
                return nil
            }
            return discardMenu(.block(containing: document.blocks[block].diffLines.lowerBound))
        case .expansion, .hunkHeader, .hunkCheckbox:
            let menu = NSMenu()
            if let item = expansionMenuItem() {
                menu.addItem(item)
            }
            return menu.items.isEmpty ? nil : menu
        case .text:
            return textMenu()
        case .inertGutter, .none:
            return textMenu()
        }
    }

    private func discardMenu(_ lines: DiffLines) -> NSMenu? {
        guard let title = actions.staging?.discardTitle(lines) else {
            return nil
        }
        let menu = NSMenu()
        let item = ClosureMenuItem(title: title) { [weak self] in
            self?.actions.staging?.discardLines(lines)
        }
        menu.addItem(item)
        return menu
    }

    private func textMenu() -> NSMenu {
        let menu = NSMenu()
        let copy = ClosureMenuItem(title: "Copy") { [weak self] in
            self?.copySelection()
        }
        copy.isEnabled = canCopy
        menu.addItem(copy)
        menu.addItem(ClosureMenuItem(title: "Select All") { [weak self] in
            self?.selectAll()
        })
        if let item = expansionMenuItem() {
            menu.addItem(.separator())
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    /// "Expand Whole File", or "Collapse Expanded Lines" once expanded.
    func expansionMenuItem() -> NSMenuItem? {
        guard let content = shownContent, content.canExpand || content.hasExpandedLines else {
            return nil
        }
        if content.hasExpandedLines {
            return ClosureMenuItem(title: "Collapse Expanded Lines") { [weak self] in
                self?.actions.collapseExpandedLines()
            }
        }
        let item = ClosureMenuItem(title: "Expand Whole File") { [weak self] in
            self?.actions.expandWholeFile()
        }
        item.isEnabled = canExpandWholeFile
        return item
    }
}

/// How a mouse drag is tracked.
enum DiffDrag: Equatable {
    case none
    /// Down the gutter, including or excluding lines.
    case gutter
    /// Selecting text on a side.
    case text(DiffColumn)
}

/// A menu item that runs a closure.
func ClosureMenuItem(title: String, handler: @escaping @MainActor () -> Void) -> NSMenuItem {
    let target = MenuItemTarget(handler: handler)
    let item = NSMenuItem(title: title, action: #selector(MenuItemTarget.run), keyEquivalent: "")
    item.target = target
    // The item keeps its target alive.
    item.representedObject = target
    return item
}

/// The target of a closure's menu item.
final class MenuItemTarget: NSObject {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func run() {
        handler()
    }
}
