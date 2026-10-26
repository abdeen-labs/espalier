// Which edges of a scrolling list fade, and how deep, at a scroll position:
// none at an end, a band that grows with the content past an edge up to the
// look's, measured inside the content insets; a scroll view's mask, there
// while an edge fades in Frost, following the scroll, and gone in a look
// without the fade; and a row scrolled into view, clear of the fade.

import AppKit
import EspalierCore
import GitKit
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Scroll edge fade") @MainActor
struct ScrollEdgeFadeTests {
    /// A clip view's bounds over a document, and the bands that show.
    struct Position: Sendable {
        var visible: CGRect
        var documentHeight: CGFloat = 1_000
        var insets = NSEdgeInsets()
        var isFlipped = true
        var band: CGFloat = 24
        var bands: ScrollEdgeFadeBands
    }

    @Test("the bands at a scroll position", arguments: [
        NamedCase("at the top: only the bottom fades", Position(visible: CGRect(x: 0, y: 0, width: 300, height: 300), bands: .init(top: 0, bottom: 24))),
        NamedCase("partway: both edges fade", Position(visible: CGRect(x: 0, y: 400, width: 300, height: 300), bands: .init(top: 24, bottom: 24))),
        NamedCase("just off the top: the top's band as deep as what's past it", Position(visible: CGRect(x: 0, y: 10, width: 300, height: 300), bands: .init(top: 10, bottom: 24))),
        NamedCase("half a point off the top: no fade there", Position(visible: CGRect(x: 0, y: 0.5, width: 300, height: 300), bands: .init(top: 0, bottom: 24))),
        NamedCase("just short of the end", Position(visible: CGRect(x: 0, y: 694, width: 300, height: 300), bands: .init(top: 24, bottom: 6))),
        NamedCase("at the end: only the top fades", Position(visible: CGRect(x: 0, y: 700, width: 300, height: 300), bands: .init(top: 24, bottom: 0))),
        NamedCase("content that fits: none", Position(visible: CGRect(x: 0, y: 0, width: 300, height: 300), documentHeight: 280, bands: .none)),
        NamedCase(
            "at rest inside insets: none at the top",
            Position(visible: CGRect(x: 0, y: -8, width: 300, height: 300), insets: NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0), bands: .init(top: 0, bottom: 24))
        ),
        NamedCase(
            "past the top inset: what's past the inset's edge",
            Position(visible: CGRect(x: 0, y: 4, width: 300, height: 300), insets: NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0), bands: .init(top: 12, bottom: 24))
        ),
        NamedCase(
            "at the end above a bottom inset: none at the bottom",
            Position(visible: CGRect(x: 0, y: 740, width: 300, height: 300), insets: NSEdgeInsets(top: 0, left: 0, bottom: 40, right: 0), bands: .init(top: 24, bottom: 0))
        ),
        NamedCase("an unflipped document at its top", Position(visible: CGRect(x: 0, y: 700, width: 300, height: 300), isFlipped: false, bands: .init(top: 0, bottom: 24))),
        NamedCase("an unflipped document at its end", Position(visible: CGRect(x: 0, y: 0, width: 300, height: 300), isFlipped: false, bands: .init(top: 24, bottom: 0))),
        NamedCase("a short list: no deeper than half its height", Position(visible: CGRect(x: 0, y: 400, width: 300, height: 30), bands: .init(top: 15, bottom: 15))),
        NamedCase("a look without the fade: none", Position(visible: CGRect(x: 0, y: 400, width: 300, height: 300), band: 0, bands: .none)),
    ])
    func bands(_ testCase: NamedCase<Position>) {
        let position = testCase.value
        let bands = ScrollEdgeFadeBands(
            visible: position.visible,
            content: CGRect(x: 0, y: 0, width: 300, height: position.documentHeight),
            insets: position.insets,
            isFlipped: position.isFlipped,
            band: position.band
        )
        #expect(bands == position.bands)
    }

    @Test("in Frost the mask is there while an edge fades and follows the scroll; a look without the fade has none")
    func mask() throws {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        scrollView.documentView = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 300, height: 1_000))
        let clipView = scrollView.contentView
        let fade = Look.with(Look(theme: .frost)) {
            ScrollEdgeFade(scrollView)
        }
        #expect(fade.bands == ScrollEdgeFadeBands(top: 0, bottom: 24))
        let layer = try #require(clipView.layer)
        let mask = try #require(layer.mask)

        Look.with(Look(theme: .frost)) {
            clipView.scroll(to: CGPoint(x: 0, y: 400))
        }
        #expect(fade.bands == ScrollEdgeFadeBands(top: 24, bottom: 24))
        #expect(layer.mask === mask)
        #expect(mask.frame == layer.bounds)
        #expect(mask.frame.minY == 400)

        Look.with(Look(theme: .frost)) {
            clipView.scroll(to: CGPoint(x: 0, y: 0))
        }
        #expect(fade.bands == ScrollEdgeFadeBands(top: 0, bottom: 24))
        #expect(mask.frame == layer.bounds)

        Look.with(.classic) {
            fade.update()
        }
        #expect(fade.bands == .none)
        #expect(layer.mask == nil)
    }

    @Test("a table's rows are its content: rows that fit don't fade, however tall the table, and rows past an edge do")
    func tableRows() {
        let rows = Rows(count: 4)
        let table = NSTableView(frame: .zero)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 20
        table.intercellSpacing = .zero
        table.dataSource = rows
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 30, right: 0)
        scrollView.documentView = table
        table.frame = CGRect(x: 0, y: 0, width: 300, height: 150)
        let fade = Look.with(Look(theme: .frost)) {
            ScrollEdgeFade(scrollView)
        }
        #expect(fade.bands == .none)

        rows.count = 8
        Look.with(Look(theme: .frost)) {
            table.reloadData()
            fade.update()
        }
        #expect(fade.bands == ScrollEdgeFadeBands(top: 0, bottom: 24))
    }

    @Test("a file selected below the list scrolls into view clear of the fade in Frost, to the list's edge in Classic", arguments: [
        NamedCase("Frost", (look: Look(theme: .frost), clearance: CGFloat(24))),
        NamedCase("Classic", (look: Look.classic, clearance: CGFloat(0))),
    ])
    func selectionClearsTheFade(_ testCase: NamedCase<(look: Look, clearance: CGFloat)>) {
        let controller = HistoryFileListController()
        controller.scrollView.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        let files = (0..<40).map { index in
            HistoryFileContent(file: CommittedFileRowContent(id: "\(index)", path: "File\(index).swift", status: .modified), numberFormat: defaultNumberFormat)
        }
        Look.with(testCase.value.look) {
            controller.update(files: files, selection: "30", actions: HistoryFilesActions(), focusRequest: 0)
        }
        let clipView = controller.scrollView.contentView
        let row = controller.tableView.rect(ofRow: 30)
        #expect(clipView.bounds.maxY - clipView.contentInsets.bottom - row.maxY == testCase.value.clearance)
    }
}

/// A table's rows, empty.
private final class Rows: NSObject, NSTableViewDataSource {
    var count: Int

    init(count: Int) {
        self.count = count
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        count
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool {
        true
    }
}
