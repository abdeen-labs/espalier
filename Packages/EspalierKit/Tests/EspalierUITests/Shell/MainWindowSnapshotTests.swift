// The whole main window, its toolbar, sidebar, and detail area, as a titled
// window draws it offscreen: History, History with Commit Info, and a
// merge's conflicts in Changes, flat in Classic and floating as cards in
// Islands. A place's split floats or lays its panes flat as the look
// changes, keeping its leading pane's content as wide.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Main window snapshots", .offline, .hangGuard(minutes: 5)) @MainActor
struct MainWindowSnapshotTests {
    private let area = "MainWindow"
    private static let size = CGSize(width: 1_280, height: 720)

    /// `context`'s window, its content `size`, drawn with its titlebar and
    /// toolbar in `look`.
    private func render(_ context: WindowContext, look: Look, appearance: SnapshotAppearance) -> NSBitmapImageRep {
        // Each window's toolbar is another of the main toolbar's family:
        // one window's goes before the next is made.
        autoreleasepool {
            Look.with(look.reviewed) {
                draw(context, appearance: appearance)
            }
        }
    }

    private func draw(_ context: WindowContext, appearance: SnapshotAppearance) -> NSBitmapImageRep {
        let root = Snapshot.deterministic(
            MainWindow()
                .windowEnvironment(context)
                .environment(\.diffBuildsSynchronously, true)
                .environment(\.historySplitAutosavePrefix, "EspalierTests.\(UUID().uuidString)")
                // A place reloads its diff as it appears, which ends after
                // the window is drawn: the loaded diff shows meanwhile, the
                // spinner only after its delay, as in the app.
                .environment(\.showsDelayedContentImmediately, false)
        )
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = [.toolbars]
        let window = SnapshotWindow(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance.appearance
        window.contentViewController = controller
        FlatWindowChrome.apply(to: window)
        window.setContentSize(Self.size)
        defer {
            window.toolbar = nil
            window.contentViewController = nil
            window.close()
        }
        guard let frame = window.contentView?.superview ?? window.contentView else {
            return Snapshot.bitmap(Self.size)
        }
        // The split view controller and the toolbar finish on the next
        // turns of the run loop.
        for _ in 0..<5 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
        }
        let image = Snapshot.image(of: frame)
        // The sidebar's and the inspector's columns are on Liquid Glass,
        // which an offscreen window draws as a blank sheet, with what's in
        // it: each column's content is drawn on its own and laid over the
        // image (the sidebar's as the window shows it, below a band as
        // high as the toolbar), then the titlebar and toolbar over that.
        let toolbarHeight = frame.bounds.height - window.contentLayoutRect.maxY
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        for glass in Self.all(NSGlassEffectView.self, in: frame) {
            let column = glass.convert(glass.bounds, to: frame)
            let view = column.minX == 0 ? AnyView(SidebarContainer()) : AnyView(InspectorColumn())
            let content = Snapshot.render(
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
            Snapshot.image(of: titlebar).draw(in: titlebar.convert(titlebar.bounds, to: frame), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return image
    }

    /// Every view of `type` in `view`, depth first.
    private static func all<V: NSView>(_ type: V.Type, in view: NSView) -> [V] {
        (view as? V).map { [$0] } ?? view.subviews.flatMap { all(type, in: $0) }
    }

    /// The first view of `type` in `view`, depth first.
    private static func first<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let match = view as? V {
            return match
        }
        for subview in view.subviews {
            if let match = first(type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func assertWindow(_ context: WindowContext, named name: String, looks: [Look], sourceLocation: SourceLocation = #_sourceLocation) {
        FlatWindowChrome.install()
        // A fixed name in the location control, not the folder's.
        if let repository = context.repository {
            context.app.setAlias("weather", for: repository.id)
        }
        for look in looks {
            for appearance in SnapshotAppearance.allCases {
                let image = render(context, look: look, appearance: appearance)
                assertSnapshot(image, named: look.snapshotName(name), area: area, appearance: appearance, sourceLocation: sourceLocation)
            }
        }
    }

    @Test("History: flat in Classic; the panes cards on the backdrop in Islands")
    func history() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture()
            await fixture.show(.history)
            assertWindow(fixture.context, named: "history", looks: [.classic, Look(theme: .islands, color: .lagoon), Look(theme: .islands, color: .indigo)])
            await fixture.settle()
        }
    }

    @Test("History with Commit Info: the inspector is a card of its own in Islands")
    func historyInspector() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await makeHistoryScreenFixture()
            await fixture.show(.history)
            fixture.context.state.isInspectorPresented = true
            assertWindow(fixture.context, named: "history-inspector", looks: [Look(theme: .islands, color: .indigo)])
            await fixture.settle()
        }
    }

    @Test("a merge's conflicts: the operation panel is a card above the place's in Islands")
    func changesConflicts() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await ChangesWindowFixture.make(try await setupConflictedRepo())
            await fixture.settle()
            assertWindow(fixture.context, named: "changes-conflicts", looks: [Look(theme: .islands, color: .lagoon)])
            await fixture.app.idle()
        }
    }
}

@Suite("Floating panes") @MainActor
struct FloatingPanesTests {
    /// A place's split as `SplitView` makes it, its leading pane `width`
    /// wide, in a split `total` wide.
    private func split(width: CGFloat, total: CGFloat = 1_000) -> (PaneSplitView, PaneCardView, PaneCardView) {
        let splitView = PaneSplitView(frame: CGRect(x: 0, y: 0, width: total, height: 600))
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.holdsPanes = true
        let leading = PaneCardView(content: NSView(frame: CGRect(x: 0, y: 0, width: width, height: 600)))
        let trailing = PaneCardView(content: NSView(frame: CGRect(x: width + 1, y: 0, width: total - width - 1, height: 600)))
        splitView.addArrangedSubview(leading)
        splitView.addArrangedSubview(trailing)
        splitView.adjustSubviews()
        splitView.setPosition(width, ofDividerAt: 0)
        return (splitView, leading, trailing)
    }

    @Test("a place's split floats its panes when the look does, and lays them flat again, the leading pane's content as wide")
    func switchesLive() {
        let (splitView, leading, trailing) = split(width: 320)
        splitView.updateLayout()
        #expect(!splitView.floats)
        #expect(splitView.dividerThickness == 1)
        #expect(leading.content.frame.width == 320)

        Look.with(Look(theme: .islands)) {
            splitView.lookDidChange()
        }
        #expect(splitView.floats)
        #expect(leading.floats && trailing.floats)
        // The gap between the cards is 8: 4 between their frames, and the
        // 2 each keeps for its ring and shadow.
        #expect(splitView.dividerThickness == PaneCards.frameGap)
        #expect(trailing.frame.minX - leading.frame.maxX == PaneCards.frameGap)
        #expect(leading.content.convert(leading.content.bounds, to: splitView).minX == PaneCards.inset)
        #expect(leading.content.frame.width == 320)

        Look.with(Look(theme: .orchard)) {
            splitView.lookDidChange()
        }
        #expect(!splitView.floats)
        #expect(!leading.floats)
        #expect(splitView.dividerThickness == 1)
        #expect(leading.content.frame.width == 320)
        #expect(leading.content.convert(leading.content.bounds, to: splitView).minX == 0)
    }

    @Test("a split inside a pane stays flat in the floating layout")
    func innerSplitStaysFlat() {
        let (splitView, leading, _) = split(width: 200)
        splitView.holdsPanes = false
        Look.with(Look(theme: .islands)) {
            splitView.updateLayout()
        }
        #expect(!splitView.floats)
        #expect(!leading.floats)
        #expect(splitView.dividerThickness == 1)
    }

    @Test("floating, the whole gap between the cards drags the divider")
    func gapDrags() {
        let (splitView, _, _) = split(width: 320)
        let coordinator = SplitView<EmptyView, EmptyView>.Coordinator(column: Metrics.Column.changesFileList)
        Look.with(Look(theme: .islands)) {
            splitView.updateLayout()
        }
        let drawn = CGRect(x: 324, y: 0, width: PaneCards.frameGap, height: 600)
        let effective = coordinator.splitView(splitView, effectiveRect: drawn, forDrawnRect: drawn, ofDividerAt: 0)
        #expect(effective.width == PaneCards.gap)
        #expect(effective.minX == drawn.minX - PaneCards.inset)
    }
}
