// Changes' motion.
// When a status takes a few rows away and brings a few, the departing rows
// fade out while the rows below close the gap and new rows fade in; motion
// never changes a result. A click on a departing row's checkbox does
// nothing; two statuses during the animation end with the same rows and
// selection as without motion; long lists, many rows changing, rows moving,
// and committing everything change at once. The operation panel shows a
// running operation only past 300 ms.

import AppKit
@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

/// A file included in full.
@MainActor
private func file(_ path: String) -> WorkingDirectoryFileChange {
    WorkingDirectoryFileChange(path: path, status: .modified(), selection: DiffSelection.fromInitialSelection(.all))
}

/// The Changes table in an offscreen window, motion on or off.
@MainActor
private final class TableFixture {
    let window: SnapshotWindow
    let coordinator: FileTableCoordinator
    var table: FileTable
    /// The checkboxes' and the selection's calls.
    var included: [([String], Bool)] = []
    var selected: [[String]] = []

    init(files: [WorkingDirectoryFileChange], selectedIDs: [String] = [], animates: Bool) {
        table = FileTable(files: .changes(files), selectedIDs: selectedIDs, inclusion: BenchmarkList.inclusion)
        coordinator = FileTableCoordinator(table)
        window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.motionOverride = animates
        table.actions = FileTableActions(
            select: { [unowned self] ids in self.selected.append(ids) },
            setIncluded: { [unowned self] ids, include in self.included.append((ids, include)) }
        )
        let scrollView = FileTable.makeScrollView(coordinator: coordinator, table: table)
        scrollView.frame = window.contentLayoutRect
        window.contentView = scrollView
        scrollView.layoutSubtreeIfNeeded()
    }

    var tableView: NSTableView {
        coordinator.tableView!
    }

    /// Shows a new status: `files`, with `selectedIDs` selected.
    func show(_ files: [WorkingDirectoryFileChange], selectedIDs: [String]) {
        table.files = .changes(files)
        table.selectedIDs = selectedIDs
        coordinator.update(table)
        tableView.layoutSubtreeIfNeeded()
    }

    /// The file each row shows, as its cell was configured.
    var rowIDs: [String?] {
        (0..<tableView.numberOfRows).map { row in
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileRowView)?.content?.id
        }
    }

    func close() {
        window.contentView = nil
    }
}

@Suite("Changes motion", .hangGuard(minutes: 5)) @MainActor
struct ChangesMotionTests {
    @Test("a click on a departing row's checkbox does nothing")
    func departingRowIgnoresClicks() throws {
        let files = [file("a.txt"), file("b.txt"), file("c.txt")]
        let fixture = TableFixture(files: files, animates: true)
        defer { fixture.close() }
        let departing = try #require(fixture.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? FileRowView)
        #expect(departing.content?.id == files[1].id)

        // b.txt was committed: its row fades out as c.txt's moves up.
        fixture.show([files[0], files[2]], selectedIDs: [])
        #expect(departing.isDeparting)
        #expect(departing.hitTest(CGPoint(x: departing.bounds.midX, y: departing.bounds.midY)) == nil)
        departing.checkbox.performClick(nil)
        #expect(fixture.included.isEmpty)
        #expect(fixture.rowIDs == [files[0].id, files[2].id])

        // A row reused for a file that's there answers again.
        let staying = try #require(fixture.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? FileRowView)
        #expect(!staying.isDeparting)
        staying.checkbox.performClick(nil)
        #expect(fixture.included.map(\.0) == [[files[2].id]])
    }

    @Test("two statuses during the animation end with the same rows and selection as without motion")
    func overlappingStatuses() {
        let files = (0..<8).map { file("file-\($0).txt") }
        let first = [files[0], files[2], files[3], files[4], files[5], files[6]]
        let second = [files[0], files[3], files[5], files[6], files[7]]
        var results: [(rows: [String?], selection: IndexSet, shown: [ExactString]?)] = []
        for animates in [true, false] {
            let fixture = TableFixture(files: Array(files.prefix(6)), selectedIDs: [files[2].id], animates: animates)
            fixture.coordinator.update(fixture.table)
            // The first status's rows are still moving when the second
            // comes.
            fixture.show(first, selectedIDs: [files[2].id])
            fixture.show(second, selectedIDs: [files[5].id])
            results.append((fixture.rowIDs, fixture.tableView.selectedRowIndexes, fixture.coordinator.shownIDs))
            // The table's own selection changes while rows move aren't the
            // user's.
            #expect(fixture.selected.isEmpty)
            fixture.close()
        }
        #expect(results[0].rows == second.map(\.id))
        #expect(results[0].rows == results[1].rows)
        #expect(results[0].selection == IndexSet([2]))
        #expect(results[0].selection == results[1].selection)
        #expect(results[0].shown == results[1].shown)
    }

    @Test("only a few rows of a list of at most 1,000 animate; moves, empty lists, and more change at once")
    func animationLimits() {
        func ids(_ range: Range<Int>) -> [ExactString] {
            range.map { ExactString("file-\($0)") }
        }
        let change = FileTableCoordinator.rowChange(from: ids(0..<10), to: ids(0..<3) + ids(4..<10) + [ExactString("new")])
        #expect(change == FileTableCoordinator.RowChange(removed: IndexSet([3]), inserted: IndexSet([9])))
        // 51 rows changing.
        #expect(FileTableCoordinator.rowChange(from: ids(0..<100), to: ids(51..<100)) == nil)
        #expect(FileTableCoordinator.rowChange(from: ids(0..<100), to: ids(50..<100)) != nil)
        // More than 1,000 files on either side.
        #expect(FileTableCoordinator.rowChange(from: ids(0..<1_001), to: ids(0..<1_000)) == nil)
        #expect(FileTableCoordinator.rowChange(from: ids(0..<1_000), to: ids(0..<999)) != nil)
        // Rows trading places.
        #expect(FileTableCoordinator.rowChange(from: ids(0..<3), to: [ExactString("file-1"), ExactString("file-0"), ExactString("file-2")]) == nil)
        // Committing everything shows the empty state at once; the first
        // status too.
        #expect(FileTableCoordinator.rowChange(from: ids(0..<3), to: []) == nil)
        #expect(FileTableCoordinator.rowChange(from: [], to: ids(0..<3)) == nil)
        #expect(FileTableCoordinator.rowChange(from: ids(0..<3), to: ids(0..<3)) == nil)
    }

    @Test("the filter, another repository, or no motion changes the rows at once")
    func instantPaths() throws {
        let files = [file("a.txt"), file("b.txt"), file("c.txt")]
        let fixture = TableFixture(files: files, animates: true)
        defer { fixture.close() }
        let cell = try #require(fixture.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? FileRowView)
        // Typing in the filter: the rows change with no row departing.
        fixture.table.scope = FileTableScope(filter: FileListFilter(text: "a"))
        fixture.show([files[0]], selectedIDs: [])
        #expect(!cell.isDeparting)
        #expect(fixture.rowIDs == [files[0].id])
    }

    @Test("the operation panel shows a running operation only past 300 ms, and what waits on the user at once")
    func operationPanelDelay() async {
        let scheduler = ManualScheduler()
        let presence = OperationPanelPresence()

        // A fast operation never shows the panel.
        presence.update(.afterDelay, scheduler: scheduler)
        #expect(!presence.isShown(for: .afterDelay))
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(200))
        #expect(!presence.isShown(for: .afterDelay))
        presence.update(.none, scheduler: scheduler)
        await scheduler.advance(by: .milliseconds(200))
        #expect(!presence.isShown(for: .afterDelay))
        #expect(!presence.isShown(for: .none))

        // One that runs on shows it at 300 ms.
        presence.update(.afterDelay, scheduler: scheduler)
        await scheduler.waitForSleepers(1)
        await scheduler.advance(by: .milliseconds(299))
        #expect(!presence.isShown(for: .afterDelay))
        await scheduler.advance(by: .milliseconds(1))
        #expect(presence.isShown(for: .afterDelay))
        presence.update(.none, scheduler: scheduler)
        #expect(!presence.isShown(for: .afterDelay))

        // Conflicts show it at once, and it stays while Continue runs.
        presence.update(.now, scheduler: scheduler)
        #expect(presence.isShown(for: .now))
        presence.update(.afterDelay, scheduler: scheduler)
        #expect(presence.isShown(for: .afterDelay))
    }
}
