// Espalier's alert card in each of its layouts, through the same mappings the
// hosts use where there's one, and the modal layer over a window: a sheet in
// its card over the scrim, an alert stacked over it, a card that scrolls,
// and a sheet that fills the window. The window images are the window's
// content with each layer's panel drawn over it, in the window's corners.

import AppKit
import EspalierCore
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Modal snapshots", .hangGuard(minutes: 5)) @MainActor
struct ModalSnapshotTests {
    private let area = "Modals"

    private func confirmation(_ name: String) throws -> AlertContent {
        try #require(UIFixtures.confirmations.first { $0.name == name }?.confirmation).alertContent
    }

    // MARK: The alert

    @Test("alerts: plain, critical with a list and the checkbox, a destructive default, three buttons")
    func alerts() throws {
        let prompt = try #require(UIFixtures.prompts.first { $0.name == "addSSHHost" }?.prompt)
        guard case .alert(let ssh, _) = PromptPresentation.make(prompt, finish: { _ in }) else {
            Issue.record("addSSHHost isn't an alert")
            return
        }
        assertSnapshot(ssh, named: "alert-plain", area: area)
        assertSnapshot(try confirmation("discardChanges"), named: "alert-critical", area: area)
        let quit = try #require(QuitGuardReasons(runningOperation: .rebase, repositoriesWithUnfinishedMessages: ["espalier"]).alert)
        assertSnapshot(quit, named: "alert-destructive", area: area)
        let push = AlertContent(
            title: "Push Local Changes?",
            message: "feature/login has 3 local commits that haven't been pushed. Push them before opening the pull request?",
            buttons: [
                AlertContent.Button("Push Commits", role: .primary),
                AlertContent.Button("Create Without Pushing", role: .secondary),
                AlertContent.Button("Cancel", role: .cancel),
            ]
        )
        assertSnapshot(push, named: "alert-threeButtons", area: area)
    }

    @Test("alerts: the checkbox on, a list of ten and the rest counted, a long URL")
    func alertContent() throws {
        assertSnapshot(try confirmation("discardChanges-one"), named: "alert-suppressed", area: area, appearances: [.light]) { model in
            model.isSuppressed = true
        }
        let files = (1...12).map { "Sources/Feature/File\($0).swift" }
        let overwritten = AlertContent(
            title: "Checkout Failed",
            message: AlertList.insert(files, intoMessage: "Your local changes to these files would be overwritten:\n\nYou can stash your changes now and restore them afterward."),
            buttons: [AlertContent.Button("Stash Changes and Retry", role: .primary), AlertContent.Button("Close", role: .cancel)]
        )
        assertSnapshot(overwritten, named: "alert-list", area: area, appearances: [.light])
        let remote = AlertContent(
            title: "Update the Upstream Remote?",
            message: "The upstream remote points to https://github.example.com/an-organization-with-a-long-name/a-repository-with-an-even-longer-name.git, not the parent repository.",
            buttons: [AlertContent.Button("Update", role: .destructive), AlertContent.Button("Ignore", role: .cancel)]
        )
        assertSnapshot(remote, named: "alert-url", area: area, appearances: [.light])
    }

    // MARK: Over a window

    /// A window's content behind the modals: a sidebar and rows.
    private struct Backdrop: View {
        var body: some View {
            HStack(spacing: 0) {
                Color(espalier: Palette.sidebar)
                    .frame(width: 200)
                VStack(alignment: .leading, spacing: Metrics.insetMedium) {
                    ForEach(0..<12) { row in
                        Text("Commit \(row + 1): Use the new widget sizes")
                            .font(Typography.row)
                            .foregroundStyle(.text)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Metrics.insetLarge)
                .padding(.top, Metrics.Toolbar.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color(espalier: Palette.background))
            }
            .ignoresSafeArea()
        }
    }

    /// An offscreen window of `size` drawing `Backdrop` under a transparent
    /// title bar, and a presenter on it.
    private func window(_ appearance: SnapshotAppearance, size: CGSize = CGSize(width: 720, height: 480)) -> (ModalPresenter, NSWindow) {
        let window = SnapshotWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = appearance.appearance
        window.contentView = NSHostingView(rootView: Snapshot.deterministic(Backdrop()))
        let modals = ModalPresenter()
        modals.environment = { AnyView(Snapshot.deterministic($0)) }
        modals.window = window
        return (modals, window)
    }

    /// The window's content with its layers over it, in its corners.
    private func image(of window: NSWindow, _ modals: ModalPresenter) throws -> NSBitmapImageRep {
        let content = try #require(window.contentView)
        content.frame = CGRect(origin: .zero, size: window.frame.size)
        content.layoutSubtreeIfNeeded()
        var images = [Snapshot.image(of: content)]
        for layer in modals.stack.layers {
            let view = try #require(layer.panel.contentView)
            view.layoutSubtreeIfNeeded()
            images.append(Snapshot.image(of: view))
        }
        let size = window.frame.size
        let result = Snapshot.bitmap(size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
        let bounds = CGRect(origin: .zero, size: size)
        let corners = UnevenRoundedRectangle(cornerRadii: ModalStack.cornerRadii(of: window), style: .continuous).path(in: bounds)
        NSGraphicsContext.current?.cgContext.addPath(corners.cgPath)
        NSGraphicsContext.current?.cgContext.clip()
        for image in images {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return result
    }

    private var removeRepository: CompactConfirmation {
        get throws {
            let confirmation = try #require(UIFixtures.confirmations.first { $0.name == "removeRepository" }?.confirmation)
            guard case .compactSheet(let compact) = confirmation.presentation else {
                throw CancellationError()
            }
            return compact
        }
    }

    @Test("a sheet in its card over the scrim, and an alert stacked over it")
    func sheetAndStackedAlert() async throws {
        let compact = try removeRepository
        let forcePush = try confirmation("forcePush")
        for appearance in SnapshotAppearance.allCases {
            let (modals, window) = window(appearance)
            defer { withExtendedLifetime(window) {} }
            modals.presentSheet(id: "sheet") { CompactConfirmationSheet(compact) { _ in } }
            assertSnapshot(try image(of: window, modals), named: "sheet", area: area, appearance: appearance)

            let alert = Task { await modals.alert(forcePush, id: "alert") }
            await waitUntil { modals.stack.layers.count == 2 }
            assertSnapshot(try image(of: window, modals), named: "alertOverSheet", area: area, appearance: appearance)
            modals.dismissAlert(id: "alert")
            _ = await alert.value
            modals.dismissSheet(id: "sheet")
        }
    }

    @Test("a card taller than its window scrolls inside the card")
    func scrollingCard() async throws {
        let (modals, window) = window(.light)
        defer { withExtendedLifetime(window) {} }
        let problems = AlertContent(
            title: "Menu Shortcut Problems",
            message: (1...30).map { "- ⇧⌘\($0): on Item \($0) and Other Item \($0)" }.joined(separator: "\n"),
            buttons: [AlertContent.Button("OK", role: .primary)]
        )
        let alert = Task { await modals.alert(problems, id: "problems") }
        await waitUntil { modals.stack.layers.count == 1 }
        assertSnapshot(try image(of: window, modals), named: "alert-scrolls", area: area, appearance: .light)
        modals.dismissAlert(id: "problems")
        _ = await alert.value
    }

    @Test("a sheet that fills the window takes it all, less its margins")
    func fillingSheet() async throws {
        let (modals, window) = window(.light)
        defer { withExtendedLifetime(window) {} }
        modals.presentSheet(id: "fill") {
            VStack(spacing: 0) {
                Text("Merge 3 commits into main from feature/login.")
                    .font(Typography.sheetTitle)
                    .foregroundStyle(.text)
                    .padding(Metrics.Sheet.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Hairline()
                Color(espalier: Palette.hunk)
            }
            .modalCardFillsWindow()
        }
        let layer = try #require(modals.stack.layers.last)
        layer.panel.contentView?.layoutSubtreeIfNeeded()
        await waitUntil { layer.state.fillsWindow }
        assertSnapshot(try image(of: window, modals), named: "sheet-fillsWindow", area: area, appearance: .light)
        modals.dismissSheet(id: "fill")
    }
}
