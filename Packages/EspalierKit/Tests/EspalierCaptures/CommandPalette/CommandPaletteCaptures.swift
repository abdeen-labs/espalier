// The command palette's card, light and dark, for a window on a repository
// with branches (main checked out; feature/login and fix/crash) and two
// other repositories, recently selected: nothing typed (the actions from
// the top, the highlight moved down the list with the keyboard, and
// scrolled to the end, where the recent repositories and branches are), a
// query matching actions and a branch, and a query matching nothing.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Command palette", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
struct CommandPaletteCaptures {
    private let area = "CommandPalette"

    /// The card with the margin its shadow draws in.
    private static let size = CGSize(
        width: Metrics.CommandPalette.width + Metrics.Popover.shadowInsets.left + Metrics.Popover.shadowInsets.right,
        height: Metrics.CommandPalette.height + Metrics.Popover.shadowInsets.top + Metrics.Popover.shadowInsets.bottom
    )

    /// The history fixture's window, with two more repositories selected
    /// before it, so they're recent.
    private func fixture() async throws -> MainWindowFixture {
        let fixture = try await MainWindowFixture.history()
        let app = fixture.app
        app.setAlias("weather", for: fixture.repository.id)
        var others: [RepositoryID] = []
        for alias in ["orchard", "espalier"] {
            let added = try await app.addRepositories([try setupEmptyRepository("main").path])
            let id = try #require(added.added.first)
            app.setAlias(alias, for: id)
            others.append(id)
        }
        for id in others + [fixture.repository.id] {
            app.select(.repository(id))
            await fixture.settle()
        }
        return fixture
    }

    /// The palette a stage shows.
    private final class Shown {
        var model: CommandPaletteModel?
    }

    /// Captures the card for `query` in `fixture`'s window, its highlight
    /// moved `moves` rows down once it shows, scrolled to its end when
    /// `scrolledToEnd`.
    private func capturePalette(_ fixture: MainWindowFixture, query: String, named name: String, moves: Int = 0, scrolledToEnd: Bool = false) async {
        let context = fixture.context
        let shown = Shown()
        await captureSettled({
            let model = CommandPaletteModel(context: context)
            model.query = query
            shown.model = model
            return PopoverCardView(model: PopoverCardModel {
                AnyView(CommandPaletteView(model: model).windowEnvironment(context))
            })
        }, named: name, area: area, size: Self.size, until: { stage in
            if moves > 0, let model = shown.model, model.highlighted == model.rowIDs.first {
                model.move(by: moves)
                return false
            }
            guard scrolledToEnd else {
                return true
            }
            guard let scrollView = stage.views(NSScrollView.self).first, let document = scrollView.documentView else {
                return false
            }
            let clip = scrollView.contentView
            clip.scroll(to: CGPoint(x: 0, y: max(document.bounds.height - clip.bounds.height, 0)))
            scrollView.reflectScrolledClipView(clip)
            return true
        })
    }

    @Test("nothing typed: the actions from the top, the highlight moved down, and scrolled to the recent repositories and branches")
    func empty() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await fixture()
            await capturePalette(fixture, query: "", named: "empty")
            await capturePalette(fixture, query: "", named: "empty-moved", moves: 14)
            await capturePalette(fixture, query: "", named: "empty-end", scrolledToEnd: true)
            await fixture.settle()
        }
    }

    @Test("a query matching a branch and actions, the matched characters in the accent")
    func filtered() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await fixture()
            await capturePalette(fixture, query: "fi", named: "filtered")
            await capturePalette(fixture, query: "branch", named: "filtered-branch")
            await fixture.settle()
        }
    }

    @Test("a query matching nothing")
    func noResults() async throws {
        try await withIsolatedGitConfig { _ in
            let fixture = try await fixture()
            await capturePalette(fixture, query: "qqqz", named: "no-results")
            await fixture.settle()
        }
    }
}

// Its window has the main toolbar, so it's one of MainToolbarWindows.
extension MainToolbarWindows {
    /// The palette open over History, where the window opens it: its
    /// panel drawn over the window at the panel's place.
    @Suite("Command palette in the window", .captures, .offline, .hangGuard(minutes: 5)) @MainActor
    struct CommandPaletteWindowCaptures {
        @Test("the palette over History, centered under the toolbar")
        func overHistory() async throws {
            try await withIsolatedGitConfig { _ in
                let fixture = try await MainWindowFixture.history()
                await fixture.show(.history)
                fixture.context.state.columnVisibility = .all
                FlatWindowChrome.install()
                fixture.app.setAlias("weather", for: fixture.repository.id)
                await fixture.settle()
                for appearance in CaptureAppearance.allCases {
                    var stage: MainWindowStage? = autoreleasepool { MainWindowStage(fixture.context, appearance: appearance) }
                    await stage?.settle { stage?.views(DiffTableView.self).contains { $0.numberOfRows > 0 } == true }
                    fixture.context.actions.perform(.showCommandPalette)
                    await fixture.context.actions.idle()
                    var panel: AnchoredPanel?
                    await stage?.settle {
                        panel = NSApp.windows.lazy.compactMap { $0 as? AnchoredPanel }.first { $0.isOpen && $0.anchorWindow === stage?.window }
                        return panel != nil
                    }
                    let image = stage.flatMap { stage in panel.map { Self.image(of: stage, with: $0) } }
                    panel?.close(reason: .closed, animated: false)
                    autoreleasepool {
                        stage?.close()
                        stage = nil
                    }
                    if let image {
                        capture(named: "window", area: "CommandPalette", appearances: [appearance]) { _ in image }
                    }
                    await Task.yield()
                }
                await fixture.settle()
            }
        }

        /// The stage's window with `panel` drawn over it where it is.
        private static func image(of stage: MainWindowStage, with panel: AnchoredPanel) -> NSBitmapImageRep {
            let image = stage.image
            guard let content = panel.contentView else {
                return image
            }
            content.layoutSubtreeIfNeeded()
            let card = Capture.image(of: content)
            let window = stage.window.frame
            let place = CGRect(x: panel.frame.minX - window.minX, y: panel.frame.minY - window.minY, width: panel.frame.width, height: panel.frame.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
            card.draw(in: place, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return image
        }
    }
}
