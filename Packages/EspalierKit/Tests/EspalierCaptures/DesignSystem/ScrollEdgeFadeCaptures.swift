// Lists scrolled partway, with more beyond both their edges: History's graph
// and simple list, the sidebar, Changes' files, and a commit's files. In a
// look with a scroll edge fade (`--look frost-iris`) each fades out at both
// edges over what's behind it; in the others they end at their edges.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Scroll edge fades", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct ScrollEdgeFadeCaptures {
    private let area = "ScrollEdgeFade"

    @Test("History's graph scrolled partway")
    func historyGraph() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeLongHistoryFixture()
            await fixture.show(.history)
            let history = fixture.history
            capture(named: "history-graph", area: area) { appearance in
                let controller = GraphTableController()
                controller.avatarLoader = MonogramAvatarLoader()
                let stage = PaneStage(controller.scrollView, size: CGSize(width: Metrics.Column.graphList.ideal, height: 360), appearance: appearance)
                defer { stage.close() }
                controller.update(
                    source: history,
                    presentation: GraphPresentation(repository: fixture.repository, place: .history),
                    selection: GraphSelection(shas: history.selection.shas, isWorkingCopy: history.isWorkingCopySelected),
                    reorderInsertionRow: nil
                )
                stage.scroll(by: Metrics.Graph.rowHeight * 6.5)
                return stage.image
            }
            await fixture.settle()
        }
    }

    @Test("History's simple list scrolled partway")
    func historySimple() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeSimpleHistoryFixture()
            await captureScrolled(
                SimpleHistoryList(repository: fixture.repository).windowEnvironment(fixture.context),
                named: "history-simple",
                size: CGSize(width: Metrics.Column.simpleList.ideal, height: 320),
                by: Metrics.SimpleList.rowHeight * 3.5
            )
            await fixture.settle()
        }
    }

    @Test("the sidebar scrolled partway, above its filter")
    func sidebar() async throws {
        try await withIsolatedGitConfig { _ in
            let local = try setupEmptyRepository("main")
            try await makeCommit(local, Tree(entries: [TreeEntry(path: "README.md", contents: Data("Weather\n".utf8))], commitMessage: "Initial commit"))
            let names = [
                "air-quality", "alerts", "app-icon", "crash-offline", "dark-mode", "hourly-chart", "launch-time",
                "localization", "onboarding", "pollen", "radar-colors", "search", "settings", "widgets",
            ]
            for name in names {
                try await runGit(["branch", name], local)
            }
            for tag in ["v1.0", "v1.1", "v2.0", "v2.1", "v2.2"] {
                try await runGit(["tag", tag], local)
            }
            let fixture = try await MainWindowFixture.make(local)
            fixture.context.state.select(.history, in: fixture.repository.id)
            await fixture.settle()
            await captureScrolled(
                SidebarContainer().windowEnvironment(fixture.context),
                named: "sidebar",
                size: CGSize(width: Metrics.Column.sidebar.ideal, height: 360),
                by: 166
            )
            await fixture.settle()
        }
    }

    @Test("Changes' files scrolled partway")
    func changesFiles() {
        let paths = (1...24).map { "Sources/Weather/Forecast\($0).swift" }
        let files = paths.map { WorkingDirectoryFileChange(path: $0, status: .modified(), selection: .fromInitialSelection(.all)) }
        let table = FileTable(files: .changes(files), selectedIDs: [files[6].id], inclusion: BenchmarkList.inclusion)
        capture(table, named: "changes-files", area: area, size: CGSize(width: Metrics.Column.changesFileList.ideal, height: 300)) { host in
            scrollAll(in: host, by: Metrics.FileList.rowHeight * 4.5)
        }
    }

    @Test("a commit's files scrolled partway, under their header")
    func commitFiles() {
        let files = (1...24).map { index in
            HistoryFileContent(
                file: CommittedFileRowContent(id: "\(index)", path: "Sources/Weather/Forecast\(index).swift", status: index % 5 == 0 ? .new : .modified),
                added: index * 3,
                deleted: index % 4,
                numberFormat: Capture.numberFormat
            )
        }
        let view = VStack(spacing: 0) {
            CommitFilesHeader(summary: CommitFilesSummary(fileCount: files.count, linesAdded: 900, linesDeleted: 36))
            Hairline()
            HistoryFileList(files: files, selection: "7")
        }
        capture(view.frame(width: Metrics.Column.commitFileList.ideal, height: 320), named: "commit-files", area: area) { host in
            scrollAll(in: host, by: Metrics.FileList.rowHeight * 4.5)
        }
    }

    /// Hosts `view` at `size` in a capture window in each appearance, waits
    /// until it has laid out, scrolls its lists down by `offset`, and
    /// captures it in the run's look.
    private func captureScrolled(_ view: some View, named name: String, size: CGSize, by offset: CGFloat, sourceLocation: SourceLocation = #_sourceLocation) async {
        _ = Capture.look
        for appearance in CaptureAppearance.allCases {
            let root = Capture.prepared(view.frame(width: size.width, height: size.height))
                .background(Color(nsColor: Palette.background))
            let host = NSHostingView(rootView: root)
            let window = CaptureWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance.appearance
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            await settle(host)
            scrollAll(in: host, by: offset)
            await settle(host)
            Capture.write(Capture.image(of: host), named: name, area: area, appearance: appearance, sourceLocation: sourceLocation)
            window.contentView = nil
        }
    }

    /// Lets `host` lay out and draw over a few turns of the run loop.
    private func settle(_ host: NSView) async {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else {
                return
            }
        }
    }
}

/// Scrolls every scroll view in `view` whose content is taller than it
/// shows down by `offset`.
@MainActor
private func scrollAll(in view: NSView, by offset: CGFloat) {
    for scrollView in view.captureDescendants(NSScrollView.self) {
        let clip = scrollView.contentView
        guard let document = scrollView.documentView, document.frame.height > clip.bounds.height else {
            continue
        }
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + offset))
        scrollView.reflectScrolledClipView(clip)
    }
    view.layoutSubtreeIfNeeded()
}

/// An AppKit list in a capture window, on the pane's background.
@MainActor
private struct PaneStage {
    let window: CaptureWindow
    let pane: NSView
    let scrollView: NSScrollView

    init(_ scrollView: NSScrollView, size: CGSize, appearance: CaptureAppearance) {
        self.scrollView = scrollView
        window = CaptureWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        pane = PaneBackground(frame: CGRect(origin: .zero, size: size))
        scrollView.frame = pane.bounds
        scrollView.autoresizingMask = [.width, .height]
        pane.addSubview(scrollView)
        window.contentView = pane
    }

    /// Scrolls the list down by `offset`, once it has laid out.
    func scroll(by offset: CGFloat) {
        pane.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        scrollAll(in: pane, by: offset)
    }

    var image: NSBitmapImageRep {
        pane.layoutSubtreeIfNeeded()
        return Capture.image(of: pane)
    }

    func close() {
        window.contentView = nil
    }
}

/// The pane's background, which shows through where a list fades.
private final class PaneBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        dirtyRect.fill()
    }
}
