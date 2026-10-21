// Espalier's alert card in each of its layouts, Reset to Commit's question,
// and a link's questions (a branch, a pull request, one from a fork),
// through the same mappings the hosts use where there's one, and the modal
// layer over a window: a sheet in its card over the scrim, an alert stacked
// over it, a card that scrolls, and a sheet that fills the window. The
// window images are the window's content with each layer's panel drawn over
// it, in the window's corners.

import AppKit
import EspalierCore
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Modals", .captures, .hangGuard(minutes: 5)) @MainActor
struct ModalCaptures {
    private let area = "Modals"

    private func confirmation(_ name: String) throws -> AlertContent {
        try #require(UIFixtures.confirmations.first { $0.name == name }?.confirmation).alertContent(Capture.numberFormat)
    }

    /// An alert's card on its layer, with its shadow; `prepare` sets its
    /// state (the checkbox) first.
    private func card(_ content: AlertContent, prepare: (AlertCardModel) -> Void = { _ in }) -> some View {
        let model = AlertCardModel(content)
        prepare(model)
        let state = ModalLayerState(coversWindow: false, title: content.title)
        state.phase = .shown
        return ModalLayerView(state: state, content: AnyView(AlertCard(model: model)))
    }

    // MARK: The alert

    @Test("alerts: plain, critical with a list and the checkbox, a destructive default, three buttons, replacing the command line tool")
    func alerts() throws {
        let prompt = try #require(UIFixtures.prompts.first { $0.name == "addSSHHost" }?.prompt)
        guard case .alert(let ssh, _) = PromptPresentation.make(prompt, finish: { _ in }) else {
            Issue.record("addSSHHost isn't an alert")
            return
        }
        capture(card(ssh), named: "alert-plain", area: area)
        capture(card(try confirmation("discardChanges")), named: "alert-critical", area: area)
        let quit = try #require(QuitGuardReasons(runningOperation: .rebase, repositoriesWithUnfinishedMessages: ["espalier"]).alert(Capture.numberFormat))
        capture(card(quit), named: "alert-destructive", area: area)
        let push = AlertContent(
            title: "Push Local Changes?",
            message: "feature/login has 3 local commits that haven't been pushed. Push them before opening the pull request?",
            buttons: [
                AlertContent.Button("Push Commits", role: .primary),
                AlertContent.Button("Create Without Pushing", role: .secondary),
                AlertContent.Button("Cancel", role: .cancel),
            ]
        )
        capture(card(push), named: "alert-threeButtons", area: area)
        capture(card(try confirmation("replaceCommandLineTool")), named: "alert-replaceCommandLineTool", area: area)
        capture(card(try confirmation("replaceCommandLineTool-file")), named: "alert-replaceCommandLineTool-file", area: area)
        capture(card(try confirmation("replaceCommandLineTool-unexamined")), named: "alert-replaceCommandLineTool-unexamined", area: area)
    }

    @Test("Reset to Commit's question, on a clean tree and with changes", arguments: ["resetToCommit", "resetWithChanges"])
    func resetAlert(name: String) throws {
        capture(card(try confirmation(name)), named: "alert-\(name)", area: area)
    }

    @Test("a link's questions: its branch, its pull request, and a pull request from a fork", arguments: [
        "checkoutLinkedBranch", "checkoutLinkedPullRequest", "checkoutLinkedPullRequest-fork",
    ])
    func linkAlert(name: String) throws {
        capture(card(try confirmation(name)), named: "alert-\(name)", area: area)
    }

    @Test("alerts: the checkbox on, a list of ten and the rest counted, a long URL")
    func alertContent() throws {
        capture(card(try confirmation("discardChanges-one")) { $0.isSuppressed = true }, named: "alert-suppressed", area: area)
        let files = (1...12).map { "Sources/Feature/File\($0).swift" }
        let overwritten = AlertContent(
            title: "Checkout Failed",
            message: AlertList.insert(files, intoMessage: "Your local changes to these files would be overwritten:\n\nYou can stash your changes now and restore them afterward.", numberFormat: Capture.numberFormat),
            buttons: [AlertContent.Button("Stash Changes and Retry", role: .primary), AlertContent.Button("Close", role: .cancel)]
        )
        capture(card(overwritten), named: "alert-list", area: area)
        let remote = AlertContent(
            title: "Update the Upstream Remote?",
            message: "The upstream remote points to https://github.example.com/an-organization-with-a-long-name/a-repository-with-an-even-longer-name.git, not the parent repository.",
            buttons: [AlertContent.Button("Update", role: .destructive), AlertContent.Button("Ignore", role: .cancel)]
        )
        capture(card(remote), named: "alert-url", area: area)
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
    private func window(_ appearance: CaptureAppearance, size: CGSize = CGSize(width: 720, height: 480)) -> (ModalPresenter, NSWindow) {
        let window = CaptureWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = appearance.appearance
        window.contentView = NSHostingView(rootView: Capture.prepared(Backdrop()))
        let modals = ModalPresenter()
        modals.environment = { AnyView(Capture.prepared($0)) }
        modals.window = window
        return (modals, window)
    }

    /// The window's content with its layers over it, in its corners.
    private func image(of window: NSWindow, _ modals: ModalPresenter) throws -> NSBitmapImageRep {
        let content = try #require(window.contentView)
        content.frame = CGRect(origin: .zero, size: window.frame.size)
        content.layoutSubtreeIfNeeded()
        var images = [Capture.image(of: content)]
        for layer in modals.stack.layers {
            let view = try #require(layer.panel.contentView)
            view.layoutSubtreeIfNeeded()
            images.append(Capture.image(of: view))
        }
        let size = window.frame.size
        let result = Capture.bitmap(size)
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

    /// Writes the window with its layers as `name`, in `appearance`.
    private func write(_ window: NSWindow, _ modals: ModalPresenter, named name: String, appearance: CaptureAppearance) throws {
        let image = try image(of: window, modals)
        capture(named: name, area: area, appearances: [appearance]) { _ in image }
    }

    @Test("a sheet in its card over the scrim, and an alert stacked over it")
    func sheetAndStackedAlert() async throws {
        let confirmation = try #require(UIFixtures.confirmations.first { $0.name == "removeRepository" }?.confirmation)
        guard case .compactSheet(let compact) = confirmation.presentation(Capture.numberFormat) else {
            Issue.record("removeRepository is an alert, not a sheet")
            return
        }
        let forcePush = try self.confirmation("forcePush")
        for appearance in CaptureAppearance.allCases {
            let (modals, window) = window(appearance)
            defer { withExtendedLifetime(window) {} }
            modals.presentSheet(id: "sheet") { CompactConfirmationSheet(compact) { _ in } }
            try write(window, modals, named: "sheet", appearance: appearance)

            let alert = Task { await modals.alert(forcePush, id: "alert") }
            await waitUntil { modals.stack.layers.count == 2 }
            try write(window, modals, named: "alertOverSheet", appearance: appearance)
            modals.dismissAlert(id: "alert")
            _ = await alert.value
            modals.dismissSheet(id: "sheet")
        }
    }

    @Test("a card taller than its window scrolls inside the card")
    func scrollingCard() async throws {
        let problems = AlertContent(
            title: "Menu Shortcut Problems",
            message: (1...30).map { "- ⇧⌘\($0): on Item \($0) and Other Item \($0)" }.joined(separator: "\n"),
            buttons: [AlertContent.Button("OK", role: .primary)]
        )
        for appearance in CaptureAppearance.allCases {
            let (modals, window) = window(appearance)
            defer { withExtendedLifetime(window) {} }
            let alert = Task { await modals.alert(problems, id: "problems") }
            await waitUntil { modals.stack.layers.count == 1 }
            try write(window, modals, named: "alert-scrolls", appearance: appearance)
            modals.dismissAlert(id: "problems")
            _ = await alert.value
        }
    }

    @Test("a sheet that fills the window takes it all, less its margins")
    func fillingSheet() async throws {
        for appearance in CaptureAppearance.allCases {
            let (modals, window) = window(appearance)
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
            try write(window, modals, named: "sheet-fillsWindow", appearance: appearance)
            modals.dismissSheet(id: "fill")
        }
    }
}
