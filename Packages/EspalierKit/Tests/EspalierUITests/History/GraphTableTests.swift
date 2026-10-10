// The history graph's table: rows and pages, reloads that keep the view in
// place, selection both ways, the context menu from the keyboard and
// VoiceOver, ref capsules, the unpushed arrow, search dimming, the loading
// footer, drags, the columns narrow rows hide, and how rows look (in light
// and dark, the narrowest rows and the emphasis in light).

import AppKit
@testable import EspalierCore
import Foundation
import GitKit
import Testing
import UniformTypeIdentifiers
@testable import EspalierUI

/// A graph table in an offscreen window, laid out.
@MainActor
final class GraphTableHarness {
    let controller = GraphTableController()
    let window: SnapshotWindow
    let source: SyntheticHistory
    var presentation: GraphPresentation
    var selection = GraphSelection()
    private(set) var selections: [(shas: [String], contiguous: Bool)] = []
    private(set) var workingCopySelections = 0

    init(_ source: SyntheticHistory, presentation: GraphPresentation = GraphPresentation(), size: CGSize = CGSize(width: 640, height: 260), appearance: SnapshotAppearance = .light) {
        self.source = source
        self.presentation = presentation
        window = SnapshotWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        controller.fixedNow = UIFixtures.now
        controller.timeZone = UIFixtures.timeZone
        controller.avatarLoader = MonogramAvatarLoader()
        controller.actions.select = { [weak self] shas, contiguous in
            self?.selections.append((shas, contiguous))
            self?.selection = GraphSelection(shas: shas)
        }
        controller.actions.selectWorkingCopy = { [weak self] in
            self?.workingCopySelections += 1
            self?.selection = GraphSelection(isWorkingCopy: true)
        }
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        controller.scrollView.frame = container.bounds
        controller.scrollView.autoresizingMask = [.width, .height]
        container.addSubview(controller.scrollView)
        window.contentView = container
        // Focused, so a selection draws in the accent color.
        window.makeFirstResponder(controller.tableView)
        update()
    }

    /// Applies the source, presentation, and selection, and lays out.
    func update() {
        controller.update(source: source, presentation: presentation, selection: selection, reorderInsertionRow: nil)
        layout()
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        controller.tableView.layoutSubtreeIfNeeded()
    }

    var table: GraphNSTableView {
        controller.tableView
    }

    /// The cell showing `row`, if it's visible.
    func cell(_ row: Int) -> CommitRowCellView? {
        table.view(atColumn: 0, row: row, makeIfNecessary: false) as? CommitRowCellView
    }

    /// The window drawn into a 1x sRGB bitmap, as every snapshot is.
    func image() -> NSBitmapImageRep {
        layout()
        return Snapshot.image(of: window.contentView!)
    }
}

@Suite("History graph table") @MainActor
struct GraphTableTests {
    private let area = "HistoryTable"

    /// A main line with a feature branch, merged, and uncommitted work.
    private func featureHistory() -> SyntheticHistory {
        let commits = graphCommits("""
            M m3 f2
            f2 f1
            f1 m2
            m3 m2
            m2 m1
            m1 A
            A
            """)
        return SyntheticHistory(commits, options: CommitGraphOptions(trunkTip: "M", includesUncommittedWork: true, headSHA: "M"))
    }

    // MARK: Rows and pages

    @Test("shows a row for every graph row, and pages append rows")
    func pages() {
        let history = SyntheticHistory(generateHistory(seed: 7, commits: 1_500, maxBranches: 6).commits, options: CommitGraphOptions())
        history.publishFirstPage(100)
        let harness = GraphTableHarness(history)
        #expect(harness.table.numberOfRows == 100)
        #expect(harness.controller.shownRowCount == 100)

        // A page lands: rows are appended, nothing is reloaded.
        let firstCell = harness.cell(0)
        history.publishNextPage(1_000)
        harness.update()
        #expect(harness.table.numberOfRows == 1_100)
        #expect(harness.cell(0) === firstCell)

        // Two pages land between updates: both apply.
        history.publishNextPage(200)
        history.publishNextPage(200)
        harness.update()
        #expect(harness.table.numberOfRows == 1_500)
    }

    @Test("a reload keeps the commit at the top of the view in place, unless the view was at the top")
    func reloadKeepsPlace() throws {
        let history = SyntheticHistory(generateHistory(seed: 3, commits: 400, maxBranches: 4).commits)
        history.publishFirstPage(400)
        let harness = GraphTableHarness(history)
        let rowHeight = harness.table.rowHeight

        // Scrolled down to row 100: two new commits on top keep row 100's
        // commit at the top.
        harness.controller.scroll(toY: 100 * rowHeight, animated: false)
        harness.layout()
        let topRow = harness.table.rows(in: harness.table.visibleRect).location
        let topSHA = try #require(history.commit(atRow: topRow)?.sha)
        let topOffset = harness.table.rect(ofRow: topRow).minY - harness.table.visibleRect.minY
        let newCommits = [CommitGraphCommit(sha: "n2", parentSHAs: ["n1"]), CommitGraphCommit(sha: "n1", parentSHAs: [history.allCommits[0].sha])]
        history.reload(with: newCommits + history.allCommits, count: 402)
        harness.update()
        let top = harness.table.rows(in: harness.table.visibleRect).location
        #expect(top == topRow + 2)
        #expect(history.commit(atRow: top)?.sha == topSHA)
        #expect(harness.table.rect(ofRow: top).minY - harness.table.visibleRect.minY == topOffset)

        // At the top, the view stays at the top.
        harness.controller.scroll(toY: 0, animated: false)
        harness.layout()
        history.reload(with: [CommitGraphCommit(sha: "n3", parentSHAs: ["n2"])] + history.allCommits, count: 403)
        harness.update()
        #expect(harness.table.rows(in: harness.table.visibleRect).location == 0)
    }

    @Test("a commit made while the top shows slides in under the working copy")
    func slideIn() throws {
        let history = featureHistory()
        history.publishFirstPage(7)
        let harness = GraphTableHarness(history)
        let firstCell = try #require(harness.cell(1))
        #expect(firstCell.content.sha == "M")

        // A new commit on HEAD: the history keeps its count, so the oldest
        // row leaves the end.
        let committed = [CommitGraphCommit(sha: "N", parentSHAs: ["M"])] + history.allCommits
        history.reload(with: committed, options: CommitGraphOptions(trunkTip: "N", includesUncommittedWork: true, headSHA: "N"), count: 7)
        harness.update()
        #expect(harness.table.numberOfRows == 8)
        #expect(harness.cell(1)?.content.sha == "N")
        #expect(harness.cell(2)?.content.sha == "M")
        // Scrolled away from the top, a reload keeps the place instead.
        #expect(harness.table.rows(in: harness.table.visibleRect).location == 0)
    }

    @Test("rows the model no longer has draw nothing until the next update reloads them")
    func shrunkBeforeUpdate() {
        let history = SyntheticHistory(generateHistory(seed: 5, commits: 400, maxBranches: 4).commits)
        history.publishFirstPage(400)
        let harness = GraphTableHarness(history)
        // A narrower scope lands, and the table lays out before SwiftUI
        // updates it.
        history.reload(with: Array(history.allCommits.prefix(5)), count: 5)
        harness.controller.scroll(toY: 300 * harness.table.rowHeight, animated: false)
        harness.layout()
        #expect(harness.table.numberOfRows == 400)
        harness.update()
        #expect(harness.table.numberOfRows == 5)
    }

    @Test("the loading footer shows after the last commit while older commits load")
    func footer() {
        let history = featureHistory()
        history.publishFirstPage(7)
        let harness = GraphTableHarness(history)
        #expect(harness.table.numberOfRows == 8)
        history.isLoadingMore = true
        harness.update()
        #expect(harness.table.numberOfRows == 9)
        #expect(harness.table.view(atColumn: 0, row: 8, makeIfNecessary: true) is GraphFooterCellView)
        #expect(harness.controller.tableView(harness.table, shouldSelectRow: 8) == false)
        history.isLoadingMore = false
        harness.update()
        #expect(harness.table.numberOfRows == 8)
    }

    @Test("the column widens for wider rows and never narrows")
    func columnWidth() {
        let history = featureHistory()
        history.publishFirstPage(7)
        let harness = GraphTableHarness(history)
        let width = harness.controller.style.geometry.columnWidth
        #expect(width == Metrics.Graph.columnWidth(lanes: 2))
        // A narrower history doesn't narrow the column.
        history.reload(with: graphCommits("a b\nb"), options: CommitGraphOptions(trunkTip: "a"), count: 2)
        harness.update()
        #expect(harness.controller.style.geometry.columnWidth == width)
    }

    // MARK: Selection

    @Test("choosing rows selects their commits; the model's selection selects rows")
    func selection() throws {
        let history = featureHistory()
        history.publishFirstPage(7)
        let harness = GraphTableHarness(history)

        // The user picks two adjacent rows, then two apart.
        harness.table.selectRowIndexes([2, 3], byExtendingSelection: false)
        #expect(harness.selections.last?.shas == ["f2", "f1"])
        #expect(harness.selections.last?.contiguous == true)
        harness.table.selectRowIndexes([1, 4], byExtendingSelection: false)
        #expect(harness.selections.last?.contiguous == false)

        // The working copy's row alone selects it.
        harness.table.selectRowIndexes([0], byExtendingSelection: false)
        #expect(harness.workingCopySelections == 1)

        // The model selects a commit: the table follows without echoing.
        let count = harness.selections.count
        harness.selection = GraphSelection(shas: ["m2"])
        harness.update()
        #expect(harness.table.selectedRowIndexes == [5])
        #expect(harness.selections.count == count)
        #expect(GraphTableController.isContiguous([2, 3, 4]))
        #expect(!GraphTableController.isContiguous([2, 4]))
    }

    // MARK: Context menus from the keyboard and VoiceOver

    @Test("⇧F10 pops up the selection's menu at the row selected last, and nothing without a selection; VoiceOver's Show Menu pops up a cell's row's")
    func keyboardContextMenu() throws {
        let history = featureHistory()
        history.publishFirstPage(7)
        let harness = GraphTableHarness(history)
        let menu = NSMenu()
        var requests: [(rows: [Int], clicked: Int)] = []
        harness.controller.actions.menu = { rows, clicked in
            requests.append((rows, clicked))
            return menu
        }
        let popped = PoppedUpMenus()
        let key = try f10KeyDown(in: harness.window)

        // Nothing selected: the key is used, and nothing pops up.
        #expect(KeyboardContextMenu.handle(key, in: harness.window, present: popped.present))
        #expect(requests.isEmpty)
        #expect(popped.popups.isEmpty)

        // Rows 2 and 4, 4 selected last: the selection's menu, at row 4.
        harness.table.selectRowIndexes([2], byExtendingSelection: false)
        harness.table.selectRowIndexes([4], byExtendingSelection: true)
        #expect(KeyboardContextMenu.handle(key, in: harness.window, present: popped.present))
        #expect(requests.map(\.rows) == [[2, 4]])
        #expect(requests.map(\.clicked) == [4])
        let popup = try #require(popped.popups.first)
        #expect(popup.menu === menu)
        #expect(popup.view === harness.table)
        #expect(harness.table.row(at: popup.location) == 4)

        // F10 alone, or with ⌘ too, goes on.
        #expect(!KeyboardContextMenu.handle(try f10KeyDown([], in: harness.window), in: harness.window, present: popped.present))
        #expect(!KeyboardContextMenu.handle(try f10KeyDown([.shift, .command], in: harness.window), in: harness.window, present: popped.present))
        #expect(popped.popups.count == 1)

        // Show Menu on a cell: its row's menu, alone or the selection's.
        // (No menu, so nothing pops up.)
        harness.controller.actions.menu = { rows, clicked in
            requests.append((rows, clicked))
            return nil
        }
        requests.removeAll()
        let cell = try #require(harness.cell(5))
        #expect(cell.isAccessibilitySelectorAllowed(#selector(NSAccessibilityProtocol.accessibilityPerformShowMenu)))
        #expect(!cell.accessibilityPerformShowMenu())
        #expect(try #require(harness.cell(2)).accessibilityPerformShowMenu() == false)
        #expect(requests.map(\.rows) == [[5], [2, 4]])
        #expect(requests.map(\.clicked) == [5, 2])
    }

    // MARK: Row content

    @Test("refs show as capsules: the current branch first, with its upstream; then branches, remote branches, and tags")
    func capsules() {
        let history = featureHistory()
        history.publishFirstPage(7)
        var presentation = GraphPresentation()
        presentation.currentBranch = "main"
        presentation.headSHA = "M"
        presentation.remoteNames = ["origin"]
        let harness = GraphTableHarness(history, presentation: presentation)
        let refs = [
            HistoryRef(kind: .localBranch, fullName: "refs/heads/release", name: "release"),
            HistoryRef(kind: .localBranch, fullName: "refs/heads/main", name: "main", upstream: "refs/remotes/origin/main"),
            HistoryRef(kind: .remoteBranch, fullName: "refs/remotes/origin/main", name: "origin/main"),
            HistoryRef(kind: .remoteBranch, fullName: "refs/remotes/origin/feature/x", name: "origin/feature/x"),
            HistoryRef(kind: .tag, fullName: "refs/tags/v1.0", name: "v1.0"),
        ]
        let capsules = harness.controller.refCapsules(refs, sha: "M", track: 0)
        #expect(capsules.map(\.kind) == [
            .currentBranchWithUpstream(remote: "origin"), .localBranch, .remoteBranch, .tag,
        ])
        #expect(capsules.map(\.name) == ["main", "release", "origin/feature/x", "v1.0"])

        // A detached HEAD gets its own capsule.
        harness.presentation.isDetached = true
        harness.presentation.currentBranch = nil
        harness.update()
        let detached = harness.controller.refCapsules([], sha: "M", track: 0)
        #expect(detached.map(\.kind) == [.detachedHead])
    }

    @Test("unpushed commits and tags waiting to be pushed show the arrow")
    func unpushed() {
        let history = featureHistory()
        history.publishFirstPage(7)
        history.localSHAs = ["M"]
        history.refsBySHA["m3"] = [HistoryRef(kind: .tag, fullName: "refs/tags/v2", name: "v2")]
        var presentation = GraphPresentation()
        presentation.tagsToPush = ["v2"]
        let harness = GraphTableHarness(history, presentation: presentation)
        #expect(harness.controller.content(forRow: 1).unpushedTooltip == "This commit has not been pushed to the remote repository")
        #expect(harness.controller.content(forRow: 4).unpushedTooltip == "This commit has 1 tag to push")
        #expect(harness.controller.content(forRow: 5).unpushedTooltip == nil)
    }

    @Test("without a remote, no commit or tag shows as unpushed, to the eye or to VoiceOver")
    func unpushedWithoutRemote() {
        let history = featureHistory()
        history.publishFirstPage(7)
        // Without a remote, every commit is local.
        history.localSHAs = Set((1..<7).compactMap { history.commit(atRow: $0)?.sha })
        history.refsBySHA["m3"] = [HistoryRef(kind: .tag, fullName: "refs/tags/v2", name: "v2")]
        var presentation = GraphPresentation()
        presentation.tagsToPush = ["v2"]
        presentation.hasRemote = false
        let harness = GraphTableHarness(history, presentation: presentation)
        for row in 1..<7 {
            #expect(harness.controller.content(forRow: row).unpushedTooltip == nil)
            #expect(!GraphAccessibility.value(forRow: row, source: history, presentation: presentation).contains("Not pushed."))
            if let commit = history.commit(atRow: row) {
                #expect(!GraphAccessibility.RotorKind.unpushedCommits.matches(commit, source: history, presentation: presentation))
            }
        }

        // With a remote, they do.
        harness.presentation.hasRemote = true
        harness.update()
        #expect(harness.controller.content(forRow: 1).unpushedTooltip == "This commit has not been pushed to the remote repository")
        #expect(GraphAccessibility.value(forRow: 1, source: history, presentation: harness.presentation).contains("Not pushed."))
    }

    @Test("rows that don't match the search dim")
    func searchDimming() {
        let history = featureHistory()
        history.publishFirstPage(7)
        var search = HistorySearch(query: "f")
        search.matchingRows = [2, 3]
        var presentation = GraphPresentation()
        presentation.search = search
        let harness = GraphTableHarness(history, presentation: presentation)
        #expect(harness.controller.content(forRow: 2).isDimmed == false)
        #expect(harness.controller.content(forRow: 4).isDimmed)
        #expect(harness.controller.emphasis(forRow: 4).nodeOpacity == Metrics.Graph.searchDimming)
    }

    @Test("narrow rows hide the short ID, then the avatar, then the date")
    func narrowColumns() throws {
        let expected: [(width: CGFloat, shown: Set<CommitRowCellView.TrailingColumn>)] = [
            (640, [.avatar, .date, .shortID]),
            (500, [.avatar, .date]),
            (420, [.date]),
            (360, []),
        ]
        for (width, shown) in expected {
            let history = featureHistory()
            history.publishFirstPage(7)
            var presentation = GraphPresentation()
            presentation.headSHA = "M"
            let harness = GraphTableHarness(history, presentation: presentation, size: CGSize(width: width, height: 200))
            let cell = try #require(harness.cell(1))
            #expect(cell.shownTrailingColumns == shown, "\(width) points")
        }
    }

    @Test("the working copy's row says what changed")
    func workingCopyRow() {
        #expect(WorkingCopySummary().title == "No Uncommitted Changes")
        #expect(WorkingCopySummary().detail == nil)
        #expect(WorkingCopySummary(changedFiles: 3).detail == "3 changed files")
        #expect(WorkingCopySummary(changedFiles: 1).detail == "1 changed file")
        #expect(WorkingCopySummary(changedFiles: 4, conflictedFiles: 2).detail == "2 conflicted files")
        #expect(WorkingCopySummary(changedFiles: 1_204).detail == "1,204 changed files")
    }

    // MARK: Drags

    @Test("dragged commits are the selection, or the dragged row alone")
    func dragPayload() throws {
        let history = featureHistory()
        history.publishFirstPage(7)
        let harness = GraphTableHarness(history)
        let repositoryID = RepositoryID()
        harness.controller.actions.dragPayload = { shas in CommitDragPayload(repositoryID: repositoryID, shas: shas) }
        harness.table.selectRowIndexes([2, 3], byExtendingSelection: false)
        func payload(_ row: Int) throws -> CommitDragPayload? {
            guard let item = harness.controller.tableView(harness.table, pasteboardWriterForRow: row) as? NSPasteboardItem,
                  let data = item.data(forType: NSPasteboard.PasteboardType(UTType.espalierCommits.identifier)) else {
                return nil
            }
            return try JSONDecoder().decode(CommitDragPayload.self, from: data)
        }
        #expect(try payload(3)?.shas == ["f2", "f1"])
        #expect(try payload(5)?.shas == ["m2"])
        // The working copy can't be dragged.
        #expect(try payload(0) == nil)
    }

    // MARK: Snapshots

    @Test("rows: the working copy, HEAD with refs, a merge, unpushed commits, and selection")
    func snapshotRows() {
        for appearance in SnapshotAppearance.allCases {
            let history = featureHistory()
            history.publishFirstPage(7)
            history.localSHAs = ["M", "f2"]
            history.refsBySHA = [
                "M": [
                    HistoryRef(kind: .localBranch, fullName: "refs/heads/main", name: "main", upstream: "refs/remotes/origin/main"),
                    HistoryRef(kind: .remoteBranch, fullName: "refs/remotes/origin/main", name: "origin/main"),
                ],
                "f2": [HistoryRef(kind: .localBranch, fullName: "refs/heads/feature/login", name: "feature/login")],
                "m2": [
                    HistoryRef(kind: .remoteBranch, fullName: "refs/remotes/origin/release", name: "origin/release"),
                    HistoryRef(kind: .tag, fullName: "refs/tags/v1.2", name: "v1.2"),
                    HistoryRef(kind: .tag, fullName: "refs/tags/v1.1", name: "v1.1"),
                    HistoryRef(kind: .tag, fullName: "refs/tags/v1.0", name: "v1.0"),
                ],
            ]
            var presentation = GraphPresentation()
            presentation.headSHA = "M"
            presentation.currentBranch = "main"
            presentation.remoteNames = ["origin"]
            presentation.workingCopy = WorkingCopySummary(changedFiles: 3)
            let harness = GraphTableHarness(history, presentation: presentation, size: CGSize(width: 640, height: 200), appearance: appearance)
            harness.selection = GraphSelection(shas: ["f1"])
            harness.update()
            assertSnapshot(harness.image(), named: "rows", area: area, appearance: appearance)
        }
    }

    @Test("the narrowest rows: no author, avatar, or date")
    func snapshotNarrow() {
        let history = featureHistory()
        history.publishFirstPage(7)
        var presentation = GraphPresentation()
        presentation.headSHA = "M"
        presentation.workingCopy = WorkingCopySummary(changedFiles: 2, conflictedFiles: 1)
        let harness = GraphTableHarness(history, presentation: presentation, size: CGSize(width: 360, height: 200))
        assertSnapshot(harness.image(), named: "narrow-360", area: area, appearance: .light)
    }

    @Test("a clean working copy, a search, and a focused branch")
    func snapshotEmphasis() {
        let history = featureHistory()
        history.publishFirstPage(7)
        var search = HistorySearch(query: "f")
        search.matchingRows = [2, 3]
        var presentation = GraphPresentation()
        presentation.headSHA = "M"
        presentation.search = search
        presentation.focusedSHA = "f2"
        let harness = GraphTableHarness(history, presentation: presentation, size: CGSize(width: 640, height: 200))
        assertSnapshot(harness.image(), named: "search-focus", area: area, appearance: .light)
    }
}
