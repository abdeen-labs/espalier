// The table behind History's simple list. Its rows are the history model's
// outline (`HistoryModel.simpleOutline`): the branch's commits one after
// another, with an expanded merge's commits under it, then a footer while
// older commits load. Like the graph's table it syncs its selection with
// the model's, pages ahead of the scroll, keeps the commit at the top in
// place across reloads, and offers the commit menus, drags, drops, and
// keyboard reorder, which work on the history's rows (the line's commits).

import AppKit
import EspalierCore
import EspalierSupport
import GitKit
import UniformTypeIdentifiers

/// What the simple list shows of the repository besides its rows.
struct SimpleListPresentation: Equatable {
    /// Whether the repository has a remote: without one nothing shows as
    /// unpushed.
    var hasRemote = true
    /// The search, while there is a query: rows that don't match dim.
    var search: HistorySearch?
    /// HEAD's commit: its node is the bold ring and its title semibold.
    var headSHA: String?
    /// The GitHub endpoint avatars load from.
    var avatarEndpoint: String?
    /// Whether commits can be dragged out (to cherry-pick).
    var allowsDragging = true
    /// The history's `decorationsGeneration`: tags or unpushed marks
    /// changed.
    var decorations: UInt64 = 0
    /// The rail's colors, and where the branch started.
    var railColors = SimpleRailColors()
}

/// What the simple list's table asks of the screen showing it.
struct SimpleListActions {
    /// The user selected commits (top to bottom); `contiguous` says whether
    /// they're adjacent commits of the branch's line.
    var select: (_ shas: [String], _ contiguous: Bool) -> Void = { _, _ in }
    /// Double-click or Return on a commit.
    var activate: () -> Void = {}
    /// Expands or collapses the merge in the history's `row`.
    var setExpanded: (_ row: Int, _ expanded: Bool) -> Void = { _, _ in }
    /// The context menu for commits (the selection, or the one clicked)
    /// and the one clicked.
    var menu: (_ shas: [String], _ clicked: String) -> MenuContent? = { _, _ in nil }
    /// The payload for dragging commits out; nil refuses the drag.
    var dragPayload: (_ shas: [String]) -> CommitDragPayload? = { _ in nil }
    var dragBegan: (_ payload: CommitDragPayload) -> Void = { _ in }
    var dragEnded: () -> Void = {}
    /// What dropping `payload` on `target` (the history's rows) shows; nil
    /// refuses it.
    var validateDrop: (_ payload: CommitDragPayload, _ target: GraphDropTarget) -> GraphDropFeedback? = { _, _ in nil }
    var acceptDrop: (_ payload: CommitDragPayload, _ target: GraphDropTarget) -> Bool = { _, _ in false }
    /// Keyboard reorder.
    var moveReorderInsertion: (_ delta: Int) -> Void = { _ in }
    var confirmReorder: () -> Void = {}
    var cancelReorder: () -> Void = {}
    /// Esc: stops loading older commits and pending jumps.
    var cancel: () -> Void = {}
    /// ⌘C: the selected commits' SHAs.
    var copy: () -> Void = {}
    /// ⌘G and ⇧⌘G; returns whether there was a search to move in.
    var moveSearchMatch: (_ forward: Bool) -> Bool = { _ in false }
    /// VoiceOver's actions for a commit; `row` is its history row when
    /// it's on the branch's line.
    var accessibilityActions: (_ sha: String, _ row: Int?) -> [NSAccessibilityCustomAction] = { _, _ in [] }
}

/// The simple list's table: its data source, delegate, and the state
/// behind it.
final class SimpleListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Prefetch starts when the last visible commit is this close to the
    /// end, as in the graph.
    static let prefetchDistance = GraphTableController.prefetchDistance

    let tableView: SimpleNSTableView
    let scrollView: NSScrollView

    private(set) weak var history: HistoryModel?
    var actions = SimpleListActions()
    var avatarLoader: (any AvatarLoading)?

    var dateFormatting = DateTimeFormatting() {
        didSet {
            if dateFormatting != oldValue {
                dates = DateTextCache(capacity: dates.capacity)
            }
        }
    }

    var timeZone = TimeZone.current {
        didSet {
            if timeZone != oldValue {
                dates = DateTextCache(capacity: dates.capacity)
            }
        }
    }

    /// The rows: the outline's items.
    private(set) var items: [SimpleHistoryItem] = []
    private(set) var presentation = SimpleListPresentation()
    /// The history's list the items are of (`graphChange.reloadGeneration`).
    private var listGeneration: UInt64?
    /// The "Loading older commits…" row after the last item.
    private(set) var showsFooter = false
    private var isApplyingSelection = false
    private var lastSelection: [String] = []
    private(set) var reorderInsertionRow: Int?
    /// Where commits dragged over the list would go, and what that shows.
    private var currentDrop: Drop?
    private var dates = DateTextCache(capacity: 2_000)
    private let monograms = MonogramCache()
    /// A commit's row height, measured again when the look changes.
    private var rowHeight = Metrics.SimpleList.rowHeight
    private var minuteTimer: Timer?
    private var dragEndTimer: Timer?
    private var isLiveScrolling = false
    private(set) var isLoadingRemaining = false

    /// The clock a merge's "Loading…" line waits on (the line shows only
    /// past 300 ms).
    var scheduler: any Scheduler = SystemScheduler()
    /// The merges (by history row) whose loading line shows: they've
    /// loaded for 300 ms.
    private var loadingLinesShown = Set<Int>()
    /// The waits before a merge's loading line shows.
    private var loadingLineDelays: [Int: Task<Void, Never>] = [:]
    /// The last update's presentation and insertion point, to show a
    /// loading line when its wait ends.
    private var lastPresentation: (presentation: SimpleListPresentation, reorderInsertionRow: Int?)?

    /// The most rows a merge's expanding or collapsing crossfades; more
    /// change at once.
    static let crossfadeLimit = 100

    override init() {
        tableView = SimpleNSTableView(frame: .zero)
        scrollView = NSScrollView(frame: .zero)
        super.init()
        configureTable()
        startMinuteTimer()
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Commit"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.focusRingType = .none
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = Palette.background
        tableView.selectionHighlightStyle = .regular
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
        // No bouncing past the edges.
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.background
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(willStartLiveScroll(_:)), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(didEndLiveScroll(_:)), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(lookDidChange(_:)), name: Look.didChange, object: nil)
    }

    /// The look changed: the rows' height and colors follow it, and the
    /// rows show again in its fonts.
    @objc private func lookDidChange(_ notification: Notification) {
        rowHeight = Metrics.SimpleList.rowHeight
        tableView.rowHeight = rowHeight
        tableView.backgroundColor = Palette.background
        scrollView.backgroundColor = Palette.background
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
        reconfigureVisibleRows()
    }

    isolated deinit {
        minuteTimer?.invalidate()
        dragEndTimer?.invalidate()
        for task in loadingLineDelays.values {
            task.cancel()
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Updating

    /// Shows `history`'s outline with `presentation`, `selection` selected,
    /// and a keyboard reorder's insertion point (a history row), applying
    /// only what changed.
    func update(
        history: HistoryModel,
        presentation: SimpleListPresentation,
        selection: [String],
        reorderInsertionRow: Int?
    ) {
        let isNewHistory = self.history !== history
        if isNewHistory {
            self.history = history
            lastSelection = []
        }
        self.presentation = presentation
        lastPresentation = (presentation, reorderInsertionRow)
        let generation = history.graphChange.reloadGeneration
        if isNewHistory || generation != listGeneration {
            forgetLoadingLines()
        }
        let newItems = shownItems(history.simpleOutline.items, history: history)
        if isNewHistory || generation != listGeneration {
            reload(newItems, toTop: isNewHistory)
        } else if newItems != items {
            apply(newItems)
        }
        listGeneration = generation
        reconfigureVisibleRows()
        updateFooter(history.isLoadingMore)
        syncSelection(selection)
        setReorderInsertionRow(reorderInsertionRow)
        prefetchIfNeeded()
    }

    /// Replaces every row, keeping the commit at the top of the view where
    /// it was (or the top, if the view was there).
    private func reload(_ newItems: [SimpleHistoryItem], toTop: Bool) {
        let anchor = toTop ? nil : captureAnchor()
        items = newItems
        isApplyingSelection = true
        tableView.reloadData()
        isApplyingSelection = false
        restoreAnchor(anchor)
    }

    /// Applies a change of the same list: pages appended, or a merge's
    /// commits shown or hidden (the rows between the common start and end).
    /// The rows change at once; for a merge's commits, up to 100 rows, the
    /// list crossfades to them over 0.22 s, and back over 0.15 s.
    private func apply(_ newItems: [SimpleHistoryItem]) {
        let old = items
        var prefix = 0
        while prefix < old.count, prefix < newItems.count, old[prefix] == newItems[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < newItems.count - prefix,
              old[old.count - 1 - suffix] == newItems[newItems.count - 1 - suffix] {
            suffix += 1
        }
        items = newItems
        let removed = IndexSet(integersIn: prefix..<(old.count - suffix))
        let inserted = IndexSet(integersIn: prefix..<(newItems.count - suffix))
        let crossfades = Self.isMergeCrossfade(removed: removed.map { old[$0] }, inserted: inserted.map { newItems[$0] })
        if crossfades, Motion.animates(tableView) {
            Motion.crossfade(scrollView.layer, duration: inserted.isEmpty ? Motion.leave : Motion.arrive)
        }
        isApplyingSelection = true
        // The rows go in and out in a group of no duration, so the table's
        // own row motion doesn't run.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.beginUpdates()
            if !removed.isEmpty {
                tableView.removeRows(at: removed, withAnimation: [])
            }
            if !inserted.isEmpty {
                tableView.insertRows(at: inserted, withAnimation: [])
            }
            tableView.endUpdates()
        }
        isApplyingSelection = false
    }

    /// Whether rows coming and going are a merge's commits shown or hidden
    /// (its commits and its status line, no commit of the branch's line),
    /// few enough to crossfade.
    static func isMergeCrossfade(removed: [SimpleHistoryItem], inserted: [SimpleHistoryItem]) -> Bool {
        guard !(removed.isEmpty && inserted.isEmpty), removed.count <= crossfadeLimit, inserted.count <= crossfadeLimit else {
            return false
        }
        return (removed + inserted).allSatisfy { item in
            if case .commit = item {
                return false
            }
            return true
        }
    }

    // MARK: A merge's loading line

    /// `items` without the loading lines of merges that haven't loaded for
    /// 300 ms yet (a quick load shows its commits straight away), starting
    /// the wait for each new one.
    private func shownItems(_ items: [SimpleHistoryItem], history: HistoryModel) -> [SimpleHistoryItem] {
        var loading = Set<Int>()
        let shown = items.filter { item in
            guard case .mergedCommitsStatus(let mergeRow) = item, let merged = history.mergedCommits(ofRow: mergeRow),
                  merged.state == .loading, merged.count == 0
            else {
                return true
            }
            loading.insert(mergeRow)
            return loadingLinesShown.contains(mergeRow)
        }
        for (row, task) in loadingLineDelays where !loading.contains(row) {
            task.cancel()
            loadingLineDelays[row] = nil
        }
        loadingLinesShown.formIntersection(loading)
        for row in loading where !loadingLinesShown.contains(row) && loadingLineDelays[row] == nil {
            let scheduler = scheduler
            loadingLineDelays[row] = Task { [weak self] in
                try? await scheduler.sleep(for: Timing.spinnerDelay)
                guard let self, !Task.isCancelled else {
                    return
                }
                self.loadingLineDelays[row] = nil
                self.loadingLinesShown.insert(row)
                self.showLoadingLines()
            }
        }
        return shown
    }

    /// A merge has loaded for 300 ms: its loading line slides in.
    private func showLoadingLines() {
        guard let history, let lastPresentation else {
            return
        }
        update(
            history: history,
            presentation: lastPresentation.presentation,
            selection: history.selection.shas,
            reorderInsertionRow: lastPresentation.reorderInsertionRow
        )
    }

    /// The list reloaded: its rows are other commits.
    private func forgetLoadingLines() {
        for task in loadingLineDelays.values {
            task.cancel()
        }
        loadingLineDelays = [:]
        loadingLinesShown = []
    }

    // MARK: Anchoring

    private struct Anchor {
        var sha: String
        var offset: CGFloat
    }

    /// The commit at the top of the view, unless the view is at the top.
    private func captureAnchor() -> Anchor? {
        let visible = tableView.visibleRect
        let rows = tableView.rows(in: visible)
        guard rows.length > 0, visible.minY > 0 else {
            return nil
        }
        for row in rows.location..<(rows.location + rows.length) {
            if let sha = sha(atTableRow: row) {
                return Anchor(sha: sha, offset: tableView.rect(ofRow: row).minY - visible.minY)
            }
        }
        return nil
    }

    private func restoreAnchor(_ anchor: Anchor?) {
        guard let anchor, let row = tableRow(of: anchor.sha) else {
            scroll(toY: 0)
            return
        }
        scroll(toY: tableView.rect(ofRow: row).minY - anchor.offset)
    }

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let maximum = max(tableView.frame.height - clip.bounds.height, 0)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: min(max(y, 0), maximum)))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Rows

    /// The commit in a table row, if it shows one.
    func sha(atTableRow row: Int) -> String? {
        guard items.indices.contains(row), let history else {
            return nil
        }
        switch items[row] {
        case .commit(let historyRow):
            return history.commit(atRow: historyRow)?.sha
        case .mergedCommit(let mergeRow, let index):
            return history.simpleMergedRow(mergeRow: mergeRow, index: index)?.commit.sha
        case .mergedCommitsStatus:
            return nil
        }
    }

    /// The table row showing the commit `sha`.
    func tableRow(of sha: String) -> Int? {
        guard let history else {
            return nil
        }
        if let historyRow = history.row(of: sha) {
            return history.simpleOutline.itemIndex(ofRow: historyRow).flatMap { items.indices.contains($0) ? $0 : nil }
        }
        for (row, item) in items.enumerated() {
            if case .mergedCommit(let mergeRow, let index) = item,
               history.simpleMergedRow(mergeRow: mergeRow, index: index)?.commit.sha == sha {
                return row
            }
        }
        return nil
    }

    /// The history row (a commit of the branch's line) a table row shows.
    func historyRow(atTableRow row: Int) -> Int? {
        guard items.indices.contains(row), case .commit(let historyRow) = items[row] else {
            return nil
        }
        return historyRow
    }

    /// The merge a table row belongs to: the merge itself, or one of its
    /// commits or its status line.
    func mergeRow(atTableRow row: Int) -> Int? {
        guard items.indices.contains(row) else {
            return nil
        }
        switch items[row] {
        case .commit(let historyRow):
            return history?.commit(atRow: historyRow)?.isMergeCommit == true ? historyRow : nil
        case .mergedCommit(let mergeRow, _), .mergedCommitsStatus(let mergeRow):
            return mergeRow
        }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count + (showsFooter ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else {
            return Metrics.SimpleList.statusRowHeight
        }
        if case .mergedCommitsStatus = items[row] {
            return Metrics.SimpleList.statusRowHeight
        }
        return rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else {
            return tableView.makeView(withIdentifier: GraphFooterCellView.identifier, owner: self) as? GraphFooterCellView
                ?? GraphFooterCellView(frame: .zero)
        }
        if case .mergedCommitsStatus(let mergeRow) = items[row] {
            let cell = tableView.makeView(withIdentifier: SimpleStatusCellView.identifier, owner: self) as? SimpleStatusCellView
                ?? SimpleStatusCellView(frame: .zero)
            configure(cell, mergeRow: mergeRow)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: SimpleRowCellView.identifier, owner: self) as? SimpleRowCellView
            ?? makeCell()
        configure(cell, row: row)
        return cell
    }

    private func makeCell() -> SimpleRowCellView {
        let cell = SimpleRowCellView(frame: .zero)
        cell.accessibilityActionsProvider = { [weak self, weak cell] in
            guard let self, let cell else {
                return []
            }
            return self.accessibilityActions(for: cell)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = tableView.makeView(withIdentifier: SimpleRowView.identifier, owner: self) as? SimpleRowView ?? SimpleRowView(frame: .zero)
        rowView.dropFeedback = feedback(forRow: row)
        rowView.isContextMenuTarget = self.tableView.contextMenuTarget.isTarget(row)
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        sha(atTableRow: row) != nil
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        content(forRow: row)?.displaySummary
    }

    /// What table row `row` shows, when it's a commit.
    func content(forRow row: Int) -> SimpleRowContent? {
        display(forRow: row)?.content
    }

    /// What table row `row` shows, when it's a commit: its content, its
    /// rail, and whether it keeps the chevron's column (a merge's
    /// commits).
    func display(forRow row: Int) -> (content: SimpleRowContent, rail: SimpleRail, keepsDisclosureColumn: Bool)? {
        guard items.indices.contains(row), let history else {
            return nil
        }
        let colors = presentation.railColors
        let simpleRow: SimpleHistoryRow?
        var kind = SimpleRowContent.Kind.commit
        var isDimmed = false
        let rail: SimpleRail
        switch items[row] {
        case .commit(let historyRow):
            simpleRow = history.simpleRow(atRow: historyRow)
            if let merge = simpleRow?.merge {
                kind = .merge(title: SimpleRowContent.mergeTitle(merge), isExpanded: merge.isExpanded)
            }
            isDimmed = presentation.search.map { !$0.matches(row: historyRow) } ?? false
            let isLast = history.isComplete && historyRow == history.commitSHAs.count - 1
            let merge = simpleRow.flatMap { row in
                row.merge.map { merge in
                    (color: mergedColor(merge, sha: row.commit.sha), isExpanded: merge.isExpanded)
                }
            }
            let isHead = simpleRow.map { $0.commit.sha == presentation.headSHA } ?? false
            rail = colors.rail(row: historyRow, isHead: isHead, isLast: isLast, merge: merge, isDimmed: isDimmed)
        case .mergedCommit(let mergeRow, let index):
            simpleRow = history.simpleMergedRow(mergeRow: mergeRow, index: index)
            kind = .mergedCommit
            isDimmed = presentation.search != nil
            let isLast = !isUnderMerge(mergeRow, tableRow: row + 1)
            rail = colors.mergedRail(mergeRow: mergeRow, color: mergedColor(ofRow: mergeRow), isLast: isLast, isDimmed: isDimmed)
        case .mergedCommitsStatus:
            return nil
        }
        guard let simpleRow else {
            return nil
        }
        let commit = simpleRow.commit
        let date = dates.entry(for: commit.sha, date: commit.author.date, now: Date(), formatting: dateFormatting, timeZone: timeZone)
        let content = SimpleRowContent(
            kind: kind,
            sha: commit.sha,
            summary: RichText.emojified(commit.summary),
            authorName: commit.author.name,
            authorEmail: commit.author.email,
            date: date.text,
            shortDate: date.short,
            dateTooltip: date.tooltip,
            changedFileCount: simpleRow.changedFileCount,
            tags: simpleRow.tags,
            isUnpushed: presentation.hasRemote && simpleRow.isUnpushed,
            isCurrentTip: commit.sha == presentation.headSHA,
            isDimmed: isDimmed,
            avatarEndpoint: presentation.avatarEndpoint
        )
        return (content, rail, kind == .mergedCommit)
    }

    /// The color of the branch a merge brought in.
    private func mergedColor(_ merge: SimpleHistoryMerge, sha: String) -> NSColor {
        presentation.railColors.mergedColor(branch: merge.branchName, isPullRequest: merge.pullRequestNumber != nil, merge: sha)
    }

    /// The color of the branch the merge in history row `mergeRow` brought
    /// in.
    private func mergedColor(ofRow mergeRow: Int) -> NSColor {
        guard let row = history?.simpleRow(atRow: mergeRow), let merge = row.merge else {
            return presentation.railColors.mergedColor(branch: nil, isPullRequest: false, merge: "")
        }
        return mergedColor(merge, sha: row.commit.sha)
    }

    /// Whether table row `row` is one of the lines under the merge in
    /// history row `mergeRow`.
    private func isUnderMerge(_ mergeRow: Int, tableRow row: Int) -> Bool {
        guard items.indices.contains(row) else {
            return false
        }
        switch items[row] {
        case .mergedCommit(let merge, _), .mergedCommitsStatus(let merge):
            return merge == mergeRow
        case .commit:
            return false
        }
    }

    /// The status line under a merge's commits.
    func statusText(mergeRow: Int) -> (text: String, tooltip: String?) {
        guard let merged = history?.mergedCommits(ofRow: mergeRow) else {
            return ("", nil)
        }
        switch merged.state {
        case .loading:
            return ("Loading the merged commits\u{2026}", nil)
        case .failed(let error):
            return ("The merged commits couldn\u{2019}t load.", error.message)
        case .loaded:
            return ("The first \(formatCount(merged.count)) commits. Graph shows them all.", nil)
        }
    }

    private func configure(_ cell: SimpleRowCellView, row: Int) {
        guard let display = display(forRow: row) else {
            return
        }
        cell.configure(
            display.content,
            rail: display.rail,
            keepsDisclosureColumn: display.keepsDisclosureColumn,
            avatars: avatarLoader,
            monograms: monograms,
            scale: tableView.window?.backingScaleFactor ?? 2
        )
    }

    private func configure(_ cell: SimpleStatusCellView, mergeRow: Int) {
        let status = statusText(mergeRow: mergeRow)
        cell.configure(status.text, tooltip: status.tooltip, rail: presentation.railColors.statusRail(mergeRow: mergeRow, color: mergedColor(ofRow: mergeRow)))
    }

    /// Configures the rows the table has views for again (their commits'
    /// marks, tags, rails, search, or dates may have changed), including
    /// those it prepared beyond the visible ones.
    func reconfigureVisibleRows() {
        tableView.enumerateAvailableRowViews { rowView, row in
            switch rowView.view(atColumn: 0) {
            case let cell as SimpleRowCellView:
                configure(cell, row: row)
            case let cell as SimpleStatusCellView:
                if items.indices.contains(row), case .mergedCommitsStatus(let mergeRow) = items[row] {
                    configure(cell, mergeRow: mergeRow)
                }
            default:
                break
            }
        }
    }

    // MARK: Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else {
            return
        }
        let rows = Array(tableView.selectedRowIndexes)
        let shas = rows.compactMap(sha(atTableRow:))
        lastSelection = shas
        actions.select(shas, isContiguous(rows))
    }

    /// Whether table rows (ascending) are adjacent commits of the branch's
    /// line; a single commit always is.
    func isContiguous(_ rows: [Int]) -> Bool {
        guard rows.count > 1 else {
            return true
        }
        let historyRows = rows.map(historyRow(atTableRow:))
        guard historyRows.allSatisfy({ $0 != nil }) else {
            return false
        }
        let line = historyRows.compactMap(\.self)
        return zip(line, line.dropFirst()).allSatisfy { $1 == $0 + 1 }
    }

    /// Selects in the table what the model has selected, and brings a
    /// selection the model changed (a search match, Go to Commit) into view.
    private func syncSelection(_ selection: [String]) {
        let rows = IndexSet(selection.compactMap(tableRow(of:)))
        let isNew = selection != lastSelection
        lastSelection = selection
        guard rows != tableView.selectedRowIndexes else {
            return
        }
        isApplyingSelection = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isApplyingSelection = false
        if isNew, let first = rows.first {
            scrollToVisible(row: first)
        }
    }

    /// Brings `row` into view; before the table has its size (it's being
    /// shown), once it has.
    private func scrollToVisible(row: Int) {
        guard scrollView.contentView.bounds.height > 0 else {
            DispatchQueue.main.async { [weak self] in
                guard let self, row < self.tableView.numberOfRows else { return }
                self.tableView.scrollRowToVisible(row)
            }
            return
        }
        tableView.scrollRowToVisible(row)
    }

    // MARK: Merges

    /// Expands (or collapses) the merge `row` belongs to; on a merged
    /// commit, collapsing selects the merge first. Nothing happens on a
    /// commit that isn't a merge.
    func setExpanded(_ expanded: Bool, atTableRow row: Int) {
        guard let mergeRow = mergeRow(atTableRow: row) else {
            return
        }
        let isMergeItself = historyRow(atTableRow: row) == mergeRow
        if !expanded, !isMergeItself, let sha = history?.commit(atRow: mergeRow)?.sha {
            actions.select([sha], true)
        }
        actions.setExpanded(mergeRow, expanded)
    }

    /// Whether the merge in table row `row` shows its commits.
    func isExpanded(atTableRow row: Int) -> Bool {
        guard let historyRow = historyRow(atTableRow: row) else {
            return false
        }
        return history?.simpleRow(atRow: historyRow)?.merge?.isExpanded == true
    }

    /// A click in the table: a merge's chevron expands or collapses it.
    /// Returns whether the click was taken.
    func click(at point: CGPoint) -> Bool {
        let row = tableView.row(at: point)
        guard row >= 0, let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SimpleRowCellView,
              cell.content.isMerge
        else {
            return false
        }
        let local = cell.convert(point, from: tableView)
        guard cell.disclosureRect.contains(local) else {
            return false
        }
        setExpanded(!cell.content.isExpanded, atTableRow: row)
        return true
    }

    // MARK: Paging

    @objc private func boundsDidChange(_ notification: Notification) {
        prefetchIfNeeded()
    }

    @objc private func willStartLiveScroll(_ notification: Notification) {
        isLiveScrolling = true
    }

    @objc private func didEndLiveScroll(_ notification: Notification) {
        isLiveScrolling = false
    }

    /// Loads the next page when the last visible commit is within 300 of
    /// the end; scrolled to the end itself, loads every page until the
    /// history ends or Esc.
    func prefetchIfNeeded() {
        guard let history, !history.isComplete, !items.isEmpty else {
            return
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else {
            return
        }
        let last = visible.location + visible.length - 1
        let loaded = history.commitSHAs.count
        var lastHistoryRow = loaded - 1
        for row in stride(from: min(last, items.count - 1), through: 0, by: -1) {
            if let historyRow = historyRow(atTableRow: row) ?? mergeRow(atTableRow: row) {
                lastHistoryRow = historyRow
                break
            }
        }
        if last >= items.count - 1, isLiveScrolling {
            loadRemainingPages()
        } else if loaded - 1 - lastHistoryRow <= Self.prefetchDistance, !history.isLoadingMore {
            Task { [weak history] in
                await history?.loadNextPage()
            }
        }
    }

    /// Loads every older page (End, or scrolling to the end), until the
    /// history ends or `cancelLoading()`.
    func loadRemainingPages() {
        guard let history, !history.isComplete, !isLoadingRemaining else {
            return
        }
        isLoadingRemaining = true
        Task { [weak self, weak history] in
            await history?.loadRemainingPages()
            self?.isLoadingRemaining = false
        }
    }

    /// Stops loading older commits and any pending jump (Esc).
    func cancelLoading() {
        history?.cancelLoading()
        isLoadingRemaining = false
        actions.cancel()
    }

    private func updateFooter(_ isLoadingMore: Bool) {
        let shows = isLoadingMore && !items.isEmpty
        guard shows != showsFooter else {
            return
        }
        showsFooter = shows
        if shows {
            tableView.insertRows(at: [items.count], withAnimation: [])
        } else {
            tableView.removeRows(at: [items.count], withAnimation: [])
        }
    }

    // MARK: Keyboard reorder and drops

    private func setReorderInsertionRow(_ row: Int?) {
        guard row != reorderInsertionRow else {
            return
        }
        let began = reorderInsertionRow == nil
        reorderInsertionRow = row
        tableView.isReordering = row != nil
        updateFeedback()
        if let row, let tableRow = tableRow(forHistoryRow: row) {
            tableView.scrollRowToVisible(min(tableRow, max(items.count - 1, 0)))
        }
        if began, row != nil {
            tableView.window?.makeFirstResponder(tableView)
        }
    }

    /// The table row of a history row, or for the history's row count (the
    /// line after the last commit), the row after the last item.
    private func tableRow(forHistoryRow row: Int) -> Int? {
        if let index = history?.simpleOutline.itemIndex(ofRow: row) {
            return index
        }
        return row == history?.commitSHAs.count ? items.count : nil
    }

    /// Where a drop proposed at table row `row` goes in the history's rows:
    /// onto a commit of the line, or between two of them (never among a
    /// merge's commits).
    func dropTarget(proposedRow row: Int, operation: NSTableView.DropOperation) -> GraphDropTarget? {
        switch operation {
        case .on:
            return historyRow(atTableRow: row).map { .onto(row: $0) }
        case .above:
            if row >= items.count {
                return history.map { .above(row: $0.commitSHAs.count) }
            }
            return historyRow(atTableRow: row).map { .above(row: $0) }
        @unknown default:
            return nil
        }
    }

    private func updateFeedback() {
        for row in Range(tableView.rows(in: tableView.visibleRect)) ?? 0..<0 {
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? SimpleRowView else {
                continue
            }
            rowView.dropFeedback = feedback(forRow: row)
        }
    }

    /// The feedback table row `row` shows: the keyboard reorder's insertion
    /// line, or a drop's.
    private func feedback(forRow row: Int) -> GraphDropFeedback? {
        if let insertion = reorderInsertionRow {
            return insertionFeedback(historyRow: insertion, tableRow: row)
        }
        guard let drop = currentDrop else {
            return nil
        }
        let value = drop.feedback
        switch (drop.target, value) {
        case (.onto(let historyRow), .squash):
            return tableRow(forHistoryRow: historyRow) == row ? value : nil
        case (.above(let historyRow), _):
            return insertionFeedback(historyRow: historyRow, tableRow: row)
        default:
            return nil
        }
    }

    private func insertionFeedback(historyRow: Int, tableRow row: Int) -> GraphDropFeedback? {
        guard let target = tableRow(forHistoryRow: historyRow) else {
            return nil
        }
        if target == row, row < items.count {
            return .insertAbove
        }
        if target == items.count, row == items.count - 1 {
            return .insertBelow
        }
        return nil
    }

    private struct Drop: Equatable {
        var target: GraphDropTarget
        var feedback: GraphDropFeedback
    }

    private func setDropTarget(_ target: GraphDropTarget?, feedback: GraphDropFeedback?) {
        let drop = target.flatMap { target in feedback.map { Drop(target: target, feedback: $0) } }
        guard drop != currentDrop else {
            return
        }
        currentDrop = drop
        updateFeedback()
    }

    // MARK: Dragging out

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard presentation.allowsDragging, sha(atTableRow: row) != nil else {
            return nil
        }
        let candidates = tableView.selectedRowIndexes.contains(row) ? Array(tableView.selectedRowIndexes) : [row]
        let rows = candidates.filter { sha(atTableRow: $0) != nil }
        // One dragging item, as the graph's (`CommitDragImage`).
        guard row == rows.first else {
            return nil
        }
        return actions.dragPayload(rows.compactMap(sha(atTableRow:)))?.pasteboardItem()
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        let payload = CommitDragPayload.read(from: session.draggingPasteboard)
        CommitDragImage.apply(to: session, in: tableView, at: screenPoint, rows: rowIndexes, count: payload?.shas.count ?? rowIndexes.count)
        if let payload {
            actions.dragBegan(payload)
            watchDragEnd()
        }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        endDrag()
    }

    /// Ends the drag once the mouse button has been up for a moment (AppKit
    /// doesn't always report a drag's end; see the graph's table).
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

    // MARK: Drops within the list

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let payload = CommitDragPayload.read(from: info.draggingPasteboard),
              let target = dropTarget(proposedRow: row, operation: dropOperation),
              let feedback = actions.validateDrop(payload, target)
        else {
            setDropTarget(nil, feedback: nil)
            return []
        }
        setDropTarget(target, feedback: feedback)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        setDropTarget(nil, feedback: nil)
        guard let payload = CommitDragPayload.read(from: info.draggingPasteboard),
              let target = dropTarget(proposedRow: row, operation: dropOperation)
        else {
            return false
        }
        return actions.acceptDrop(payload, target)
    }

    /// A drag left the table or ended.
    func dragExited() {
        setDropTarget(nil, feedback: nil)
    }

    // MARK: Activation and menus

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, sha(atTableRow: row) != nil else {
            return
        }
        actions.activate()
    }

    /// Return on the selection.
    func activateSelection() {
        guard let row = tableView.selectedRowIndexes.first, sha(atTableRow: row) != nil else {
            return
        }
        actions.activate()
    }

    /// The context menu for a click on `row`: the selection when the row is
    /// in it, else the row alone.
    func menu(forClickedRow row: Int) -> MenuContent? {
        guard let clicked = sha(atTableRow: row) else {
            return nil
        }
        let selected = tableView.selectedRowIndexes
        let rows = selected.contains(row) ? Array(selected) : [row]
        return actions.menu(rows.compactMap(sha(atTableRow:)), clicked)
    }

    // MARK: Accessibility

    /// VoiceOver's actions for a row's cell: expanding or collapsing a
    /// merge, then the commit's actions.
    private func accessibilityActions(for cell: SimpleRowCellView) -> [NSAccessibilityCustomAction] {
        let sha = cell.content.sha
        guard let row = tableRow(of: sha) else {
            return []
        }
        var result: [NSAccessibilityCustomAction] = []
        if cell.content.isMerge {
            let expanded = cell.content.isExpanded
            result.append(NSAccessibilityCustomAction(name: expanded ? "Collapse" : "Expand") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let row = self.tableRow(of: sha) else {
                        return false
                    }
                    self.setExpanded(!expanded, atTableRow: row)
                    return true
                }
            })
        }
        return result + actions.accessibilityActions(sha, historyRow(atTableRow: row))
    }

    // MARK: Dates

    /// Shows the visible rows' relative dates again once a minute.
    private func startMinuteTimer() {
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconfigureVisibleRows()
            }
        }
    }
}
