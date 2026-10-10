// History's simple list on a real repository: how it looks, in light and
// dark, collapsed and with a merge expanded; its rows (merges' titles, the
// "Not pushed" mark, file counts, tags, the time); the rail (the branch's
// line, where it started, merges' stubs); selection both ways and which
// selections are contiguous; expanding and collapsing a merge with the
// keyboard, its chevron, and VoiceOver; the commit menu of a merge's
// commit, from a right-click and ⇧F10; and where drops go.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

/// A feature branch selected in an app in the simple style, with a window.
@MainActor
struct SimpleListFixture {
    let harness: AppHarness
    let app: AppModel
    let repository: RepositoryModel
    let context: WindowContext
    /// The commits by summary.
    let shas: [String: String]

    var history: HistoryModel {
        repository.history
    }

    func settle() async {
        await app.idle()
        await repository.operations.enrichmentIdle()
        await history.idle()
    }

    /// The simple list rendered alone (the header is History's).
    func image(size: CGSize = CGSize(width: 400, height: 640), appearance: SnapshotAppearance) -> NSBitmapImageRep {
        Snapshot.render(SimpleHistoryList(repository: repository).windowEnvironment(context), size: size, appearance: appearance)
    }

    /// The list's table in an offscreen window, laid out.
    func table(size: CGSize = CGSize(width: 400, height: 640)) -> (controller: SimpleListController, window: SnapshotWindow) {
        let controller = SimpleListController()
        controller.fixedNow = UIFixtures.now
        controller.timeZone = UIFixtures.timeZone
        controller.avatarLoader = MonogramAvatarLoader()
        controller.actions = SimpleListActions.make(repository: repository, context: context)
        let window = SnapshotWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        controller.scrollView.frame = container.bounds
        container.addSubview(controller.scrollView)
        window.contentView = container
        window.makeFirstResponder(controller.tableView)
        update(controller)
        return (controller, window)
    }

    /// Shows the history's current state in `controller`'s table.
    func update(_ controller: SimpleListController) {
        controller.update(
            history: history,
            presentation: SimpleListPresentation(repository: repository),
            selection: history.selection.shas,
            reorderInsertionRow: context.state.history.reorder?.insertionRow
        )
        controller.scrollView.layoutSubtreeIfNeeded()
    }

    /// The table row of the commit with `summary`.
    func tableRow(_ summary: String, in controller: SimpleListController) throws -> Int {
        let sha = try #require(shas[summary], "No commit \(summary)")
        return try #require(controller.tableRow(of: sha))
    }
}

/// `main`: a few commits by several authors, two pull request merges
/// (#205 and #209), a tag, then five commits the feature branch doesn't
/// have; `feature/hourly-forecast`: two pushed commits and two that aren't,
/// checked out. Dates are before the fixtures' clock.
@MainActor
func makeSimpleListFixture() async throws -> SimpleListFixture {
    let seed = try setupEmptyRepository("main")
    var shas: [String: String] = [:]
    let now = Int(UIFixtures.now.timeIntervalSince1970)
    func run(_ repository: Repository, _ args: [String], by author: String, minutesAgo: Int) async throws -> String {
        let email = author.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com"
        return try await withGitEnvironment([
            "GIT_AUTHOR_NAME": author, "GIT_AUTHOR_EMAIL": email,
            "GIT_AUTHOR_DATE": "\(now - minutesAgo * 60) +0000", "GIT_COMMITTER_DATE": "\(now - minutesAgo * 60) +0000",
        ]) {
            try await runGit(args, repository)
            return JSCompat.trim(try await runGit(["rev-parse", "HEAD"], repository))
        }
    }
    func commit(_ repository: Repository, _ summary: String, by author: String, minutesAgo: Int, files: Int = 1) async throws {
        for index in 0..<files {
            let name = summary.lowercased().map { $0.isLetter ? $0 : "-" }
            try Data("\(summary) \(index)\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "\(String(name))-\(index).txt")))
        }
        try await runGit(["add", "-A"], repository)
        shas[summary] = try await run(repository, ["commit", "-q", "-m", summary], by: author, minutesAgo: minutesAgo)
    }
    func merge(_ repository: Repository, _ branch: String, _ message: String, by author: String, minutesAgo: Int) async throws {
        shas[message] = try await run(repository, ["merge", "-q", "--no-ff", "-m", message, branch], by: author, minutesAgo: minutesAgo)
    }
    let day = 24 * 60
    try await commit(seed, "Tune radar overlay opacity", by: "Leo Park", minutesAgo: 5 * day)
    try await commit(seed, "Localize precipitation strings", by: "Priya Nair", minutesAgo: 4 * day + 600)
    try await runGit(["checkout", "-q", "-b", "sam/severe-alerts"], seed)
    try await commit(seed, "Add severe weather alerts", by: "Sam Ortiz", minutesAgo: 4 * day + 300)
    try await runGit(["checkout", "-q", "main"], seed)
    try await merge(seed, "sam/severe-alerts", "Merge pull request #205 from sam/severe-alerts", by: "Sam Ortiz", minutesAgo: 4 * day)
    try await commit(seed, "Release 2.3.1", by: "Sam Ortiz", minutesAgo: 3 * day)
    try await runGit(["tag", "v2.3.1"], seed)
    try await commit(seed, "Fix crash when location access is denied", by: "Leo Park", minutesAgo: 2 * day)
    try await runGit(["checkout", "-q", "-b", "jonas/widget-refresh"], seed)
    try await commit(seed, "Refresh the widget's timeline", by: "Jonas Weber", minutesAgo: day + 600, files: 2)
    try await commit(seed, "Use the new widget sizes", by: "Jonas Weber", minutesAgo: day + 500)
    try await runGit(["checkout", "-q", "main"], seed)
    try await merge(seed, "jonas/widget-refresh", "Merge pull request #209 from jonas/widget-refresh", by: "Jonas Weber", minutesAgo: day + 400)
    let remote = try await makeBareRemote(from: seed)
    let local = try await cloneRepository(remote)
    try await runGit(["checkout", "-q", "-b", "feature/hourly-forecast"], local)
    try await commit(local, "Add HourlyForecast model", by: "Maya Chen", minutesAgo: day + 300, files: 2)
    try await commit(local, "Fetch hourly data from the forecast API", by: "Maya Chen", minutesAgo: 18 * 60, files: 3)
    try await runGit(["push", "-q", "-u", "origin", "feature/hourly-forecast"], local)
    try await commit(local, "Add HourlyRow view", by: "Maya Chen", minutesAgo: 60, files: 2)
    try await commit(local, "Show hourly forecast for the next 24 hours", by: "Maya Chen", minutesAgo: 12, files: 4)
    try await runGit(["checkout", "-q", "main"], local)
    for number in 1...5 {
        try await commit(local, "Main moves on \(number)", by: "Leo Park", minutesAgo: 600 - number * 60)
    }
    try await runGit(["checkout", "-q", "feature/hourly-forecast"], local)

    let harness = try AppHarness(historyStyle: nil)
    let app = await harness.loadedApp()
    app.preferences.hasShownWelcomeFlow = true
    let repository = try await harness.addAndSelect(local, to: app)
    let context = WindowContext(app: app)
    context.avatarLoader = MonogramAvatarLoader()
    let fixture = SimpleListFixture(harness: harness, app: app, repository: repository, context: context, shas: shas)
    context.state.select(.history, in: repository.id)
    fixture.history.activate()
    await fixture.settle()
    return fixture
}

@Suite("Simple history list", .offline, .hangGuard(minutes: 5)) @MainActor
struct SimpleHistoryListTests {
    private let area = "SimpleHistory"

    @Test("the list: the base's notice, then the branch's commits one after another, merges as one row")
    func list() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleListFixture()
            fixture.history.select(shas: [fixture.shas["Fetch hourly data from the forecast API"]!], contiguous: true)
            await fixture.settle()
            for appearance in SnapshotAppearance.allCases {
                assertSnapshot(fixture.image(appearance: appearance), named: "list", area: area, appearance: appearance)
            }
            await fixture.settle()
        }
    }

    @Test("a merge expanded: the commits it brought in, indented under it")
    func expandedMerge() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleListFixture()
            let merge = try #require(fixture.history.row(of: fixture.shas["Merge pull request #209 from jonas/widget-refresh"]!))
            fixture.history.setMergeExpanded(true, row: merge)
            fixture.history.select(shas: [fixture.shas["Use the new widget sizes"]!], contiguous: true)
            await fixture.settle()
            for appearance in SnapshotAppearance.allCases {
                assertSnapshot(fixture.image(appearance: appearance), named: "expanded", area: area, appearance: appearance)
            }
            await fixture.settle()
        }
    }

    @Test("rows: merges named for what they merged, the unpushed mark, file counts, tags, and what VoiceOver reads")
    func rows() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleListFixture()
            let (controller, window) = fixture.table()
            defer { window.contentView = nil }

            let newest = try #require(controller.content(forRow: try fixture.tableRow("Show hourly forecast for the next 24 hours", in: controller)))
            #expect(newest.isUnpushed)
            #expect(newest.metaText == "Maya Chen \u{00B7} 4 files")
            #expect(newest.shortDate == "12m")
            #expect(newest.accessibilityLabel == "Show hourly forecast for the next 24 hours. Maya Chen, 12 minutes ago. 4 files. Not pushed.")
            let pushed = try #require(controller.content(forRow: try fixture.tableRow("Fetch hourly data from the forecast API", in: controller)))
            #expect(pushed.isUnpushed == false)

            let merge = try #require(controller.content(forRow: try fixture.tableRow("Merge pull request #209 from jonas/widget-refresh", in: controller)))
            #expect(merge.mergeTitle == SimpleRowContent.MergeTitle(title: "Merged #209", branch: "jonas/widget-refresh"))
            #expect(merge.isExpanded == false)
            #expect(merge.filesText == "3 files")
            let release = try #require(controller.content(forRow: try fixture.tableRow("Release 2.3.1", in: controller)))
            #expect(release.tags == ["v2.3.1"])
            #expect(release.filesText == "1 file")

            // VoiceOver: one element per row, with a merge's state.
            let mergeRow = try fixture.tableRow("Merge pull request #209 from jonas/widget-refresh", in: controller)
            let cell = try #require(controller.tableView.view(atColumn: 0, row: mergeRow, makeIfNecessary: true) as? SimpleRowCellView)
            #expect(cell.isAccessibilityElement())
            #expect(cell.accessibilityLabel() == "Merged #209 jonas/widget-refresh. Jonas Weber, yesterday. 3 files.")
            #expect(cell.accessibilityValue() as? String == "Collapsed")
            #expect(cell.accessibilityCustomActions()?.first?.name == "Expand")

            #expect(SimpleListBanner.message(try #require(fixture.history.simpleBaseStatus)).characters.elementsEqual(
                "main has 5 new commits since this branch started."
            ))
            await fixture.settle()
        }
    }

    @Test("the rail: the tip, unpushed rings and pushed dots in the branch's color, the base's color from where the branch started, and merges' stubs")
    func rail() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleListFixture()
            let (controller, window) = fixture.table()
            defer { window.contentView = nil }
            let colors = controller.presentation.railColors
            #expect(colors.startRow == 4)
            #expect(colors.base == TrackPalette.trunk)
            @MainActor func rail(_ summary: String) throws -> SimpleRail {
                try #require(controller.display(forRow: try fixture.tableRow(summary, in: controller))?.rail)
            }

            let tip = try rail("Show hourly forecast for the next 24 hours")
            #expect(tip.node == .tip && tip.nodeColor == colors.line && tip.top == nil && tip.bottom == colors.line)
            #expect(try rail("Add HourlyRow view").node == .unpushed)
            let pushed = try rail("Add HourlyForecast model")
            #expect(pushed.node == .pushed && pushed.top == colors.line && pushed.bottom == colors.line)

            // The branch started at the merge of #209: the line runs into it
            // in the branch's color and leaves in main's.
            let start = try rail("Merge pull request #209 from jonas/widget-refresh")
            #expect(start.top == colors.line && start.nodeColor == TrackPalette.trunk && start.bottom == TrackPalette.trunk)
            let widget = colors.mergedColor(branch: "jonas/widget-refresh", isPullRequest: true, merge: fixture.shas["Merge pull request #209 from jonas/widget-refresh"]!)
            #expect(start.stub == SimpleRail.SideLine(color: widget, fades: true))
            #expect(try rail("Fix crash when location access is denied").top == TrackPalette.trunk)
            // The root commit ends the line.
            let root = try rail("Tune radar overlay opacity")
            #expect(root.bottom == nil && root.top == TrackPalette.trunk)

            // Expanded: the stub runs on through the merged commits and
            // fades out below the last.
            let merge = try #require(fixture.history.row(of: fixture.shas["Merge pull request #209 from jonas/widget-refresh"]!))
            fixture.history.setMergeExpanded(true, row: merge)
            await fixture.settle()
            fixture.update(controller)
            #expect(try rail("Merge pull request #209 from jonas/widget-refresh").stub?.fades == false)
            let first = try rail("Use the new widget sizes")
            #expect(first.node == .merged(isUnpushed: false) && first.nodeColor == widget)
            #expect(first.top == TrackPalette.trunk && first.bottom == TrackPalette.trunk)
            #expect(first.side == SimpleRail.SideLine(color: widget, fades: false))
            #expect(try rail("Refresh the widget's timeline").side == SimpleRail.SideLine(color: widget, fades: true))
            // A merged commit keeps the chevron's column, so its time lines
            // up with the merge's.
            #expect(controller.display(forRow: try fixture.tableRow("Use the new widget sizes", in: controller))?.keepsDisclosureColumn == true)
            await fixture.settle()
        }
    }

    @Test("after a push, the shown rows lose their unpushed marks and rings")
    func pushClearsUnpushedMarks() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleListFixture()
            let (window, host) = hostInWindow(
                SimpleHistoryList(repository: fixture.repository).windowEnvironment(fixture.context),
                size: CGSize(width: 400, height: 640)
            )
            defer { window.contentView = nil }
            let table = try #require(firstView(SimpleNSTableView.self, in: host))
            let controller = try #require(table.controller)
            @MainActor func cell(_ summary: String) throws -> SimpleRowCellView {
                let row = try fixture.tableRow(summary, in: controller)
                return try #require(table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SimpleRowCellView)
            }
            @MainActor func node(_ summary: String) throws -> SimpleRail.Node? {
                firstView(SimpleRailView.self, in: try cell(summary))?.rail.node
            }
            let unpushed = ["Show hourly forecast for the next 24 hours", "Add HourlyRow view"]
            #expect(try unpushed.allSatisfy { try cell($0).content.isUnpushed })
            #expect(try node("Add HourlyRow view") == .unpushed)

            _ = try await fixture.repository.sync.push()
            await fixture.settle()
            host.layoutSubtreeIfNeeded()

            #expect(try unpushed.allSatisfy { try !cell($0).content.isUnpushed })
            #expect(try node("Add HourlyRow view") == .pushed)
            await fixture.settle()
        }
    }

    @Test("selection both ways; only adjacent commits of the branch's line are contiguous")
    func selection() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleListFixture()
            let merge = try #require(fixture.history.row(of: fixture.shas["Merge pull request #209 from jonas/widget-refresh"]!))
            fixture.history.setMergeExpanded(true, row: merge)
            await fixture.settle()
            let (controller, window) = fixture.table()
            defer { window.contentView = nil }

            // The model's selection shows in the table: HEAD's commit.
            #expect(controller.tableView.selectedRowIndexes == [0])

            // A commit a merge brought in can be selected, and is the model's.
            let widget = try fixture.tableRow("Use the new widget sizes", in: controller)
            controller.tableView.selectRowIndexes([widget], byExtendingSelection: false)
            #expect(fixture.history.selection.shas == [fixture.shas["Use the new widget sizes"]!])

            let first = try fixture.tableRow("Add HourlyRow view", in: controller)
            let second = try fixture.tableRow("Fetch hourly data from the forecast API", in: controller)
            #expect(controller.isContiguous([first, second]))
            #expect(controller.isContiguous([0, second]) == false)
            let mergeTableRow = try fixture.tableRow("Merge pull request #209 from jonas/widget-refresh", in: controller)
            #expect(controller.isContiguous([mergeTableRow, widget]) == false)

            // The status line isn't selectable.
            #expect(controller.sha(atTableRow: widget + 1) != nil)
            await fixture.settle()
        }
    }

    @Test("a merge expands and collapses with → and ←, its chevron, and VoiceOver")
    func expandAndCollapse() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleListFixture()
            let (controller, window) = fixture.table()
            defer { window.contentView = nil }
            let summary = "Merge pull request #209 from jonas/widget-refresh"
            let mergeRow = try fixture.tableRow(summary, in: controller)
            let historyRow = try #require(fixture.history.row(of: fixture.shas[summary]!))

            @MainActor func press(_ key: Int) {
                let characters = String(Character(UnicodeScalar(UInt16(key))!))
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
                )!
                controller.tableView.keyDown(with: event)
            }

            // →: expands the selected merge.
            fixture.history.select(shas: [fixture.shas[summary]!], contiguous: true)
            fixture.update(controller)
            press(NSRightArrowFunctionKey)
            await fixture.settle()
            fixture.update(controller)
            #expect(fixture.history.mergedCommits(ofRow: historyRow)?.state == .loaded)
            #expect(controller.items.count == fixture.history.commitSHAs.count + 2)
            let widget = try fixture.tableRow("Use the new widget sizes", in: controller)
            #expect(widget == mergeRow + 1)

            // ← on a merged commit: back to the merge, collapsed.
            controller.tableView.selectRowIndexes([widget], byExtendingSelection: false)
            press(NSLeftArrowFunctionKey)
            fixture.update(controller)
            #expect(fixture.history.selection.shas == [fixture.shas[summary]!])
            #expect(fixture.history.mergedCommits(ofRow: historyRow) == nil)
            #expect(controller.items.count == fixture.history.commitSHAs.count)

            // The chevron: a click at the row's trailing end.
            let rect = controller.tableView.rect(ofRow: mergeRow)
            #expect(controller.click(at: CGPoint(x: rect.maxX - Metrics.SimpleList.rowInset - 8, y: rect.midY)))
            fixture.update(controller)
            #expect(fixture.history.simpleRow(atRow: historyRow)?.merge?.isExpanded == true)
            // Elsewhere in the row, a click selects as usual.
            #expect(controller.click(at: CGPoint(x: rect.midX, y: rect.midY)) == false)

            // VoiceOver's Collapse.
            let cell = try #require(controller.tableView.view(atColumn: 0, row: mergeRow, makeIfNecessary: true) as? SimpleRowCellView)
            let collapse = try #require(cell.accessibilityCustomActions()?.first)
            #expect(collapse.name == "Collapse")
            #expect(collapse.handler?() == true)
            #expect(fixture.history.simpleRow(atRow: historyRow)?.merge?.isExpanded == false)
            await fixture.settle()
        }
    }

    @Test("a merged commit's menu is a commit's, from a right-click or ⇧F10; drops go between the branch's commits, never among a merge's")
    func menusAndDrops() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleListFixture()
            let merge = try #require(fixture.history.row(of: fixture.shas["Merge pull request #209 from jonas/widget-refresh"]!))
            fixture.history.setMergeExpanded(true, row: merge)
            await fixture.settle()
            let (controller, window) = fixture.table()
            defer { window.contentView = nil }

            let widget = try fixture.tableRow("Use the new widget sizes", in: controller)
            #expect(controller.menu(forClickedRow: widget) != nil)
            let content = CommitContextMenus.menuContent(
                shas: [fixture.shas["Use the new widget sizes"]!],
                clicked: try #require(fixture.history.commit(fixture.shas["Use the new widget sizes"]!)),
                repository: fixture.repository
            )
            #expect(content.canAmend == false)

            // ⇧F10 with it selected: the same menu, at its row.
            controller.tableView.selectRowIndexes([widget], byExtendingSelection: false)
            let popped = PoppedUpMenus()
            #expect(KeyboardContextMenu.handle(try f10KeyDown(in: window), in: window, present: popped.present))
            let popup = try #require(popped.popups.first)
            #expect(controller.tableView.row(at: popup.location) == widget)
            #expect(popup.titles == controller.menu(forClickedRow: widget)?.items.map { $0.isSeparatorItem ? "—" : $0.title })

            let mergeTableRow = try fixture.tableRow("Merge pull request #209 from jonas/widget-refresh", in: controller)
            #expect(controller.dropTarget(proposedRow: mergeTableRow, operation: .on) == .onto(row: merge))
            #expect(controller.dropTarget(proposedRow: widget, operation: .on) == nil)
            #expect(controller.dropTarget(proposedRow: widget, operation: .above) == nil)
            #expect(controller.dropTarget(proposedRow: mergeTableRow + 3, operation: .above) == .above(row: merge + 1))
            #expect(controller.dropTarget(proposedRow: controller.items.count, operation: .above) == .above(row: fixture.history.commitSHAs.count))
            await fixture.settle()
        }
    }
}
