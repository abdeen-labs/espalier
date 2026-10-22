// The whole main window, its toolbar, sidebar, and detail area, as a
// titled window draws it offscreen: History with HEAD's commit and its
// diff, History with Commit Info, History with the sidebar hidden (Changes
// | History in the toolbar), History beside the icons style's rail, with
// and without Commit Info, and a merge's conflicts in Changes; and the
// rail's Branches and Tags popovers.
// The window stays up while its split view, toolbar, and diff finish, so
// it's drawn in the run's look: `--look islands-lagoon` shows the panes as
// cards on the backdrop.

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

/// The suites whose windows have the main toolbar, run one test at a time.
/// Toolbars with one identifier are a family: AppKit inserts an item added
/// to one into the others too, and throws when they don't match. So one
/// window's toolbar goes before the next is made, across these suites.
@Suite(.serialized) enum MainToolbarWindows {}

extension MainToolbarWindows {
    @Suite("Main window", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
    struct MainWindowCaptures {
        private let area = "MainWindow"

        /// Draws `context`'s window in each appearance, once its diff (when
        /// `showsDiff`) has rows and it has stopped changing.
        private func captureWindow(_ context: WindowContext, named name: String, showsDiff: Bool) async {
            FlatWindowChrome.install()
            // A fixed name in the location control, not the folder's.
            if let repository = context.repository {
                context.app.setAlias("weather", for: repository.id)
            }
            for appearance in CaptureAppearance.allCases {
                var stage: MainWindowStage? = autoreleasepool { MainWindowStage(context, appearance: appearance) }
                await stage?.settle { !showsDiff || stage?.views(DiffTableView.self).contains { $0.numberOfRows > 0 } == true }
                let image = stage?.image
                autoreleasepool {
                    stage?.close()
                    stage = nil
                }
                if let image {
                    capture(named: name, area: area, appearances: [appearance]) { _ in image }
                }
                // The window's toolbar leaves the family once it's released.
                await Task.yield()
            }
        }

        @Test("History: every local branch's graph, and HEAD's commit with its diff")
        func history() async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await MainWindowFixture.history()
                await fixture.show(.history)
                fixture.context.state.columnVisibility = .all
                await captureWindow(fixture.context, named: "history", showsDiff: true)
                await fixture.settle()
            }
        }

        @Test("History with Commit Info")
        func historyInspector() async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await MainWindowFixture.history()
                await fixture.show(.history)
                fixture.context.state.columnVisibility = .all
                fixture.context.state.isInspectorPresented = true
                await captureWindow(fixture.context, named: "history-inspector", showsDiff: true)
                await fixture.settle()
            }
        }

        @Test("History with the sidebar hidden, Changes | History in the toolbar")
        func historySidebarHidden() async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await MainWindowFixture.history()
                await fixture.show(.history)
                await captureWindow(fixture.context, named: "history-sidebar-hidden", showsDiff: true)
                await fixture.settle()
            }
        }

        @Test("History beside the icons style's rail")
        func historyRail() async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await MainWindowFixture.history()
                fixture.app.preferences.sidebarStyle = .icons
                await fixture.show(.history)
                await captureWindow(fixture.context, named: "history-rail", showsDiff: true)
                await fixture.settle()
            }
        }

        @Test("History with Commit Info beside the icons style's rail")
        func historyRailInspector() async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await MainWindowFixture.history()
                fixture.app.preferences.sidebarStyle = .icons
                await fixture.show(.history)
                fixture.context.state.isInspectorPresented = true
                await captureWindow(fixture.context, named: "history-rail-inspector", showsDiff: true)
                await fixture.settle()
            }
        }

        @Test("the rail's Branches and Tags popovers, a branch selected", arguments: [RailSection.branches, .tags])
        func railPopover(_ section: RailSection) async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await MainWindowFixture.history()
                fixture.app.preferences.sidebarStyle = .icons
                await fixture.show(.branch(ref: "refs/heads/fix/crash"))
                let context = fixture.context
                let repository = fixture.repository
                await captureSettled({
                    PopoverCardView(model: PopoverCardModel {
                        AnyView(RailSectionPopover(section: section, repository: repository).windowEnvironment(context))
                    })
                    .fixedSize()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }, named: "rail-\(section.rawValue)", area: area, size: CGSize(width: 340, height: 360), untilStill: true)
                await fixture.settle()
            }
        }

        @Test("a merge's conflicts in Changes, with the operation panel")
        func changesConflicts() async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await MainWindowFixture.make(try await setupConflictedRepo())
                fixture.context.state.select(.changes, in: fixture.repository.id)
                await fixture.settle()
                await captureWindow(fixture.context, named: "changes-conflicts", showsDiff: false)
                await fixture.settle()
            }
        }
    }
}

/// The main window on an offscreen titled window, its toolbar bridged from
/// SwiftUI, kept up while it settles.
@MainActor
final class MainWindowStage {
    static let size = CGSize(width: 1_280, height: 720)

    let window: CaptureWindow
    let context: WindowContext

    /// - Parameters:
    ///   - size: The window's content size.
    ///   - highlighter: What colors the diff's code, as the app's own
    ///     highlighter does; none by default.
    init(
        _ context: WindowContext,
        appearance: CaptureAppearance,
        size: CGSize = MainWindowStage.size,
        highlighter: (any SyntaxHighlighter)? = nil
    ) {
        _ = Capture.look
        self.context = context
        let root = MainWindow()
            .windowEnvironment(context)
            .environment(\.syntaxHighlighter, highlighter)
        let controller = NSHostingController(rootView: Capture.prepared(root))
        controller.sceneBridgingOptions = [.toolbars]
        window = CaptureWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance.appearance
        window.contentViewController = controller
        FlatWindowChrome.apply(to: window)
        window.setContentSize(size)
    }

    /// The window's frame view: its content, titlebar, and toolbar.
    var frame: NSView {
        window.contentView?.superview ?? window.contentView ?? NSView()
    }

    /// Lets the split view controller and the toolbar finish (they do on
    /// later turns of the run loop, which runs while the stage waits), waits
    /// until `condition` holds, then until the window stops changing.
    func settle(until condition: () -> Bool) async {
        var last: Data?
        var turns = 0
        while true {
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            turns += 1
            if turns >= 5, condition() {
                let next = image.tiffRepresentation
                if next == last {
                    return
                }
                last = next
            }
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else {
                return
            }
        }
    }

    /// Every view of `type` in the window, depth first.
    func views<V: NSView>(_ type: V.Type) -> [V] {
        frame.captureDescendants(type)
    }

    /// What the window draws now. The sidebar's and the inspector's
    /// columns are on Liquid Glass, which an offscreen window draws as a
    /// blank sheet, with what's in it, and with a 0.5-point line just
    /// outside the column's inner edge that the window on screen doesn't
    /// show. So the columns are left out of the window's image, each
    /// column's content is drawn on its own and laid over it (below a band
    /// as high as the toolbar, as the window shows it), then the titlebar
    /// and toolbar over that.
    var image: NSBitmapImageRep {
        let frame = frame
        frame.layoutSubtreeIfNeeded()
        // A collapsed column's glass stays, hidden.
        let glasses = frame.captureDescendants(NSGlassEffectView.self).filter { !$0.isHiddenOrHasHiddenAncestor }
        // A column is its split item's view, the glass's superview.
        let image = Self.withLayersHidden(glasses.compactMap { $0.superview?.layer }) {
            Capture.image(of: frame)
        }
        let toolbarHeight = frame.bounds.height - window.contentLayoutRect.maxY
        let appearance: CaptureAppearance = window.appearance?.name == .darkAqua ? .dark : .light
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        for glass in glasses {
            let column = glass.convert(glass.bounds, to: frame)
            let view = column.minX == 0 ? AnyView(SidebarContainer()) : AnyView(InspectorColumn())
            let content = Capture.render(
                view
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear.frame(height: toolbarHeight)
                    }
                    .windowEnvironment(context),
                size: column.size,
                appearance: appearance
            )
            content.draw(in: column, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let titlebar = window.standardWindowButton(.closeButton)?.superview {
            Capture.image(of: titlebar).draw(in: titlebar.convert(titlebar.bounds, to: frame), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return image
    }

    /// Runs `body` with `layers` hidden, then shows them again, with no
    /// animation. A layer rather than its view: hiding a split item's view
    /// collapses the item.
    private static func withLayersHidden<T>(_ layers: [CALayer], _ body: () -> T) -> T {
        let shown = layers.filter { !$0.isHidden }
        func setHidden(_ isHidden: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in shown {
                layer.isHidden = isHidden
            }
            CATransaction.commit()
        }
        setHidden(true)
        defer { setHidden(false) }
        return body()
    }

    /// Takes the window down, and its toolbar with it.
    func close() {
        window.contentViewController = nil
        window.toolbar = nil
        window.close()
    }
}

/// A loaded app with one selected repository, and a window's context for it.
@MainActor
struct MainWindowFixture {
    let harness: AppHarness
    let app: AppModel
    let repository: RepositoryModel
    let context: WindowContext

    /// Adds `local` to a new app and selects it.
    static func make(_ local: Repository) async throws -> MainWindowFixture {
        let harness = try AppHarness()
        let app = try await AccountCaptureFixtures.app(harness)
        let repository = try await harness.addAndSelect(local, to: app)
        let context = AccountCaptureFixtures.context(app)
        let fixture = MainWindowFixture(harness: harness, app: app, repository: repository, context: context)
        await fixture.settle()
        return fixture
    }

    /// `main`: Initial commit, Add loader (tagged v1.0), Update docs, a
    /// merge of `feature/login` (Add sign-in sheet, Wire device flow, from
    /// Add loader), Bump version (HEAD); `fix/crash` from Update docs with
    /// Fix crash on empty repository. Commits are from a day ago, half an
    /// hour apart; one file is changed but not committed.
    static func history() async throws -> MainWindowFixture {
        let local = try setupEmptyRepository("main")
        let start = Int(Date().timeIntervalSince1970) - 86_400
        var minute = 0
        func nextDate() -> String {
            minute += 30
            return "\(start + minute * 60) +0000"
        }
        func commit(_ path: String, _ message: String) async throws {
            try await datedGit(local, date: nextDate(), writing: path, ["commit", "-q", "-m", message])
        }
        try await commit("README.md", "Initial commit")
        try await commit("Sources/Loader.swift", "Add loader")
        try await runGit(["tag", "v1.0"], local)
        try await runGit(["checkout", "-q", "-b", "feature/login"], local)
        try await commit("Sources/SignIn.swift", "Add sign-in sheet")
        try await commit("Sources/DeviceFlow.swift", "Wire device flow")
        try await runGit(["checkout", "-q", "main"], local)
        try await commit("docs/Guide.md", "Update docs")
        try await runGit(["checkout", "-q", "-b", "fix/crash"], local)
        try await commit("Sources/Empty.swift", "Fix crash on empty repository")
        try await runGit(["checkout", "-q", "main"], local)
        try await datedGit(local, date: nextDate(), writing: nil, ["merge", "-q", "--no-ff", "-m", "Merge branch 'feature/login'", "feature/login"])
        try await commit("VERSION", "Bump version")
        try Data("Changed\n".utf8).write(to: URL(filePath: POSIXPath.join(local.path, "README.md")))
        return try await make(local)
    }

    /// Runs git at a fixed author and committer date, after writing and
    /// adding `path` (its contents are git's arguments' last word).
    @concurrent
    private static func datedGit(_ repository: Repository, date: String, writing path: String?, _ args: [String]) async throws {
        try await withGitEnvironment(["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]) {
            if let path {
                let fullPath = POSIXPath.join(repository.path, path)
                try FileManager.default.createDirectory(atPath: POSIXPath.dirname(fullPath), withIntermediateDirectories: true)
                try Data("\(args.last ?? path)\n".utf8).write(to: URL(filePath: fullPath))
                try await runGit(["add", "--", path], repository)
            }
            try await runGit(args, repository)
        }
    }

    /// Waits for refreshes, operations, and the loads that follow them.
    func settle() async {
        await app.idle()
        await repository.operations.enrichmentIdle()
        await repository.history.idle()
        await repository.changes.diffIdle()
        await repository.commit.mostRecentLocalCommitIdle()
        await repository.stash.loadsIdle()
        await app.idle()
        withExtendedLifetime(harness) {}
    }

    /// Shows `place` and waits for it.
    func show(_ place: SidebarPlace) async {
        context.state.select(place, in: repository.id)
        repository.history.activate()
        await settle()
        await HistoryPlaces.enter(place, repository: repository, context: context)
        await settle()
    }
}
