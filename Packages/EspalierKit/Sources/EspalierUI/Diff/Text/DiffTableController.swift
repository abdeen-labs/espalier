// The controller of the diff table. It owns the AppKit table, builds the
// `DiffDocument` off the main actor whenever the diff or a setting that
// shapes rows changes, computes row heights with monospace arithmetic, and
// handles the mouse and keyboard. While a new document builds, the previous
// one stays on screen. When lines don't wrap, the table is as wide as the
// longest line needs, so the scroll view shows its horizontal scroller and
// scrolls sideways; rows draw at the visible part, only their text moved.
// A conflicted file drawn as blocks (`ConflictBlocks`) has a header atop
// each block whose Use <branch>'s Version button, clicked, asks for that
// side of that conflict; the buttons wait until the file shows again.

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
    /// A conflicted file to draw as blocks, in place of the diff (always
    /// unified).
    var conflicts: ConflictBlocks?

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
        isInteractive: Bool = true,
        conflicts: ConflictBlocks? = nil
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
        self.conflicts = conflicts
    }

    /// What the document is built from.
    var documentInput: DiffDocumentInput {
        DiffDocumentInput(
            hunks: diff.hunks,
            maxLineNumber: diff.maxLineNumber,
            isSplit: isSplit && conflicts == nil,
            canExpand: canExpand,
            tabSize: tabSize,
            detectsConflictMarkers: detectsConflictMarkers,
            conflictFile: conflicts?.file
        )
    }

    /// Whether `other` needs a new document.
    func needsNewDocument(comparedTo other: DiffTableContent) -> Bool {
        fileID != other.fileID || isSplit != other.isSplit || tabSize != other.tabSize
            || canExpand != other.canExpand || detectsConflictMarkers != other.detectsConflictMarkers
            || conflicts?.file != other.conflicts?.file
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
    /// A conflict block's button: keeps one side (ours or theirs) of the
    /// conflict at an index in the file as shown; returns whether it was
    /// kept.
    var chooseConflictSide: (@MainActor (ConflictedFileText, Int, ManualConflictResolution) async -> Bool)?
}


/// The diff table's controller: the table's data source and delegate.
@MainActor
final class DiffTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView: NSScrollView
    let tableView: DiffTableView
    var actions = DiffTableActions()

    private(set) var content: DiffTableContent?
    /// The content of the document shown (it lags `content` while a new
    /// document builds).
    private(set) var shownContent: DiffTableContent?
    private(set) var document = DiffDocument.empty
    private var buildTask: Task<Void, Never>?
    private var buildGeneration = 0
    /// A new document is building: the rows on screen are the previous
    /// one's, so gestures that stage, discard, or expand by its indexes
    /// wait for it.
    private(set) var isBuilding = false

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
    /// The width rows are wrapped for (lags while a large document's
    /// relayout is coalesced).
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
    /// The line cursor: the rows from `anchor` to `head`. A click in the
    /// text moves it without showing it; the keyboard and a click in the
    /// gutter show it.
    private(set) var cursor: (anchor: Int, head: Int)?
    /// Whether the line cursor shows (and Space, Option-Space, and Copy
    /// act on it).
    private(set) var showsCursor = false
    /// The block whose handle the pointer is over.
    private(set) var hoveredBlock: Int?
    /// The changed line whose numbers the pointer is over, while lines can
    /// be staged.
    private(set) var hoveredLine: (row: Int, column: DiffColumn)?
    /// The hunk header button the pointer is over.
    private(set) var hoveredButton: (hunk: Int, button: DiffHunkButton)?
    /// The conflict block button the pointer is over, by its header's
    /// index.
    private(set) var hoveredConflictButton: Int?
    /// The conflict block button pressed, while the pointer stays on it.
    private(set) var pressedConflictButton: Int?
    /// The conflict block button clicked last, while its side is kept and
    /// the file shows again: the buttons wait.
    private(set) var pendingConflictChoice: Int?
    /// Conflict block buttons' title widths, by title.
    private var conflictButtonTitleWidths: [String: CGFloat] = [:]
    /// The side being kept for the button clicked last.
    private var conflictChoiceTask: Task<Void, Never>?
    /// The discard asked for from the gutter's menu, by its number, until
    /// the file shows again without its lines or the discard is cancelled
    /// or fails.
    private var pendingDiscard: Int?
    /// The discards asked for, for numbering the next.
    private var discardRequests = 0
    /// A drag down the gutter: the original diff's indexes from and to,
    /// and whether it includes or excludes them.
    private(set) var gutterDrag: (column: DiffColumn, from: Int, to: Int, include: Bool)?
    /// How far the text is scrolled sideways when lines don't wrap: the
    /// clip view's horizontal scroll.
    private(set) var textScrollX: CGFloat = 0
    /// The longest line's width, for sideways scrolling.
    private var maximumTextWidth: CGFloat = 0

    /// Find in the diff: the container's model once attached
    /// (`attach(_:)`, DiffTableFind.swift).
    var find = DiffFindModel()
    /// Whether find's matches were highlighted, and the current match's
    /// row, as last drawn: their highlights fade as they change
    /// (DiffTableFind.swift).
    var findShowsHighlights = false
    var currentFindRow: Int?
    /// The format VoiceOver hears counts in.
    var numberFormat = defaultNumberFormat

    /// The popover offering to show whitespace changes, and where it was
    /// asked for.
    private var whitespaceHint: PopoverController?
    private(set) var whitespaceHintPoint: CGPoint?

    override init() {
        let tableView = DiffTableView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        self.tableView = tableView
        scrollView = UnbouncedScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        geometry = DiffRowGeometry(
            width: 600, isSplit: false, showsStaging: false, digits: 3,
            font: DiffFontMetrics(fontSize: Metrics.Diff.codeFontSize),
            oneNumber: false
        )
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        column.maxWidth = CGFloat(Float.greatestFiniteMagnitude)
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
        // Shown while lines don't wrap and one is wider than the pane.
        scrollView.hasHorizontalScroller = true
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(lookDidChange(_:)), name: Look.didChange, object: nil)
        tableView.sizeLastColumnToFit()
        connectFind()
    }

    /// The view went away: stops work in flight.
    func tearDown() {
        buildTask?.cancel()
        relayoutTask?.cancel()
        whitespaceHint?.close()
        find.disconnect(self)
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
        guard !isBuilding, let shown = shownContent else {
            // The document on screen keeps its content until the new one
            // installs with the latest; only a new font size applies to it
            // at once.
            if fontChanged, shownContent != nil {
                textCache.reset()
                relayout(force: true)
            }
            return
        }
        // The document is current: settings that don't shape rows.
        let conflictsChanged = shown.conflicts != content.conflicts
        let stagingShapeChanged = (shown.staging != nil) != (content.staging != nil)
        let stagingChanged = shown.staging != content.staging
        // Lines included or left out: the rows on screen whose number
        // cells or hunk checkbox change crossfade over 0.12 s.
        let fading = stagingShapeChanged || !stagingChanged
            ? InclusionChange()
            : rowsChangingInclusion(from: shown.staging, to: content.staging)
        defer {
            crossfade(rows: fading.rows, duration: Motion.mark)
        }
        shownContent = content
        if stagingChanged {
            hunkInclusions = fading.hunkInclusions
        }
        // Wrap Lines swaps the rows' layout: the pane crossfades over
        // 0.15 s, as Unified ↔ Split does.
        if shown.wrapsLines != content.wrapsLines, Motion.animates(tableView) {
            Motion.crossfade(scrollView.layer, duration: Motion.leave)
        }
        if fontChanged || stagingShapeChanged || shown.wrapsLines != content.wrapsLines {
            relayout(force: true)
        }
        if shown.tokensGeneration != content.tokensGeneration || fontChanged {
            textCache.reset()
        }
        if shown.tokensGeneration != content.tokensGeneration || stagingChanged
            || shown.hasExpandedLines != content.hasExpandedLines || fontChanged || stagingShapeChanged || conflictsChanged {
            redrawVisibleRows()
        }
        if shown.wrapsLines != content.wrapsLines {
            scrollText(toX: 0)
        }
    }

    private func buildDocument(for content: DiffTableContent) {
        buildGeneration &+= 1
        isBuilding = true
        let generation = buildGeneration
        let input = content.documentInput
        buildTask?.cancel()
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

    /// Shows a new document. The same file's expanded lines crossfade in
    /// over 0.22 s (up to 100 lines, when the table can insert them rather
    /// than reload); other changes the user made crossfade the pane
    /// (`documentCrossfade`). A hover showing moves to what's under the
    /// pointer in the new rows.
    private func install(_ document: DiffDocument, for content: DiffTableContent) {
        isBuilding = false
        let isNewFile = shownContent?.fileID != content.fileID
        let keepsScroll = !isNewFile
        let scrollOrigin = scrollView.contentView.bounds.origin
        let animates = !isNewFile && Motion.animates(tableView)
        let switchesLayout = shownContent.map { $0.isSplit != content.isSplit || $0.wrapsLines != content.wrapsLines } ?? false
        let canInsert = shownContent.map { $0.wrapsLines == content.wrapsLines && (($0.staging == nil) == (content.staging == nil)) } ?? false
        let expansion = animates && !switchesLayout && canInsert ? Self.expansion(from: self.document, to: document) : nil
        let fade = animates ? documentCrossfade(to: content, switchesLayout: switchesLayout) : nil
        let hovers = hoveredBlock != nil || hoveredLine != nil || hoveredButton != nil || hoveredConflictButton != nil

        self.document = document
        shownContent = content
        hunkInclusions.removeAll()
        textCache.reset()
        lineLayouts.removeAll()
        intraLineChanges.removeAll()
        intraLineMisses.removeAll()
        hoveredBlock = nil
        hoveredLine = nil
        hoveredButton = nil
        hoveredConflictButton = nil
        pressedConflictButton = nil
        pendingConflictChoice = nil
        pendingDiscard = nil
        gutterDrag = nil
        if isNewFile {
            textSelection = nil
            cursor = nil
            showsCursor = false
        } else {
            clampInteractionState()
        }
        pendingPaintFileID = content.fileID
        if let expansion {
            insertExpandedRows(expansion)
        } else {
            if let fade {
                Motion.crossfade(scrollView.layer, duration: fade)
            }
            relayout(force: true, reload: true)
        }
        if keepsScroll {
            tableView.scroll(scrollOrigin)
        } else {
            tableView.scroll(.zero)
        }
        // Laid out, find's matches follow (another file's first one
        // scrolled into view).
        find.documentDidChange(document, isNewFile: isNewFile)
        if hovers {
            refreshHover()
        }
    }

    /// How long the pane crossfades to the same file's next document, for
    /// a change the user made: Unified ↔ Split and Wrap Lines swap over
    /// 0.15 s; a conflict's side kept arrives over 0.22 s as the file shows
    /// again, and discarded lines leave over 0.15 s; lines expanded where
    /// the table reloads (Expand Whole File) arrive over 0.22 s, and
    /// collapsing them leaves over 0.15 s. Nil for the rest, which show at
    /// once: the model reloading the diff (it isn't interactive meanwhile),
    /// the file's contents arriving.
    private func documentCrossfade(to content: DiffTableContent, switchesLayout: Bool) -> TimeInterval? {
        guard let shown = shownContent else {
            return nil
        }
        if switchesLayout {
            return Motion.leave
        }
        if pendingConflictChoice != nil {
            return Motion.arrive
        }
        if pendingDiscard != nil {
            return Motion.leave
        }
        if shown.hasExpandedLines != content.hasExpandedLines, shown.isInteractive, content.isInteractive {
            return content.hasExpandedLines ? Motion.arrive : Motion.leave
        }
        return nil
    }

    /// Waits for the document building, if any, to install (for tests).
    func documentIdle() async {
        await buildTask?.value
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

    /// Lays out the new document and inserts its revealed rows at once, the
    /// pane crossfading to them over 0.22 s.
    private func insertExpandedRows(_ change: ExpansionChange) {
        let width = max(scrollView.contentView.bounds.width, 200)
        geometry = DiffRowGeometry(
            width: width,
            isSplit: document.isSplit,
            showsStaging: shownContent?.staging != nil,
            digits: document.lineNumberDigits,
            font: font,
            oneNumber: document.isWorkingFile
        )
        layoutWidth = width
        lineLayouts.removeAll()
        textCache.reset()
        computeRowHeights(wraps: shownContent?.wrapsLines ?? true)
        updateDocumentWidth()
        // The rows go in in a group of no duration, so the table's own row
        // motion doesn't run, and the pane crossfades.
        Motion.crossfade(scrollView.layer, duration: Motion.arrive)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.beginUpdates()
            if !change.removed.isEmpty {
                tableView.removeRows(at: change.removed, withAnimation: [])
            }
            tableView.insertRows(at: change.inserted, withAnimation: [])
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
            showsCursor = false
        }
    }

    // MARK: Layout

    @objc private func clipViewFrameDidChange(_ notification: Notification) {
        scheduleRelayout()
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        let x = max(scrollView.contentView.bounds.origin.x, 0)
        guard x != textScrollX else {
            return
        }
        textScrollX = x
        redrawVisibleRows()
    }

    /// The look changed: the code font's metrics, the colors, and the rows'
    /// heights follow it.
    @objc private func lookDidChange(_ notification: Notification) {
        font = DiffFontMetrics(fontSize: font.fontSize)
        tableView.rowHeight = font.lineHeight
        tableView.backgroundColor = Palette.background
        scrollView.backgroundColor = Palette.background
        textCache.reset()
        conflictButtonTitleWidths.removeAll()
        relayout(force: true, reload: true)
    }

    @objc private func displayOptionsDidChange(_ notification: Notification) {
        increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        textCache.reset()
        redrawVisibleRows()
    }

    /// Recomputes heights for the new width: at once for small documents,
    /// during live resize too, and coalesced for large ones.
    func scheduleRelayout() {
        let width = scrollView.contentView.bounds.width
        guard width != layoutWidth else {
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

    /// Live resize ended: wrap for the final width at once, without waiting
    /// for a large document's coalesced relayout.
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
            font: font,
            oneNumber: document.isWorkingFile
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
        updateDocumentWidth()
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
    /// the line's visual lines (the taller half, split).
    private func computeRowHeights(wraps: Bool) {
        let lineHeight = font.lineHeight
        let columnsBefore = geometry.columnsPerLine(.before)
        let columnsAfter = geometry.columnsPerLine(.after)
        var heights = [CGFloat](repeating: lineHeight, count: document.rowCount)
        var widest = 0
        for (index, row) in document.rows.enumerated() {
            switch row.kind {
            case .hunk, .noNewline:
                continue
            case .conflictHeader:
                heights[index] = DiffTableMetrics.conflictHeaderHeight(lineHeight: lineHeight)
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

    /// While lines don't wrap, makes the table wider than the pane by as
    /// much as the longest line overflows its side (and two characters
    /// more), so the scroll view shows its horizontal scroller; otherwise
    /// as wide as the pane.
    private func updateDocumentWidth() {
        guard let column = tableView.tableColumns.first else {
            return
        }
        let clipWidth = scrollView.contentView.bounds.width
        let text = geometry.half(.before).text
        let overflow = (shownContent?.wrapsLines ?? true)
            ? 0
            : max(maximumTextWidth - (text.upperBound - text.lowerBound) + font.characterWidth * 2, 0)
        let minimum = overflow > 0 ? (clipWidth + overflow).rounded(.up) : 0
        guard column.minWidth != minimum else {
            return
        }
        // A table that resizes its column keeps itself as wide as the pane,
        // so one wider than the pane doesn't. A wider column takes its width
        // before its minimum (a minimum above the column's width leaves the
        // table's geometry at the old width), a narrower one after (the old
        // minimum would hold the width up).
        tableView.columnAutoresizingStyle = overflow > 0 ? .noColumnAutoresizing : .uniformColumnAutoresizingStyle
        if minimum > column.minWidth {
            column.width = max(minimum, clipWidth)
            column.minWidth = minimum
        } else {
            column.minWidth = minimum
            column.width = max(minimum, clipWidth)
        }
        if overflow == 0, tableView.frame.width != clipWidth {
            tableView.setFrameSize(NSSize(width: clipWidth, height: tableView.frame.height))
        }
        tableView.sizeLastColumnToFit()
        tableView.tile()
        let maximumScroll = max(tableView.frame.width - clipWidth, 0)
        if scrollView.contentView.bounds.origin.x > maximumScroll {
            scrollText(toX: maximumScroll)
        }
    }

    /// Scrolls up or down just enough to show a row, keeping the sideways
    /// scroll.
    func scrollRowIntoView(_ row: Int) {
        guard document.rows.indices.contains(row) else {
            return
        }
        let rect = tableView.rect(ofRow: row)
        let visible = tableView.visibleRect
        tableView.scrollToVisible(CGRect(x: visible.minX, y: rect.minY, width: visible.width, height: rect.height))
    }

    /// Scrolls the text sideways by `delta` points.
    func scrollText(by delta: CGFloat) {
        guard shownContent?.wrapsLines == false else {
            return
        }
        scrollText(toX: scrollView.contentView.bounds.origin.x + delta)
    }

    /// Scrolls the text sideways to `x`, within the table.
    private func scrollText(toX x: CGFloat) {
        let clip = scrollView.contentView
        let maximum = max(tableView.frame.width - clip.bounds.width, 0)
        let target = min(max(x, 0), maximum)
        guard target != clip.bounds.origin.x else {
            return
        }
        clip.scroll(to: CGPoint(x: target, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
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

    /// The rows on screen whose staging marks differ between two stagings,
    /// and the new staging's inclusions of the hunks on screen.
    private struct InclusionChange {
        var rows: [Int] = []
        /// By header row, as `hunkInclusions` keeps them.
        var hunkInclusions: [Int: DiffSelectionType?] = [:]
    }

    /// The rows on screen whose staging marks differ between `old`, the
    /// shown staging, and `new` (a line's number cells, a hunk's checkbox);
    /// none when motion doesn't run.
    private func rowsChangingInclusion(from old: StagingState?, to new: StagingState?) -> InclusionChange {
        guard let old, let new, Motion.animates(tableView) else {
            return InclusionChange()
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        var change = InclusionChange()
        for row in visible.location..<(visible.location + visible.length) where document.rows.indices.contains(row) {
            let documentRow = document.rows[row]
            if documentRow.kind == .hunk {
                let hunk = document.hunks[Int(documentRow.hunk)]
                let newInclusion = inclusion(ofHunk: hunk, in: new.selection)
                change.hunkInclusions[hunk.row] = .some(newInclusion)
                // The shown staging's, from the cache.
                if inclusion(ofHunk: hunk) != newInclusion {
                    change.rows.append(row)
                }
                continue
            }
            for column in [DiffColumn.before, .after] {
                guard let line = documentRow.line(column), document.lines[line].isChange else {
                    continue
                }
                let number = document.lines[line].diffLineNumber
                if number >= 0, old.selection.isSelected(number) != new.selection.isSelected(number) {
                    change.rows.append(row)
                    break
                }
            }
        }
        return change
    }

    /// Crossfades `rows`' next drawing over `duration` (a transition on
    /// each row's layer, only for rows on screen).
    func crossfade(rows: [Int], duration: TimeInterval) {
        for row in rows {
            guard let view = tableView.rowView(atRow: row, makeIfNecessary: false) else {
                continue
            }
            Motion.crossfade(view.layer, duration: duration)
            view.needsDisplay = true
        }
    }

    /// The rows the pointer's hover draws on: a block (its handle and
    /// numbers), a line's numbers, a hunk header's button, a conflict
    /// block's button.
    private func hoverRows(block: Int?, line: Int?, buttonHunk: Int?, conflictHeader: Int? = nil) -> [Int] {
        var rows: [Int] = []
        if let conflictHeader, document.conflictHeaders.indices.contains(conflictHeader) {
            rows.append(document.conflictHeaders[conflictHeader].row)
        }
        if let block, document.blocks.indices.contains(block) {
            rows.append(contentsOf: document.blocks[block].rows)
        }
        if let line, document.rows.indices.contains(line) {
            rows.append(line)
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

    /// Each hunk's inclusion in the shown staging's selection, by its
    /// header's row. A header draws it every time it draws, and working it
    /// out walks the hunk's lines, so it's kept until the document or the
    /// staging changes.
    private var hunkInclusions: [Int: DiffSelectionType?] = [:]

    /// How much of a hunk the commit includes.
    func inclusion(ofHunk hunk: DocumentHunk) -> DiffSelectionType? {
        guard let staging = shownContent?.staging else {
            return nil
        }
        if let cached = hunkInclusions[hunk.row] {
            return cached
        }
        let computed = inclusion(ofHunk: hunk, in: staging.selection)
        hunkInclusions[hunk.row] = .some(computed)
        return computed
    }

    /// How much of a hunk `selection` includes.
    private func inclusion(ofHunk hunk: DocumentHunk, in selection: DiffSelection) -> DiffSelectionType? {
        var lines = Set<Int>()
        for row in hunk.rows where document.rows[row].isChange {
            for column in [DiffColumn.before, .after] {
                if let line = document.rows[row].line(column), document.lines[line].isChange, document.lines[line].diffLineNumber >= 0 {
                    lines.insert(line)
                }
            }
        }
        return hunkInclusion(ofChangedLines: lines.map { document.lines[$0].diffLineNumber }, in: selection)
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
        // Rows draw from the pane's left edge, however far the table is
        // scrolled sideways.
        let x = point.x - textScrollX
        if documentRow.kind == .conflictHeader {
            let header = Int(documentRow.block)
            if let button = conflictButtonRect(ofRow: row, rowHeight: rect.height),
               button.contains(CGPoint(x: x, y: point.y - rect.minY)) {
                return .conflictButton(header: header)
            }
            return .conflictHeader(header: header)
        }
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
               x >= geometry.hunkGutter.upperBound, x < checkbox.upperBound + DiffTableMetrics.textInset {
                return .hunkCheckbox(hunk: hunk)
            }
            return .hunkHeader(hunk: hunk)
        }
        if documentRow.kind == .noNewline {
            return .none
        }
        if let handle = geometry.handleHitArea, handle.contains(x), documentRow.block >= 0 {
            return .handle(row: row, block: Int(documentRow.block))
        }
        let side = geometry.column(atX: x)
        let half = geometry.half(side)
        // The gutter is left of the marker, but a split diff's old half,
        // turned around while lines can be staged, has it on its right.
        let isInGutter = document.isSplit && side == .before && geometry.handle != nil
            ? x >= half.gutter.lowerBound
            : x < half.marker.lowerBound
        if isInGutter {
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
        let textColumn = geometry.textColumn(atX: point.x - textScrollX, side: column, scrollX: textScrollX)
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
        case .conflictButton(let header):
            guard canChooseConflictSide(header: header) else {
                return .none
            }
            pressedConflictButton = header
            redrawVisibleRows()
            return .conflictButton(header)
        case .hunkCheckbox(let hunk):
            guard !isBuilding, let range = document.hunks[hunk].changedDiffLines else {
                return .none
            }
            if showWhitespaceHintIfNeeded(at: point) {
                return .none
            }
            guard let staging = shownContent?.staging, staging.canSelectLines else {
                return .none
            }
            actions.staging?.toggleLines(.range(range), staging.diffGeneration)
            return .none
        case .handle(_, let block):
            guard !isBuilding else {
                return .none
            }
            if showWhitespaceHintIfNeeded(at: point) {
                return .none
            }
            guard let staging = shownContent?.staging, staging.canSelectLines else {
                return .none
            }
            actions.staging?.toggleLines(.block(containing: document.blocks[block].diffLines.lowerBound), staging.diffGeneration)
            return .none
        case .gutter(let row, let column):
            guard shownContent?.staging != nil else {
                return beginCursorClick(row: row)
            }
            guard !isBuilding else {
                return .none
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
            // The cursor moves here for the keyboard to go on from, but a
            // click in the text selects text: it doesn't show.
            setCursor(row: row, extending: false, shows: false)
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
        case .hunkHeader, .conflictHeader, .none:
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
            let column = document.isSplit ? geometry.column(atX: point.x - textScrollX) : current.column
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
                let x = point.x - textScrollX
                if x > text.upperBound {
                    scrollText(by: font.characterWidth)
                } else if x < text.lowerBound, textScrollX > 0 {
                    scrollText(by: -font.characterWidth)
                }
            }
            selection.head = position
            textSelection = selection
        case .conflictButton(let header):
            // Pressed while the pointer stays on the button: the press
            // shows at once and eases back as the pointer leaves.
            let pressed: Int? = hit(at: point) == .conflictButton(header: header) ? header : nil
            if pressed != pressedConflictButton {
                pressedConflictButton = pressed
                redrawVisibleRows()
                if pressed == nil {
                    easePressBack(conflictHeader: header)
                }
            }
        case .none:
            break
        }
    }

    /// The mouse went up: a gutter drag applies its lines; a conflict
    /// block's button, still pressed, keeps its side (the buttons wait at
    /// once), else its press eases back.
    func mouseUp(drag: DiffDrag) {
        if case .conflictButton(let header) = drag {
            let isPressed = pressedConflictButton == header
            pressedConflictButton = nil
            redrawVisibleRows()
            if isPressed {
                chooseConflictSide(header: header)
                if pendingConflictChoice != header {
                    easePressBack(conflictHeader: header)
                }
            }
            return
        }
        guard case .gutter = drag, let gutterDrag else {
            return
        }
        self.gutterDrag = nil
        let lower = min(gutterDrag.from, gutterDrag.to)
        let upper = max(gutterDrag.from, gutterDrag.to)
        let lines: DiffLines = lower == upper ? .line(lower) : .range(lower...upper)
        if let staging = shownContent?.staging {
            actions.staging?.setLines(lines, gutterDrag.include, staging.diffGeneration)
        }
        redrawVisibleRows()
    }

    /// The pointer moved: updates the hovered block, line, and button.
    func mouseMoved(to point: CGPoint?) {
        var block: Int?
        var line: (row: Int, column: DiffColumn)?
        var button: (hunk: Int, button: DiffHunkButton)?
        var conflictButton: Int?
        var tooltip: String?
        if let point {
            switch hit(at: point) {
            case .handle(_, let hovered):
                block = hovered
            case .gutter(let row, let column):
                line = (row, column)
            case .expansion(let hunk, let kind):
                button = (hunk, kind)
                tooltip = kind.title
            case .conflictButton(let header):
                conflictButton = header
            default:
                break
            }
        }
        if shownContent?.staging == nil || gutterDrag != nil {
            block = nil
            line = nil
        }
        let changed = block != hoveredBlock || line?.row != hoveredLine?.row || line?.column != hoveredLine?.column
            || button?.hunk != hoveredButton?.hunk || button?.button != hoveredButton?.button
            || conflictButton != hoveredConflictButton
        // The gutter's and a button's hover fade out over 0.15 s and in
        // over 0.08 s.
        let fadesHover = changed && Motion.animates(tableView)
        let leaving = fadesHover
            ? hoverRows(block: hoveredBlock, line: hoveredLine?.row, buttonHunk: hoveredButton?.hunk, conflictHeader: hoveredConflictButton)
            : []
        hoveredBlock = block
        hoveredLine = line
        hoveredButton = button
        hoveredConflictButton = conflictButton
        tableView.setTooltip(tooltip)
        if changed {
            redrawVisibleRows()
        }
        if fadesHover {
            crossfade(rows: leaving, duration: Motion.hoverOut)
            crossfade(rows: hoverRows(block: block, line: line?.row, buttonHunk: button?.hunk, conflictHeader: conflictButton), duration: Motion.hoverIn)
        }
    }

    /// Finds what's under the pointer again: the rows changed under a
    /// pointer that didn't move.
    private func refreshHover() {
        guard let window = tableView.window else {
            return
        }
        let point = tableView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        mouseMoved(to: tableView.visibleRect.contains(point) ? point : nil)
    }

    /// Whether the cursor over a point is an I-beam (text).
    func showsTextCursor(at point: CGPoint) -> Bool {
        if case .text = hit(at: point) {
            return true
        }
        return false
    }

    // MARK: Conflict blocks

    /// Where a conflict block header's button is in its row (from the
    /// pane's left edge, the row's top): a small capsule at the trailing
    /// edge, centered; nil for a header without one.
    func conflictButtonRect(ofRow row: Int, rowHeight: CGFloat) -> CGRect? {
        guard let header = document.conflictHeader(ofRow: row),
              let title = shownContent?.conflicts?.side(header.side)?.buttonTitle
        else {
            return nil
        }
        let width = conflictButtonTitleWidth(title) + 2 * Metrics.ControlHeight.horizontalPadding(for: .small)
        let height = Metrics.ControlHeight.small
        return CGRect(
            x: (geometry.width - DiffTableMetrics.trailingInset - width).rounded(),
            y: ((rowHeight - height) / 2).rounded(),
            width: width,
            height: height
        )
    }

    /// A conflict block button's title width, measured once per title.
    private func conflictButtonTitleWidth(_ title: String) -> CGFloat {
        if let width = conflictButtonTitleWidths[title] {
            return width
        }
        let width = ceil(NSAttributedString(string: title, attributes: [.font: AppKitTypography.smallButton]).size().width)
        conflictButtonTitleWidths[title] = width
        return width
    }

    /// Whether a conflict block's button takes a click now: the diff shown
    /// is the file's, its rows are built, and no other side is being kept.
    func canChooseConflictSide(header: Int) -> Bool {
        guard shownContent?.isInteractive == true, !isBuilding, pendingConflictChoice == nil,
              actions.chooseConflictSide != nil, document.conflictHeaders.indices.contains(header)
        else {
            return false
        }
        let side = document.conflictHeaders[header].side
        return shownContent?.conflicts?.side(side)?.buttonTitle != nil
    }

    /// Keeps the side of a conflict block's header (its button): the
    /// buttons wait until the file shows again, or the choice fails.
    func chooseConflictSide(header: Int) {
        guard canChooseConflictSide(header: header), let file = shownContent?.conflicts?.file,
              let choose = actions.chooseConflictSide
        else {
            return
        }
        let documentHeader = document.conflictHeaders[header]
        let side: ManualConflictResolution
        switch documentHeader.side {
        case .ours: side = .ours
        case .theirs: side = .theirs
        case .base, .marker: return
        }
        pendingConflictChoice = header
        redrawVisibleRows()
        conflictChoiceTask = Task { [weak self] in
            let chosen = await choose(file, documentHeader.conflict, side)
            guard let self, !chosen, self.pendingConflictChoice == header else {
                return
            }
            self.pendingConflictChoice = nil
            self.redrawVisibleRows()
        }
    }

    /// A conflict block button's press eases back over 0.15 s (the
    /// header's row crossfading), unless motion doesn't run.
    private func easePressBack(conflictHeader header: Int) {
        guard Motion.animates(tableView) else {
            return
        }
        crossfade(rows: hoverRows(block: nil, line: nil, buttonHunk: nil, conflictHeader: header), duration: Motion.pressRelease)
    }

    /// Waits for the side being kept, if any (for tests).
    func conflictChoiceIdle() async {
        await conflictChoiceTask?.value
    }

    // MARK: Expansion

    private func expand(hunk: Int, button: DiffHunkButton) {
        guard !isBuilding else {
            return
        }
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
        let popover = PopoverController(title: "Show whitespace changes?") { [weak self] in
            WhitespaceHintView(
                onCancel: {
                    self?.whitespaceHint?.close()
                },
                onShow: {
                    self?.whitespaceHint?.close()
                    self?.actions.staging?.showWhitespaceChanges()
                }
            )
        }
        let anchor = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
        popover.show(relativeTo: anchor, of: tableView, edge: .trailing)
        whitespaceHint = popover
    }

    // MARK: Keyboard

    /// Moves the line cursor to `row` (extending the range with Shift),
    /// showing it or not.
    func setCursor(row: Int, extending: Bool, shows: Bool = true) {
        guard document.rows.indices.contains(row) else {
            return
        }
        if extending, let cursor {
            self.cursor = (cursor.anchor, row)
        } else {
            cursor = (row, row)
        }
        let wasShown = showsCursor
        showsCursor = shows
        guard shows else {
            if wasShown {
                redrawVisibleRows()
            }
            return
        }
        scrollRowIntoView(row)
        redrawVisibleRows()
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) {
            NSAccessibility.post(element: rowView, notification: .focusedUIElementChanged)
        }
    }

    /// The rows under the cursor, while it shows.
    var cursorRows: ClosedRange<Int>? {
        guard showsCursor, let cursor else {
            return nil
        }
        return min(cursor.anchor, cursor.head)...max(cursor.anchor, cursor.head)
    }

    /// The row the cursor moves from, while it shows.
    var cursorHead: Int? {
        showsCursor ? cursor?.head : nil
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
            guard shownContent?.isInteractive == true, !isBuilding else {
                return true
            }
            if option {
                toggleCursorBlock()
            } else {
                toggleCursorLines()
            }
            return true
        case 0x1B:
            // Escape closes find (selecting its current match), else
            // clears the selection.
            if find.isShown {
                find.close()
            } else {
                textSelection = nil
            }
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
        scrollRowIntoView(target)
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
            showWhitespaceHint(at: CGPoint(x: geometry.before.gutter.upperBound + textScrollX, y: rect.midY))
            return
        }
        guard staging.canSelectLines else {
            return
        }
        let numbers = rows.flatMap { document.diffLines(ofRow: $0) }
        guard let first = numbers.min(), let last = numbers.max() else {
            return
        }
        actions.staging?.toggleLines(first == last ? .line(first) : .range(first...last), staging.diffGeneration)
    }

    /// Option-Space: toggles the block under the cursor.
    private func toggleCursorBlock() {
        guard showsCursor, let row = cursor?.head, let block = document.block(ofRow: row), let staging = shownContent?.staging else {
            return
        }
        if staging.hidesWhitespace {
            let rect = tableView.rect(ofRow: row)
            showWhitespaceHint(at: CGPoint(x: geometry.before.gutter.upperBound + textScrollX, y: rect.midY))
            return
        }
        guard staging.canSelectLines else {
            return
        }
        actions.staging?.toggleLines(.block(containing: block.diffLines.lowerBound), staging.diffGeneration)
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
    func menuContent(at point: CGPoint) -> MenuContent? {
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
            guard !isBuilding, staging.canDiscard || staging.hidesWhitespace else {
                return nil
            }
            if staging.hidesWhitespace {
                showWhitespaceHint(at: point)
                return nil
            }
            guard let line = document.changedLine(ofRow: row, column: column) else {
                return nil
            }
            return discardMenu(.line(document.lines[line].diffLineNumber), generation: staging.diffGeneration)
        case .handle(_, let block):
            guard !isBuilding, let staging = shownContent?.staging, staging.canDiscard || staging.hidesWhitespace else {
                return nil
            }
            if staging.hidesWhitespace {
                showWhitespaceHint(at: point)
                return nil
            }
            return discardMenu(.block(containing: document.blocks[block].diffLines.lowerBound), generation: staging.diffGeneration)
        case .expansion, .hunkHeader, .hunkCheckbox:
            return expansionMenuAction().map { $0.menuContent }
        case .text, .inertGutter, .conflictButton, .conflictHeader, .none:
            return textMenu()
        }
    }

    /// Where the menu of `row`'s text opens (⇧F10, VoiceOver's Show Menu):
    /// the start of its text, on the first side.
    func textMenuPoint(ofRow row: Int) -> CGPoint? {
        guard row >= 0, row < tableView.numberOfRows else {
            return nil
        }
        let rect = tableView.rect(ofRow: row)
        return CGPoint(x: textScrollX + geometry.before.text.lowerBound, y: rect.midY)
    }

    /// Discards `lines` of the diff of `generation`, asking first; the file
    /// shows again without them (`documentCrossfade`).
    func discard(_ lines: DiffLines, generation: Int) {
        guard let discardLines = actions.staging?.discardLines else {
            return
        }
        discardRequests &+= 1
        let request = discardRequests
        pendingDiscard = request
        Task { [weak self] in
            let discarded = await discardLines(lines, generation)
            guard let self, !discarded, self.pendingDiscard == request else {
                return
            }
            self.pendingDiscard = nil
        }
    }

    /// The menu discarding `lines` of the diff of `generation`.
    private func discardMenu(_ lines: DiffLines, generation: Int) -> MenuContent? {
        guard let title = actions.staging?.discardTitle(lines, generation) else {
            return nil
        }
        return MenuContent {
            MenuAction(title) { [weak self] in
                self?.discard(lines, generation: generation)
            }
        }
    }

    private func textMenu() -> MenuContent {
        MenuContent {
            MenuAction("Copy") { [weak self] in
                self?.copySelection()
            }
            .disabled(!canCopy)
            MenuAction("Select All") { [weak self] in
                self?.selectAll()
            }
            if let expansion = expansionMenuAction() {
                MenuDivider()
                expansion
            }
        }
    }

    /// "Expand Whole File", or "Collapse Expanded Lines" once expanded.
    func expansionMenuAction() -> MenuAction? {
        guard let content = shownContent, content.canExpand || content.hasExpandedLines else {
            return nil
        }
        if content.hasExpandedLines {
            return MenuAction("Collapse Expanded Lines") { [weak self] in
                self?.actions.collapseExpandedLines()
            }
        }
        return MenuAction("Expand Whole File") { [weak self] in
            self?.actions.expandWholeFile()
        }
        .disabled(!canExpandWholeFile)
    }
}

/// How much of a hunk `selection` includes, given the original diff's
/// indexes of the hunk's changed lines: nil for a hunk with none.
nonisolated func hunkInclusion(ofChangedLines lines: [Int], in selection: DiffSelection) -> DiffSelectionType? {
    guard !lines.isEmpty else {
        return nil
    }
    let selected = lines.count(where: { selection.isSelected($0) })
    if selected == lines.count {
        return .all
    }
    return selected == 0 ? DiffSelectionType.none : .partial
}

/// How a mouse drag is tracked.
enum DiffDrag: Equatable {
    case none
    /// Down the gutter, including or excluding lines.
    case gutter
    /// Selecting text on a side.
    case text(DiffColumn)
    /// Pressing a conflict block's button (its header's index).
    case conflictButton(Int)
}
