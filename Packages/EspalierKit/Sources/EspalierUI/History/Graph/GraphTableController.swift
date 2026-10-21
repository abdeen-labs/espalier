// The history graph's table: a view-based `NSTableView` with fixed row
// heights that draws the graph row by row, applies pages incrementally (a
// page appends rows, and the provisional rows the layout relaid redraw),
// keeps the row under the pointer in place across reloads, prefetches 300
// rows ahead, and syncs its selection with the history model's.

import AppKit
import EspalierCore
import EspalierSupport
import GitKit
import UniformTypeIdentifiers
import os

/// The history graph's table: its data source, delegate, and the state
/// behind it.
final class GraphTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Prefetch starts when the last visible row is this close to the end.
    static let prefetchDistance = 300

    let tableView: GraphNSTableView
    let scrollView: NSScrollView

    /// The history the table shows.
    private(set) weak var source: (HistoryModel)?
    /// What the table asks of its screen.
    var actions = GraphTableActions()
    /// Where avatars come from (monograms when nil).
    var avatarLoader: (any AvatarLoading)?
    /// How dates show.
    var dateFormatting = DateTimeFormatting() {
        didSet {
            guard dateFormatting != oldValue else {
                return
            }
            dates = DateTextCache(capacity: dates.capacity)
            reconfigureVisibleRows()
        }
    }

    var timeZone = TimeZone.current {
        didSet {
            if timeZone != oldValue {
                dates = DateTextCache(capacity: dates.capacity)
            }
        }
    }

    /// How counts show.
    var numberFormat = defaultNumberFormat {
        didSet {
            if numberFormat != oldValue {
                reconfigureVisibleRows()
            }
        }
    }

    // MARK: What the table shows

    private(set) var presentation = GraphPresentation()
    /// The graph rows the table knows (the footer isn't one).
    private(set) var shownRowCount = 0
    /// How many of them were stable when shown.
    private var shownStableRowCount = 0
    private var appliedGeneration: UInt64?
    private var appliedReloadGeneration: UInt64?
    /// The "Loading older commits…" row after the last commit.
    private(set) var showsFooter = false
    /// The most lanes any row has needed: the column never shrinks.
    private var lanesSeen = 1
    private(set) var style: GraphRowStyle
    private var isIncreasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    private var differentiatesWithoutColor = NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor

    // MARK: Selection

    /// Set while the table's selection is changed to match the model's, so
    /// the change isn't sent back.
    private var isApplyingSelection = false
    /// The selection last sent to or taken from the model.
    private var lastSelection = GraphSelection()

    // MARK: Emphasis

    /// The track the pointer rests on (after the hover dwell).
    private(set) var hoveredTrack: Int?
    /// The row whose node is outlined: a hovered stub's other end.
    private(set) var outlinedRow: Int?
    /// The keyboard reorder's insertion point (a row; the row count for
    /// after the last).
    private(set) var reorderInsertionRow: Int?
    private var dropFeedbackRow: Int?
    /// The rows a stub's other end is loading for (a spinner at the stub).
    private var loadingStubRow: Int?

    // MARK: Caches and timers

    private var dates = DateTextCache(capacity: 2_000)
    private var minuteTimer: Timer?
    private var hoverTimer: Timer?
    /// Watches for the end of a drag of commits (see `watchDragEnd`).
    private var dragEndTimer: Timer?
    private var pendingHover: (track: Int?, outline: Int?)?
    /// The history's first page: from showing to painted (`HistoryFirstPage`).
    private var firstPageInterval: OSSignpostIntervalState?
    /// The next reload is of another history: it starts at the top.
    private var isNewSource = false
    private var firstPageStart: ContinuousClock.Instant?
    /// How long the first page took to paint, once it has.
    private(set) var firstPageDuration: Duration?
    /// When set, how long each row's configuration and each page's apply
    /// takes (the performance tests and the benchmark).
    var measurements: GraphTableMeasurements?

    override init() {
        let table = GraphNSTableView(frame: .zero)
        tableView = table
        scrollView = UnbouncedScrollView()
        let palette = TrackPalette.Resolved()
        style = GraphRowStyle(
            geometry: GraphGeometry(laneCount: 1, increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast),
            colors: GraphColors(palette: palette, appearance: NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!),
            palette: palette,
            avatars: nil,
            monograms: MonogramCache(),
            scale: 2
        )
        super.init()
        configureTable()
        observeSystem()
        startMinuteTimer()
        tableView.setAccessibilityCustomRotors(GraphAccessibility.rotors(for: self))
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Commit"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // Rows draw their own selection, in the row's rounded shape
        // (`GraphRowView`).
        tableView.style = .plain
        tableView.focusRingType = .none
        tableView.rowHeight = Metrics.Graph.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = Palette.background
        tableView.draggingDestinationFeedbackStyle = .none
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([], forLocal: false)
        tableView.registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.espalierCommits.identifier)])
        tableView.setAccessibilityLabel("Commits")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.controller = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.background
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(willStartLiveScroll(_:)), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(didEndLiveScroll(_:)), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    private func observeSystem() {
        NotificationCenter.default.addObserver(self, selector: #selector(systemColorsDidChange(_:)), name: NSColor.systemColorsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(lookDidChange(_:)), name: Look.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    isolated deinit {
        minuteTimer?.invalidate()
        hoverTimer?.invalidate()
        dragEndTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: Updating

    /// Shows `source`'s rows with `presentation`, `selection` selected, and
    /// a keyboard reorder's insertion point, applying only what changed.
    func update(source: HistoryModel, presentation: GraphPresentation, selection: GraphSelection, reorderInsertionRow: Int?) {
        if self.source !== source {
            // Another repository's history: from the top.
            self.source = source
            appliedGeneration = nil
            appliedReloadGeneration = nil
            lastSelection = GraphSelection()
            lanesSeen = 1
            isNewSource = true
            beginFirstPage()
        }
        let presentationChanged = presentation != self.presentation
        self.presentation = presentation
        let reloaded = applyGraphChange()
        // After the rows: a page can bring a branch's commit, whose line
        // then takes the branch's color.
        let colorsChanged = updateTrackColors()
        if colorsChanged || (presentationChanged && !reloaded) {
            reconfigureVisibleRows()
        }
        updateFooter()
        syncSelection(selection)
        setReorderInsertionRow(reorderInsertionRow)
        recordAnchor()
    }

    /// Applies the history's last change: a reload, or appended pages.
    /// Returns whether every row was reloaded.
    @discardableResult
    private func applyGraphChange() -> Bool {
        guard let source else {
            return false
        }
        let change = source.graphChange
        guard change.generation != appliedGeneration else {
            return false
        }
        let graph = source.graph
        defer {
            appliedGeneration = change.generation
            appliedReloadGeneration = change.reloadGeneration
        }
        if change.reloadGeneration != appliedReloadGeneration || graph.count < shownRowCount {
            reloadAll(graph)
            return true
        }
        // Pages appended since the rows were last shown (changes can
        // coalesce): new rows, and the provisional rows they relaid.
        let interval = UISignposts.begin(.historyPageApply)
        let start = measurements == nil ? nil : ContinuousClock.now
        defer {
            UISignposts.end(.historyPageApply, interval)
            if let start {
                measurements?.pageApplies.append(.now - start)
            }
        }
        let oldCount = shownRowCount
        let relaidStart = shownStableRowCount
        shownRowCount = graph.count
        shownStableRowCount = graph.stableRowCount
        let widened = noteLanes(graph.laneCount)
        if shownRowCount != oldCount {
            tableView.noteNumberOfRowsChanged()
        }
        // The footer's row is a commit's now; the provisional rows draw
        // again, and the row above them, whose line may bend into a node
        // below it now.
        var redraw = IndexSet(integersIn: max(relaidStart - 1, 0)..<oldCount)
        if showsFooter {
            redraw.insert(oldCount)
        }
        if widened {
            reconfigureVisibleRows()
        } else {
            reconfigure(rows: redraw)
        }
        prefetchIfNeeded()
        return false
    }

    /// Reloads every row, keeping the row at the top of the view where it
    /// is (unless the view was at the top, where it stays).
    private func reloadAll(_ graph: CommitGraphLayout) {
        // The source holds the new rows already: the anchor is the one
        // recorded while the old rows showed.
        let anchor = isNewSource ? Anchor(sha: nil, offset: 0, isAtTop: true) : shownAnchor
        let wasNewSource = isNewSource
        isNewSource = false
        // A commit made while the top shows slides in under the working
        // copy.
        if !wasNewSource, anchor?.isAtTop == true, let added = commitsAddedUnderWorkingCopy(graph) {
            slideIn(added, graph: graph)
            return
        }
        shownRowCount = graph.count
        shownStableRowCount = graph.stableRowCount
        if !noteLanes(graph.laneCount), lanesSeen == 1 {
            style.geometry = GraphGeometry(rowHeight: tableView.rowHeight, laneCount: 1, increaseContrast: isIncreasedContrast)
        }
        outlinedRow = nil
        // The table keeps its selected rows, which may name other commits
        // now: `syncSelection` selects the model's again, without scrolling
        // unless the model's selection changed.
        isApplyingSelection = true
        tableView.reloadData()
        isApplyingSelection = false
        restoreAnchor(anchor)
    }

    /// How many commits now sit between the working copy and the commit
    /// that was first under it, when that's a few (a commit, an amend's
    /// replacement): nil otherwise.
    private func commitsAddedUnderWorkingCopy(_ graph: CommitGraphLayout) -> Int? {
        guard graph.hasUncommittedWorkRow, let source, let first = shownFirstCommitSHA, let row = source.row(of: first) else {
            return nil
        }
        let added = row - 1
        let dropped = shownRowCount + added - graph.count
        guard (1...3).contains(added), dropped >= 0, dropped <= shownRowCount - 1 else {
            return nil
        }
        return added
    }

    /// Inserts `added` rows under the working copy sliding down (0.22 s on
    /// the motion curve; at once with Reduce Motion), dropping as many rows
    /// at the end as the history did, then redraws what's visible.
    private func slideIn(_ added: Int, graph: CommitGraphLayout) {
        let oldCount = shownRowCount
        let dropped = oldCount + added - graph.count
        shownRowCount = graph.count
        shownStableRowCount = graph.stableRowCount
        noteLanes(graph.laneCount)
        isApplyingSelection = true
        Motion.run(Motion.arrive, in: tableView) { animates in
            tableView.beginUpdates()
            if dropped > 0 {
                tableView.removeRows(at: IndexSet((oldCount - dropped)..<oldCount), withAnimation: [])
            }
            tableView.insertRows(at: IndexSet(1..<(1 + added)), withAnimation: animates ? .slideDown : [])
            tableView.endUpdates()
        }
        isApplyingSelection = false
        reconfigureVisibleRows()
    }

    /// The commit in the first commit row, as last shown.
    private var shownFirstCommitSHA: String?

    /// Widens the column when rows need more lanes than seen so far.
    /// Returns whether the geometry changed.
    @discardableResult
    private func noteLanes(_ laneCount: Int) -> Bool {
        guard laneCount > lanesSeen else {
            return false
        }
        lanesSeen = laneCount
        style.geometry = GraphGeometry(rowHeight: tableView.rowHeight, laneCount: lanesSeen, increaseContrast: isIncreasedContrast)
        return true
    }

    // MARK: Anchoring

    private struct Anchor {
        /// The commit in the first visible row; nil for the working copy.
        var sha: String?
        /// Its row's top relative to the view's top.
        var offset: CGFloat
        /// The view was scrolled to the top.
        var isAtTop: Bool
    }

    /// The row at the top of the view as last shown, recorded when the view
    /// scrolls or its rows change.
    private var shownAnchor: Anchor?

    private func recordAnchor() {
        shownAnchor = captureAnchor()
        if let source, shownRowCount > 0 {
            shownFirstCommitSHA = source.commit(atRow: CommitRows(source.graph).firstRow)?.sha
        } else {
            shownFirstCommitSHA = nil
        }
    }

    private func captureAnchor() -> Anchor? {
        guard shownRowCount > 0, let source else {
            return nil
        }
        let visible = tableView.visibleRect
        let rows = tableView.rows(in: visible)
        guard rows.length > 0 else {
            return nil
        }
        let first = rows.location
        let rect = tableView.rect(ofRow: first)
        let isAtTop = first == 0 && rect.minY >= visible.minY - 1
        return Anchor(sha: source.commit(atRow: first)?.sha, offset: rect.minY - visible.minY, isAtTop: isAtTop)
    }

    private func restoreAnchor(_ anchor: Anchor?) {
        guard let anchor, let source, shownRowCount > 0 else {
            return
        }
        if anchor.isAtTop {
            scroll(toY: 0, animated: false)
            return
        }
        guard let sha = anchor.sha, let row = source.row(of: sha), row < shownRowCount else {
            return
        }
        scroll(toY: tableView.rect(ofRow: row).minY - anchor.offset, animated: false)
    }

    /// Scrolls the table so `y` is at the top of the view.
    func scroll(toY y: CGFloat, animated: Bool) {
        let clip = scrollView.contentView
        let maximum = max(tableView.frame.height - clip.bounds.height, 0)
        let target = NSPoint(x: clip.bounds.origin.x, y: min(max(y, 0), maximum))
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.scroll
                context.timingFunction = Motion.scrollTimingFunction
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        shownRowCount + (showsFooter ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row >= shownRowCount {
            let footer = tableView.makeView(withIdentifier: GraphFooterCellView.identifier, owner: self) as? GraphFooterCellView
                ?? GraphFooterCellView(frame: .zero)
            return footer
        }
        let interval = UISignposts.signposter.isEnabled ? UISignposts.begin(.graphRowConfigure) : nil
        let start = measurements == nil ? nil : ContinuousClock.now
        defer {
            if let interval {
                UISignposts.end(.graphRowConfigure, interval)
            }
            if let start {
                measurements?.rowConfigurations.append(.now - start)
            }
        }
        let cell = tableView.makeView(withIdentifier: CommitRowCellView.identifier, owner: self) as? CommitRowCellView
            ?? makeCell()
        configure(cell, row: row)
        return cell
    }

    /// A new row cell, asking this controller for its tooltips and
    /// VoiceOver's value.
    private func makeCell() -> CommitRowCellView {
        let cell = CommitRowCellView(frame: .zero)
        cell.graphView.tooltipProvider = { [weak self] row, stub in
            self?.tooltip(forRow: row, stub: stub)
        }
        cell.accessibilityValueProvider = { [weak self] row in
            guard let self, let source = self.source, row < self.shownRowCount, row < source.graph.count else {
                return nil
            }
            return GraphAccessibility.value(forRow: row, source: source, presentation: self.presentation, numberFormat: self.numberFormat)
        }
        cell.accessibilityActionsProvider = { [weak self] row in
            guard let self, row < self.shownRowCount else {
                return []
            }
            return self.actions.accessibilityActions(row)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = tableView.makeView(withIdentifier: GraphRowView.identifier, owner: self) as? GraphRowView ?? GraphRowView(frame: .zero)
        rowView.dropFeedback = feedback(forRow: row)
        rowView.isContextMenuTarget = self.tableView.contextMenuTarget.isTarget(row)
        return rowView
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        if firstPageInterval != nil, shownRowCount > 0, (source?.commit(atRow: row) != nil || shownRowCount == 1) {
            endFirstPage()
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < shownRowCount
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        source?.commit(atRow: row)?.summary
    }

    /// Configures `cell` for `row`.
    func configure(_ cell: CommitRowCellView, row: Int) {
        // The model may have published fewer rows than the table shows
        // until the next update reloads it: such a row draws nothing.
        guard let source, row < shownRowCount, row < source.graph.count else {
            return
        }
        style.avatars = avatarLoader
        cell.configure(content(forRow: row), drawing: drawing(forRow: row, in: source), emphasis: emphasis(forRow: row), style: style)
    }

    /// Configures the visible rows again (presentation, emphasis, or
    /// geometry changed).
    func reconfigureVisibleRows() {
        reconfigure(rows: IndexSet(integersIn: Range(tableView.rows(in: tableView.visibleRect)) ?? 0..<0))
    }

    private func reconfigure(rows: IndexSet) {
        let visible = Range(tableView.rows(in: tableView.visibleRect)) ?? 0..<0
        for row in rows where visible.contains(row) {
            guard let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else {
                continue
            }
            if let cell = view as? CommitRowCellView, row < shownRowCount {
                configure(cell, row: row)
            } else {
                // A footer that became a commit, or the reverse.
                tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
            }
        }
    }

    // MARK: Row content

    /// What `row` shows besides its graph.
    func content(forRow row: Int) -> CommitRowContent {
        guard let source else {
            return CommitRowContent()
        }
        guard let commit = source.commit(atRow: row) else {
            return .workingCopy(presentation.workingCopy, numberFormat: numberFormat)
        }
        let date = dates.entry(for: commit.sha, date: commit.author.date, now: Date(), formatting: dateFormatting, timeZone: timeZone)
        let track = source.graph[row].track
        let refs = refCapsules(source.refs(at: commit.sha), sha: commit.sha, track: track)
        var unpushed: String?
        if !presentation.hasRemote {
            // Nowhere to push to.
            unpushed = nil
        } else if source.isLocalCommit(commit.sha) {
            unpushed = CommitRowContent.notPushedTooltip
        } else {
            let tags = source.refs(at: commit.sha).filter { $0.kind == .tag && presentation.tagsToPush.contains($0.name) }.count
            if tags > 0 {
                unpushed = tags == 1 ? "This commit has 1 tag to push" : "This commit has \(formatCount(tags, numberFormat)) tags to push"
            }
        }
        return CommitRowContent(
            sha: commit.sha,
            summary: RichText.emojified(commit.summary),
            authorName: commit.author.name,
            authorEmail: commit.author.email,
            date: date.text,
            shortDate: date.short,
            dateTooltip: date.tooltip,
            refs: refs,
            unpushedTooltip: unpushed,
            isDimmed: presentation.search.map { !$0.matches(row: row) } ?? false,
            avatarEndpoint: presentation.avatarEndpoint,
            isMerge: commit.parentSHAs.count > 1,
            isCurrentTip: commit.sha == presentation.headSHA,
            numberFormat: numberFormat
        )
    }

    /// The capsules for a commit's refs (`GraphPresentation.refCapsules`).
    func refCapsules(_ refs: [HistoryRef], sha: String, track: Int) -> [RefCapsuleContent] {
        presentation.refCapsules(refs, sha: sha, track: track)
    }

    /// What `row`'s graph draws.
    func drawing(forRow row: Int, in source: HistoryModel) -> GraphRowDrawing {
        let graph = source.graph
        let headRow = presentation.headSHA.flatMap { source.row(of: $0) }
        return GraphRowDrawing(
            layout: graph,
            row: row,
            isMerge: (source.commit(atRow: row)?.parentSHAs.count ?? 0) > 1,
            headRow: headRow,
            hasHead: presentation.headSHA != nil,
            workingCopyIsDirty: presentation.workingCopy.isDirty
        )
    }

    /// How `row`'s graph is emphasized.
    func emphasis(forRow row: Int) -> GraphEmphasis {
        var emphasis = GraphEmphasis()
        if let hoveredTrack {
            emphasis.emphasizedTrack = hoveredTrack
            emphasis.dimming = Metrics.Graph.hoverDimming
        } else if let focusedTrack {
            emphasis.emphasizedTrack = focusedTrack
            emphasis.dimming = Metrics.Graph.focusDimming
        }
        emphasis.dashesDimmedTracks = differentiatesWithoutColor
        if let search = presentation.search, !search.matches(row: row) {
            emphasis.nodeOpacity = Metrics.Graph.searchDimming
        }
        emphasis.outlinesNode = row == outlinedRow
        emphasis.isLoadingStub = row == loadingStubRow
        return emphasis
    }

    /// The focused commit's track: its line is emphasized.
    private var focusedTrack: Int? {
        guard let sha = presentation.focusedSHA, let source, let row = source.row(of: sha), row < shownRowCount else {
            return nil
        }
        return source.graph[row].track
    }

    // MARK: Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let source else {
            return
        }
        let rows = tableView.selectedRowIndexes.filteredIndexSet { $0 < shownRowCount }
        let hasWorkingCopyRow = source.graph.hasUncommittedWorkRow
        if hasWorkingCopyRow, rows == [0] {
            lastSelection = GraphSelection(shas: [], isWorkingCopy: true)
            actions.selectWorkingCopy()
            return
        }
        let commitRows = rows.filter { !(hasWorkingCopyRow && $0 == 0) }
        let shas = commitRows.compactMap { source.commit(atRow: $0)?.sha }
        lastSelection = GraphSelection(shas: shas, isWorkingCopy: false)
        actions.select(shas, Self.isContiguous(commitRows))
    }

    /// Whether rows (ascending) follow each other without gaps.
    static func isContiguous(_ rows: [Int]) -> Bool {
        zip(rows, rows.dropFirst()).allSatisfy { $1 == $0 + 1 }
    }

    /// Selects in the table what the model has selected. A selection the
    /// model changed (a search match, a jump) scrolls into view; the same
    /// selection after a reload is only reapplied.
    private func syncSelection(_ selection: GraphSelection) {
        guard let source else {
            return
        }
        let rows: IndexSet
        if selection.isWorkingCopy {
            rows = source.graph.hasUncommittedWorkRow && shownRowCount > 0 ? [0] : []
        } else {
            rows = IndexSet(selection.shas.compactMap(source.row(of:)).filter { $0 < shownRowCount })
        }
        let isNew = selection != lastSelection
        lastSelection = selection
        guard rows != tableView.selectedRowIndexes else {
            return
        }
        isApplyingSelection = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isApplyingSelection = false
        if isNew, let first = rows.first {
            tableView.scrollRowToVisible(first)
        }
    }

    // MARK: Revealing rows

    /// Selects `row` and brings it into view: animated when it's within
    /// three screens, at once (and pulsed) when farther.
    func reveal(row: Int, pulse: Bool) {
        guard row < shownRowCount else {
            return
        }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        let visible = tableView.visibleRect
        let rect = tableView.rect(ofRow: row)
        let target = rect.midY - visible.height / 2
        let distance = abs(target - visible.minY)
        let animates = Motion.animates(tableView)
        let isNear = distance <= visible.height * 3
        if !visible.insetBy(dx: 0, dy: tableView.rowHeight).contains(rect) {
            scroll(toY: target, animated: isNear && animates)
        }
        if pulse || !isNear {
            let delay = isNear && animates ? Motion.scroll : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pulseNode(row: row)
            }
        }
    }

    /// Pulses `row`'s node (a still outline with Reduce Motion).
    func pulseNode(row: Int) {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? CommitRowCellView else {
            return
        }
        cell.graphView.pulseNode(reduceMotion: !Motion.animates(tableView))
    }

    // MARK: Hover

    /// The pointer moved over the table: emphasizes the track under it and
    /// outlines a hovered stub's other end, after the hover dwell.
    func pointerMoved(to point: CGPoint) {
        let hit = hitTest(point)
        let track = hit.track
        let outline = hit.stub.flatMap { target(of: $0.edge) }
        let wanted = (track: track, outline: outline)
        if wanted.track == hoveredTrack, wanted.outline == outlinedRow {
            pendingHover = nil
            hoverTimer?.invalidate()
            return
        }
        if track == nil, outline == nil {
            // Leaving the lines clears at once.
            hoverTimer?.invalidate()
            pendingHover = nil
            setHover(track: nil, outline: nil)
            return
        }
        guard pendingHover.map({ $0.track != wanted.track || $0.outline != wanted.outline }) ?? true else {
            return
        }
        pendingHover = wanted
        hoverTimer?.invalidate()
        let dwell = Double(Timing.hoverDwell.components.attoseconds) / 1e18 + Double(Timing.hoverDwell.components.seconds)
        hoverTimer = Timer.scheduledTimer(withTimeInterval: dwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let pending = self.pendingHover else { return }
                self.pendingHover = nil
                self.setHover(track: pending.track, outline: pending.outline)
            }
        }
    }

    /// The pointer left the table.
    func pointerExited() {
        hoverTimer?.invalidate()
        pendingHover = nil
        setHover(track: nil, outline: nil)
    }

    private func setHover(track: Int?, outline: Int?) {
        guard track != hoveredTrack || outline != outlinedRow else {
            return
        }
        hoveredTrack = track
        outlinedRow = outline
        reconfigureVisibleRows()
    }

    /// What's under `point`: the track of the line or node there, and a
    /// stub whose end is there.
    func hitTest(_ point: CGPoint) -> (row: Int?, track: Int?, stub: GraphRenderer.StubTarget?) {
        let row = tableView.row(at: point)
        guard row >= 0, row < shownRowCount, let source, row < source.graph.count else {
            return (nil, nil, nil)
        }
        let rect = tableView.rect(ofRow: row)
        let cellOrigin = tableView.frameOfCell(atColumn: 0, row: row).origin
        let local = CGPoint(x: point.x - cellOrigin.x, y: point.y - rect.minY)
        let geometry = style.geometry
        guard local.x >= 0, local.x <= geometry.columnWidth else {
            return (row, nil, nil)
        }
        let graphRow = source.graph[row]
        for stub in GraphRenderer.stubTargets(of: graphRow, geometry: geometry) where geometry.hitArea(around: stub.point).contains(local) {
            return (row, stub.edge.track, stub)
        }
        // The node, then the nearest line.
        let nodeCenter = CGPoint(x: geometry.laneX(graphRow.lane), y: geometry.nodeY)
        if hypot(local.x - nodeCenter.x, local.y - nodeCenter.y) <= geometry.clearance(.commit) + 1 {
            return (row, graphRow.track, nil)
        }
        var best: (distance: CGFloat, track: Int)?
        for edge in graphRow.edges where edge.kind == .passing || edge.kind == .incoming || edge.kind == .outgoing {
            let distance = abs(local.x - geometry.laneX(edge.lane))
            if distance <= geometry.lanePitch / 2 - 1, distance < (best?.distance ?? .infinity) {
                best = (distance, edge.track)
            }
        }
        return (row, best?.track, nil)
    }

    /// The row a stub leads to, when it's loaded.
    func target(of edge: CommitGraphEdge) -> Int? {
        switch edge.kind {
        case .outgoingStub, .unrouted: edge.parentRow
        case .incomingStub: edge.childRow
        default: nil
        }
    }

    /// A click in the table: follows a stub when one is under it. Returns
    /// whether the click was taken.
    func click(at point: CGPoint) -> Bool {
        let hit = hitTest(point)
        guard let row = hit.row, let stub = hit.stub else {
            return false
        }
        if stub.edge.kind == .outgoingStub, stub.edge.parentRow == nil, source?.isComplete == true {
            // The parent isn't in the history: nothing to go to.
            return true
        }
        actions.followStub(row, stub.edge)
        return true
    }

    /// The tooltip for what's at `point` in `row`'s graph.
    func tooltip(forRow row: Int, stub: GraphRenderer.StubTarget?) -> String? {
        guard let source, row < shownRowCount, row < source.graph.count else {
            return nil
        }
        guard let stub else {
            guard let commit = source.commit(atRow: row) else {
                return presentation.workingCopy.title
            }
            let refs = source.refs(at: commit.sha).map(\.name)
            let summary = commit.summary.isEmpty ? CommitRowContent.emptySummary : RichText.emojified(commit.summary)
            return refs.isEmpty ? summary : "\(summary)\n\(refs.joined(separator: ", "))"
        }
        return StubNavigator.tooltip(for: stub.edge, row: row, source: source, isLoading: loadingStubRow == row, numberFormat: numberFormat)
    }

    /// Marks `row`'s stub as loading its other end (or stops, with nil).
    func setLoadingStub(row: Int?) {
        let previous = loadingStubRow
        loadingStubRow = row
        tableView.loadingStubRow = row
        reconfigure(rows: IndexSet([previous, row].compactMap { $0 }))
    }

    // MARK: Paging

    @objc private func boundsDidChange(_ notification: Notification) {
        recordAnchor()
        prefetchIfNeeded()
    }

    @objc private func willStartLiveScroll(_ notification: Notification) {
        isLiveScrolling = true
    }

    /// Whether the user is scrolling (the scroller, a trackpad, a wheel).
    private var isLiveScrolling = false
    /// Whether every older page is loading (the user went to the end).
    private(set) var isLoadingRemaining = false

    /// Loads the next page when the last visible row is within 300 rows of
    /// the end; when the user scrolls to the end itself, keeps loading pages
    /// until the history ends or Esc.
    func prefetchIfNeeded() {
        guard let source, !source.isComplete, shownRowCount > 0 else {
            return
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else {
            return
        }
        let last = visible.location + visible.length - 1
        if last >= shownRowCount - 1, isLiveScrolling {
            loadRemainingPages()
        } else if shownRowCount - 1 - last <= Self.prefetchDistance, !source.isLoadingMore {
            Task { [weak source] in
                await source?.loadNextPage()
            }
        }
    }

    /// Loads every older page (End, or scrolling to the end), until the
    /// history ends or `cancelLoading()`.
    func loadRemainingPages() {
        guard let source, !source.isComplete, !isLoadingRemaining else {
            return
        }
        isLoadingRemaining = true
        Task { [weak self, weak source] in
            await source?.loadRemainingPages()
            self?.isLoadingRemaining = false
        }
    }

    /// Stops loading older commits and any pending jump (Esc).
    func cancelLoading() {
        source?.cancelLoading()
        isLoadingRemaining = false
        actions.cancel()
    }

    private func updateFooter() {
        let shows = (source?.isLoadingMore ?? false) && shownRowCount > 0
        guard shows != showsFooter else {
            return
        }
        showsFooter = shows
        if shows {
            tableView.insertRows(at: [shownRowCount], withAnimation: [])
        } else {
            tableView.removeRows(at: [shownRowCount], withAnimation: [])
        }
    }

    // MARK: Keyboard reorder and drops

    private func setReorderInsertionRow(_ row: Int?) {
        guard row != reorderInsertionRow else {
            return
        }
        let previous = reorderInsertionRow
        reorderInsertionRow = row
        tableView.isReordering = row != nil
        updateFeedback(rows: [previous, row].compactMap { $0 })
        if let row {
            tableView.scrollRowToVisible(min(row, max(shownRowCount - 1, 0)))
        }
    }

    /// Shows drop feedback for `target`, or none.
    func setDropFeedback(_ feedback: GraphDropFeedback?, target: GraphDropTarget?) {
        let previous = dropFeedbackRow
        switch target {
        case .onto(let row)?: dropFeedbackRow = row
        case .above(let row)?: dropFeedbackRow = row
        case nil: dropFeedbackRow = nil
        }
        dropFeedbackValue = feedback
        updateFeedback(rows: [previous, dropFeedbackRow].compactMap { $0 })
    }

    private var dropFeedbackValue: GraphDropFeedback?

    private func updateFeedback(rows: [Int]) {
        for row in Set(rows.flatMap { [$0 - 1, $0] }) where row >= 0 && row < tableView.numberOfRows {
            (tableView.rowView(atRow: row, makeIfNecessary: false) as? GraphRowView)?.dropFeedback = feedback(forRow: row)
        }
    }

    /// The feedback `row` shows: the keyboard reorder's insertion line, or a
    /// drop's.
    private func feedback(forRow row: Int) -> GraphDropFeedback? {
        if let insertion = reorderInsertionRow {
            if insertion == row, row < shownRowCount {
                return .insertAbove
            }
            if insertion == shownRowCount, row == shownRowCount - 1 {
                return .insertBelow
            }
            return nil
        }
        guard let target = dropFeedbackRow, let value = dropFeedbackValue else {
            return nil
        }
        switch value {
        case .squash:
            return row == target ? value : nil
        case .insertAbove, .insertBelow:
            if target == row, row < shownRowCount {
                return .insertAbove
            }
            if target == shownRowCount, row == shownRowCount - 1 {
                return .insertBelow
            }
            return nil
        }
    }

    // MARK: Dragging out

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard presentation.allowsDragging, let source, row < shownRowCount, source.commit(atRow: row) != nil else {
            return nil
        }
        let candidates = tableView.selectedRowIndexes.contains(row) ? Array(tableView.selectedRowIndexes) : [row]
        let rows = candidates.filter { $0 < shownRowCount && source.commit(atRow: $0) != nil }
        // The first of the rows writes all their commits and the others
        // nothing: one dragging item, with Espalier's image of the stack
        // (`CommitDragImage`) and no count badge of the system's.
        guard row == rows.first else {
            return nil
        }
        return actions.dragPayload(rows.compactMap { source.commit(atRow: $0)?.sha })?.pasteboardItem()
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        let payload = CommitDragPayload.read(from: session.draggingPasteboard)
        CommitDragImage.apply(to: session, in: tableView, at: screenPoint, rows: rowIndexes, count: payload?.shas.count ?? rowIndexes.count, numberFormat: numberFormat)
        if let payload {
            actions.dragBegan(payload)
            watchDragEnd()
        }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        endDrag()
    }

    /// Ends the drag once the mouse button has been up for a moment.
    /// AppKit doesn't always report a drag's end (`endedAt` never comes for
    /// drags ended by posted mouse events), and the sidebar's "New Branch…"
    /// row would stay after them; the button's state is checked as the drag
    /// runs instead. The moment lets the drop land on that row first.
    private func watchDragEnd() {
        dragEndTimer?.invalidate()
        var ticksReleased = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                ticksReleased = NSEvent.pressedMouseButtons & 1 == 0 ? ticksReleased + 1 : 0
                if ticksReleased >= 3 {
                    self?.endDrag()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragEndTimer = timer
    }

    private func endDrag() {
        dragEndTimer?.invalidate()
        dragEndTimer = nil
        actions.dragEnded()
    }

    // MARK: Drops within the graph

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let payload = CommitDragPayload.read(from: info.draggingPasteboard) else {
            setDropFeedback(nil, target: nil)
            return []
        }
        let target: GraphDropTarget = dropOperation == .on ? .onto(row: row) : .above(row: row)
        guard let feedback = actions.validateDrop(payload, target) else {
            setDropFeedback(nil, target: nil)
            return []
        }
        setDropFeedback(feedback, target: target)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        setDropFeedback(nil, target: nil)
        guard let payload = CommitDragPayload.read(from: info.draggingPasteboard) else {
            return false
        }
        return actions.acceptDrop(payload, dropOperation == .on ? .onto(row: row) : .above(row: row))
    }

    /// A drag left the table or ended.
    func dragExited() {
        setDropFeedback(nil, target: nil)
    }

    // MARK: Activation

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < shownRowCount else {
            return
        }
        actions.activate(row)
    }

    /// Return on the selection.
    func activateSelection() {
        guard let row = tableView.selectedRowIndexes.first, row < shownRowCount else {
            return
        }
        actions.activate(row)
    }

    /// The context menu for a click on `row`: the selection when the row is
    /// in it, else the row alone.
    func menu(forClickedRow row: Int) -> MenuContent? {
        guard row >= 0, row < shownRowCount else {
            return nil
        }
        let selected = tableView.selectedRowIndexes
        let rows = selected.contains(row) ? Array(selected.filter { $0 < shownRowCount }) : [row]
        return actions.menu(rows, row)
    }

    // MARK: Appearance and dates

    /// The tracks' colors for the rows shown: the current branch's in the
    /// accent, those local branches start in their branches' colors.
    private var trackPalette: TrackPalette.Resolved {
        source.map(presentation.palette(for:)) ?? TrackPalette.Resolved()
    }

    /// Takes the tracks' colors again, when the current branch's track or
    /// the tracks branches start changed. Returns whether they did.
    private func updateTrackColors() -> Bool {
        let palette = trackPalette
        guard palette != style.palette else {
            return false
        }
        style.palette = palette
        style.colors = GraphColors(palette: palette, appearance: tableView.effectiveAppearance)
        return true
    }

    /// Draws with the colors of the table's appearance (and accent).
    func appearanceDidChange() {
        let palette = trackPalette
        style.palette = palette
        style.colors = GraphColors(palette: palette, appearance: tableView.effectiveAppearance)
        style.scale = tableView.window?.backingScaleFactor ?? style.scale
        reconfigureVisibleRows()
    }

    @objc private func systemColorsDidChange(_ notification: Notification) {
        appearanceDidChange()
    }

    /// The look changed: the rows' height, the lanes, the colors, and the
    /// rows' fonts follow it.
    @objc private func lookDidChange(_ notification: Notification) {
        tableView.rowHeight = Metrics.Graph.rowHeight
        tableView.backgroundColor = Palette.background
        scrollView.backgroundColor = Palette.background
        style.geometry = GraphGeometry(rowHeight: tableView.rowHeight, laneCount: lanesSeen, increaseContrast: isIncreasedContrast)
        appearanceDidChange()
    }

    @objc private func displayOptionsDidChange(_ notification: Notification) {
        isIncreasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        differentiatesWithoutColor = NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
        style.geometry = GraphGeometry(rowHeight: tableView.rowHeight, laneCount: lanesSeen, increaseContrast: isIncreasedContrast)
        reconfigureVisibleRows()
    }

    private func startMinuteTimer() {
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshVisibleDates()
            }
        }
    }

    /// Relative dates of the visible rows, once a minute.
    func refreshVisibleDates() {
        guard let source else {
            return
        }
        let now = Date()
        for row in Range(tableView.rows(in: tableView.visibleRect)) ?? 0..<0 where row < shownRowCount {
            guard let commit = source.commit(atRow: row),
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? CommitRowCellView else {
                continue
            }
            let date = dates.entry(for: commit.sha, date: commit.author.date, now: now, formatting: dateFormatting, timeZone: timeZone)
            cell.updateDate(date.text, short: date.short, tooltip: date.tooltip)
        }
    }

    // MARK: Accessibility

    @objc private func didEndLiveScroll(_ notification: Notification) {
        isLiveScrolling = false
        GraphAccessibility.announceScrollStatus(self)
    }

    // MARK: First page

    private func beginFirstPage() {
        if let interval = firstPageInterval {
            UISignposts.end(.historyFirstPage, interval)
        }
        firstPageInterval = UISignposts.begin(.historyFirstPage)
        firstPageStart = .now
        firstPageDuration = nil
    }

    private func endFirstPage() {
        guard let interval = firstPageInterval else {
            return
        }
        UISignposts.end(.historyFirstPage, interval)
        firstPageInterval = nil
        if let start = firstPageStart {
            firstPageDuration = .now - start
        }
    }
}

/// How long the table's work takes, for its budgets: each row configured
/// (≤ 0.3 ms), each page applied (≤ 2 ms).
final class GraphTableMeasurements {
    var rowConfigurations: [Duration] = []
    var pageApplies: [Duration] = []

    init() {}
}

/// The selection the graph shows: commits by SHA, or the working copy.
struct GraphSelection: Equatable {
    var shas: [String]
    var isWorkingCopy: Bool

    init(shas: [String] = [], isWorkingCopy: Bool = false) {
        self.shas = shas
        self.isWorkingCopy = isWorkingCopy
    }
}

/// Relative dates by commit, for the rows shown, refreshed once a minute: in
/// words, as History's rows show them (`RelativeTime.abbreviated`), and in
/// full.
struct DateTextCache {
    struct Text {
        /// In words, as VoiceOver reads it ("12 minutes ago").
        var text: String
        var tooltip: String
        /// As the rows show it ("12m", "Oct 5").
        var short: String
        /// The minute the text was made for.
        var minute: Int
        var stamp: UInt64
    }

    private var entries: [String: Text] = [:]
    private var counter: UInt64 = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// The date of `sha` in words, short and in full, from the cache when
    /// it was made this minute.
    mutating func entry(for sha: String, date: Date, now: Date, formatting: DateTimeFormatting, timeZone: TimeZone) -> Text {
        let minute = Int(now.timeIntervalSinceReferenceDate / 60)
        counter &+= 1
        if var entry = entries[sha], entry.minute == minute {
            entry.stamp = counter
            entries[sha] = entry
            return entry
        }
        let entry = Text(
            text: RelativeTime.describe(date, now: now, formatting: formatting, timeZone: timeZone),
            tooltip: RelativeTime.formatDate(date, formatting: formatting, timeZone: timeZone),
            short: RelativeTime.abbreviated(date, now: now, formatting: formatting, timeZone: timeZone),
            minute: minute,
            stamp: counter
        )
        entries[sha] = entry
        if entries.count > capacity {
            // Forget the least recently used half.
            let threshold = entries.values.map(\.stamp).sorted()[entries.count / 2]
            entries = entries.filter { $0.value.stamp > threshold }
        }
        return entry
    }
}

/// The row after the last commit while older commits load.
final class GraphFooterCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GraphFooter")

    private let spinner = ArcProgressView(.small)
    fileprivate let label = NSTextField(labelWithString: "Loading older commits…")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.font = AppKitTypography.secondary
        label.textColor = Palette.text3
        addSubview(spinner)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let size = Metrics.Progress.ArcSize.small.side
        let labelSize = label.intrinsicContentSize
        let total = size + Metrics.insetSmall + labelSize.width
        let x = max((bounds.width - total) / 2, Metrics.insetSmall)
        spinner.frame = CGRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
        label.frame = CGRect(x: x + size + Metrics.insetSmall, y: (bounds.height - labelSize.height) / 2, width: labelSize.width, height: labelSize.height)
    }
}

extension GraphFooterCellView: LookChangeObserving {
    func lookDidChange() {
        label.font = AppKitTypography.secondary
        label.textColor = Palette.text3
    }
}

import UniformTypeIdentifiers
