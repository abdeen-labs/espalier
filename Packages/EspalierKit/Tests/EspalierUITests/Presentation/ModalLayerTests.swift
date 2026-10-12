// The modal layer: alerts answer Return, Escape, and ⌘. as their buttons say,
// report the checkbox whatever the button, and close with `dismissAlert`;
// modals stack in the order they open, each covering the window and taking
// its keys from the ones below; a sheet's `onDismiss` runs once however it
// closes; the layers follow the window's frame and corners; focus comes back
// when a card closes; a confirmation in front of a write goes ahead only on
// its default button; a sheet that fills the window sets its layer to fill
// it. The windows are offscreen, so no panel is ordered in.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Modal layer", .hangGuard(minutes: 5)) @MainActor
struct ModalLayerTests {
    /// A presenter on an offscreen window (the presenter holds it weakly:
    /// keep it alive).
    private func presenter() -> (ModalPresenter, NSWindow) {
        let modals = ModalPresenter()
        let window = SnapshotWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        modals.window = window
        return (modals, window)
    }

    /// A key press in `window`.
    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }

    /// Shows `content` and returns the answer's task and the alert's layer.
    private func show(_ content: AlertContent, id: String? = nil, in modals: ModalPresenter) async throws -> (Task<AlertResponse, Never>, ModalLayer) {
        let count = modals.stack.layers.count
        let task = Task { await modals.alert(content, id: id) }
        await waitUntil { modals.stack.layers.count > count }
        return (task, try #require(modals.stack.layers.last))
    }

    nonisolated private static let discard = AlertContent(
        title: "Discard Changes?",
        message: "Are you sure you want to discard all changes to README.md?",
        buttons: [AlertContent.Button("Discard Changes", role: .destructive), AlertContent.Button("Cancel", role: .cancel)],
        suppressionTitle: AlertContent.doNotShowAgain,
        severity: .critical
    )

    nonisolated private static let close = AlertContent(title: "Fetch Failed", message: "The remote hung up.", buttons: [AlertContent.Button("Close", role: .primary)])

    nonisolated private static let notice = AlertContent(
        title: "Couldn't Read the Repository List",
        message: "It was moved aside.",
        buttons: [AlertContent.Button("OK", role: .primary), AlertContent.Button("Show in Finder", role: .secondary)]
    )

    @Test("Return presses the default button, destructive or not; Escape and ⌘. the cancel button, or an alert's only one", arguments: [
        NamedCase("Return on a destructive default", (ModalLayerTests.discard, "\r", NSEvent.ModifierFlags(), 0)),
        NamedCase("Enter", (ModalLayerTests.discard, "\u{3}", NSEvent.ModifierFlags(), 0)),
        NamedCase("Escape", (ModalLayerTests.discard, "\u{1b}", NSEvent.ModifierFlags(), 1)),
        NamedCase("⌘.", (ModalLayerTests.discard, ".", NSEvent.ModifierFlags.command, 1)),
        NamedCase("Escape with one button", (ModalLayerTests.close, "\u{1b}", NSEvent.ModifierFlags(), 0)),
    ])
    func keys(_ testCase: NamedCase<(AlertContent, String, NSEvent.ModifierFlags, Int)>) async throws {
        let (content, characters, modifiers, expected) = testCase.value
        let (modals, window) = presenter()
        defer { withExtendedLifetime(window) {} }
        let (task, layer) = try await show(content, in: modals)
        layer.panel.sendEvent(try key(characters, modifiers, in: layer.panel))
        #expect(await task.value == AlertResponse(buttonIndex: expected))
        #expect(!modals.isPresenting)
        #expect(modals.stack.layers.isEmpty)
    }

    @Test("Escape does nothing when no button cancels; other keys go on; a key equivalent answers too")
    func keysWithoutCancel() async throws {
        let (modals, window) = presenter()
        defer { withExtendedLifetime(window) {} }
        let (task, layer) = try await show(Self.notice, in: modals)
        layer.panel.sendEvent(try key("\u{1b}", in: layer.panel))
        #expect(!layer.panel.handleKey(try key("a", in: layer.panel)))
        #expect(!layer.panel.handleKey(try key("\r", .command, in: layer.panel)))
        #expect(modals.isPresenting)
        #expect(layer.panel.performKeyEquivalent(with: try key("\r", in: layer.panel)))
        #expect(await task.value == AlertResponse(buttonIndex: 0))
    }

    @Test("the checkbox is reported whatever the button")
    func suppression() async throws {
        let (modals, window) = presenter()
        defer { withExtendedLifetime(window) {} }
        for (characters, index) in [("\u{1b}", 1), ("\r", 0)] {
            let (task, layer) = try await show(Self.discard, in: modals)
            try #require(layer.alert).isSuppressed = true
            layer.panel.sendEvent(try key(characters, in: layer.panel))
            #expect(await task.value == AlertResponse(buttonIndex: index, isSuppressed: true))
        }
        let (task, layer) = try await show(Self.discard, in: modals)
        layer.panel.sendEvent(try key("\u{1b}", in: layer.panel))
        #expect(await task.value == AlertResponse(buttonIndex: 1, isSuppressed: false))
    }

    @Test("dismissAlert answers with the cancel button, or the last; an answered alert ignores later answers")
    func dismissAlert() async throws {
        let (modals, window) = presenter()
        defer { withExtendedLifetime(window) {} }
        let (cancelled, cancelledLayer) = try await show(Self.discard, id: "discard", in: modals)
        modals.dismissAlert(id: "discard")
        #expect(await cancelled.value == AlertResponse(buttonIndex: 1))
        #expect(cancelledLayer.isClosed)

        let (last, lastLayer) = try await show(Self.notice, id: "notice", in: modals)
        modals.dismissAlert(id: "notice")
        lastLayer.panel.sendEvent(try key("\r", in: lastLayer.panel))
        #expect(await last.value == AlertResponse(buttonIndex: 1))
        #expect(!modals.isPresenting)
        // Unknown ids do nothing.
        modals.dismissAlert(id: "notice")
    }

    @Test("modals stack in the order they open, each covering the window and taking its keys from the ones below")
    func stacking() async throws {
        let (modals, window) = presenter()
        defer { withExtendedLifetime(window) {} }
        #expect(modals.topmostWindow() === window)
        modals.presentSheet(id: "sheet") { Text("Sheet") }
        let sheet = try #require(modals.stack.layers.last)
        #expect(modals.topmostWindow() === sheet.panel)
        let (task, alert) = try await show(Self.discard, in: modals)
        #expect(modals.stack.layers.map(ObjectIdentifier.init) == [sheet, alert].map(ObjectIdentifier.init))
        #expect(modals.topmostWindow() === alert.panel)
        for layer in [sheet, alert] {
            #expect(layer.panel.frame == window.frame)
            #expect(!layer.panel.ignoresMouseEvents)
            #expect(layer.panel.coveredWindow === window)
            #expect(layer.state.phase == .shown)
        }

        // The sheet closing underneath leaves the alert on top.
        modals.dismissSheet(id: "sheet")
        #expect(sheet.isClosed)
        #expect(sheet.panel.ignoresMouseEvents)
        #expect(modals.topmostWindow() === alert.panel)
        #expect(modals.isPresenting)

        // A sheet opened over the alert goes on top; Escape on the alert
        // answers it alone.
        modals.presentSheet(id: "over") { Text("Over") }
        let over = try #require(modals.stack.layers.last)
        #expect(modals.topmostWindow() === over.panel)
        alert.panel.sendEvent(try key("\u{1b}", in: alert.panel))
        #expect(await task.value == AlertResponse(buttonIndex: 1))
        #expect(modals.isPresentingSheet(id: "over"))
        #expect(modals.topmostWindow() === over.panel)
        modals.dismissSheet(id: "over")
        #expect(modals.topmostWindow() === window)
        #expect(!modals.isPresenting)
    }

    /// Holds the `dismissModal` action a sheet's content gets.
    @MainActor
    private final class DismissBox {
        var dismiss: DismissModalAction?
    }

    /// Reads the sheet's `dismissModal` into `box`.
    private struct DismissReader: View {
        let box: DismissBox
        @Environment(\.dismissModal) private var dismissModal

        var body: some View {
            let _ = box.dismiss = dismissModal
            Text("Sheet")
        }
    }

    @Test("onDismiss runs once however a sheet closes: dismissSheet, dismissModal, a sheet replacing it, the window closing")
    func onDismiss() async throws {
        let (modals, window) = presenter()
        defer { withExtendedLifetime(window) {} }
        var dismissed: [String] = []

        modals.presentSheet(id: "a", onDismiss: { dismissed.append("dismissSheet") }) { Text("A") }
        modals.dismissSheet(id: "a")
        modals.dismissSheet(id: "a")
        #expect(dismissed == ["dismissSheet"])

        let box = DismissBox()
        modals.presentSheet(id: "b", onDismiss: { dismissed.append("dismissModal") }) { DismissReader(box: box) }
        modals.stack.layers.last?.panel.contentView?.layoutSubtreeIfNeeded()
        let dismiss = try #require(box.dismiss)
        dismiss()
        dismiss()
        #expect(dismissed == ["dismissSheet", "dismissModal"])
        #expect(!modals.isPresentingSheet(id: "b"))

        modals.presentSheet(id: "c", onDismiss: { dismissed.append("replaced") }) { Text("C") }
        modals.presentSheet(id: "c", onDismiss: { dismissed.append("window closed") }) { Text("C again") }
        #expect(dismissed == ["dismissSheet", "dismissModal", "replaced"])
        #expect(modals.stack.layers.count == 1)

        let (task, _) = try await show(Self.discard, in: modals)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(dismissed == ["dismissSheet", "dismissModal", "replaced", "window closed"])
        #expect(await task.value == AlertResponse(buttonIndex: 1))
        #expect(!modals.isPresenting)
        #expect(modals.stack.layers.isEmpty)
    }

    @Test("isPresenting is on while a sheet or an alert shows")
    func isPresenting() async throws {
        let (modals, window) = presenter()
        defer { withExtendedLifetime(window) {} }
        #expect(!modals.isPresenting)
        modals.presentSheet(id: "sheet") { Text("Sheet") }
        #expect(modals.isPresenting)
        let (task, layer) = try await show(Self.close, in: modals)
        modals.dismissSheet(id: "sheet")
        #expect(modals.isPresenting)
        layer.panel.sendEvent(try key("\r", in: layer.panel))
        #expect(!modals.isPresenting)
        _ = await task.value

        // Without a window a sheet doesn't show, and says so.
        let windowless = ModalPresenter()
        var dismissed = false
        #expect(windowless.presentSheet(id: "nowhere", onDismiss: { dismissed = true }) { Text("Nowhere") } == nil)
        #expect(dismissed)
        #expect(!windowless.isPresenting)
    }

    @Test("the layers follow the window's frame and take its corners")
    func frames() throws {
        let (modals, window) = presenter()
        defer { withExtendedLifetime(window) {} }
        modals.presentSheet(id: "sheet") { Text("Sheet") }
        let layer = try #require(modals.stack.layers.last)
        #expect(layer.panel.frame == window.frame)
        window.setFrame(CGRect(x: 40, y: 60, width: 1000, height: 700), display: false)
        #expect(layer.panel.frame == window.frame)
        window.setFrameOrigin(CGPoint(x: 200, y: 120))
        #expect(layer.panel.frame == window.frame)

        let radii = try #require(window.contentView?.superview?.effectiveCornerRadii)
        #expect(radii.topLeft > 0)
        #expect(layer.state.cornerRadii == RectangleCornerRadii(topLeading: radii.topLeft, bottomLeading: radii.bottomLeft, bottomTrailing: radii.bottomRight, topTrailing: radii.topRight))

        // An open panel shown on the layer as a sheet attaches below the
        // window's title bar, as on the window.
        let sheetWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let position = layer.panel.delegate?.window?(layer.panel, willPositionSheet: sheetWindow, using: .zero)
        #expect(position == CGRect(x: 0, y: window.contentLayoutRect.maxY, width: window.frame.width, height: 0))

        // Moved to another window, the layer covers it instead.
        let other = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        defer { withExtendedLifetime(other) {} }
        modals.window = other
        #expect(layer.panel.frame == other.frame)
        #expect(layer.panel.coveredWindow === other)
        modals.dismissSheet(id: "sheet")
    }

    /// A sheet with a field and the scaffold's buttons.
    private struct FieldSheet: View {
        let onCancel: () -> Void
        @State private var name = ""

        var body: some View {
            SheetScaffold("Rename Branch") {
                TextField("Name", text: $name)
            } buttons: {
                SheetButtons("Rename", cancel: onCancel, confirm: {})
            }
        }
    }

    @Test("a sheet's card takes focus in its first field, ⌘. presses its Cancel, and focus goes back when it closes")
    func sheetFocusAndKeys() async throws {
        let (modals, window) = presenter()
        defer { withExtendedLifetime(window) {} }
        let field = NSTextField(frame: CGRect(x: 20, y: 20, width: 200, height: 22))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))

        var cancelled = 0
        modals.presentSheet(id: "rename") { FieldSheet(onCancel: { cancelled += 1 }) }
        let layer = try #require(modals.stack.layers.last)
        layer.panel.contentView?.layoutSubtreeIfNeeded()
        layer.focusFirstField()
        let editor = try #require(layer.panel.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)

        #expect(layer.panel.handleKey(try key(".", .command, in: layer.panel)))
        #expect(cancelled == 1)

        // Something moved the window's focus meanwhile: it comes back.
        window.makeFirstResponder(nil)
        modals.dismissSheet(id: "rename")
        let restored = try #require(window.firstResponder as? NSTextView)
        #expect(restored.delegate === field)
    }

    @Test("VoiceOver sees a sheet's card as a modal dialog")
    func dialog() async throws {
        let (modals, window) = presenter()
        defer { withExtendedLifetime(window) {} }
        modals.presentSheet(id: "rename") { FieldSheet(onCancel: {}) }
        let sheet = try #require(modals.stack.layers.last)
        sheet.panel.contentView?.layoutSubtreeIfNeeded()
        await waitUntil { sheet.state.title != nil }
        #expect(sheet.panel.accessibilitySubrole() == .dialog)
        #expect(sheet.panel.isAccessibilityModal())
        modals.dismissSheet(id: "rename")
    }

    @Test("a confirmation in front of a write goes ahead on Return, its checkbox with it; Escape, ⌘., and the window closing cancel it", .offline, arguments: [
        NamedCase("Return", ("\r", NSEvent.ModifierFlags(), false, true)),
        NamedCase("Return with the checkbox", ("\r", NSEvent.ModifierFlags(), true, true)),
        NamedCase("Escape with the checkbox", ("\u{1b}", NSEvent.ModifierFlags(), true, false)),
        NamedCase("⌘.", (".", NSEvent.ModifierFlags.command, false, false)),
        NamedCase("the window closing", ("", NSEvent.ModifierFlags(), false, false)),
    ])
    func confirmation(_ testCase: NamedCase<(String, NSEvent.ModifierFlags, Bool, Bool)>) async throws {
        let (characters, modifiers, checksBox, goesAhead) = testCase.value
        let harness = try AppHarness()
        let app = await harness.loadedApp()
        let context = WindowContext(app: app, registersFeatures: false)
        let window = SnapshotWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        context.modals.window = window
        defer { withExtendedLifetime(window) {} }
        #expect(app.preferences.confirmForcePush)

        var calls = 0
        let task = Task {
            await context.presenter.perform { _ throws(OperationError) -> String in
                calls += 1
                if calls == 1 {
                    throw OperationError(.confirmationRequired(.forcePush(upstreamBranch: "origin/main")), operation: .push)
                }
                return "pushed"
            }
        }
        await waitUntil { context.presenter.confirmation != nil }
        ConfirmationHost.present(try #require(context.presenter.confirmation), in: context)
        await waitUntil { context.modals.stack.layers.count == 1 }
        let layer = try #require(context.modals.stack.layers.last)
        #expect(layer.alert?.content.suppressionTitle != nil)
        layer.alert?.isSuppressed = checksBox
        if characters.isEmpty {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        } else {
            layer.panel.sendEvent(try key(characters, modifiers, in: layer.panel))
        }

        #expect(await task.value == (goesAhead ? "pushed" : nil))
        #expect(calls == (goesAhead ? 2 : 1))
        #expect(app.preferences.confirmForcePush == !(goesAhead && checksBox))
        #expect(context.presenter.confirmation == nil)
        #expect(!context.modals.isPresenting)
        await app.idle()
    }

    @Test("an alert with no window is a card on its own, centered on the screen, which its keys answer")
    func appModal() throws {
        let screen = try #require(NSScreen.main)
        let model = AlertCardModel(Self.discard)
        var answers: [AlertResponse] = []
        model.onAnswer = { answers.append($0) }
        let panel = AppModalAlert.makePanel(for: model, on: screen)
        let visible = screen.visibleFrame
        #expect(abs(panel.frame.midX - visible.midX) <= 1)
        #expect(abs(panel.frame.midY - visible.midY) <= 1)
        #expect(panel.frame.width > Metrics.Sheet.compactWidth)
        #expect(panel.frame.width <= Metrics.Sheet.compactWidth + 2 * Metrics.Sheet.shadowInset + 1)
        #expect(panel.coveredWindow == nil)
        panel.sendEvent(try key("\u{1b}", in: panel))
        #expect(answers == [AlertResponse(buttonIndex: 1)])
    }

    @Test("a sheet that fills the window sets its layer to fill it")
    func fillingSheet() async throws {
        let (modals, window) = presenter()
        defer { withExtendedLifetime(window) {} }
        modals.presentSheet(id: "fill") {
            Text("Sheet")
                .modalCardFillsWindow()
        }
        let layer = try #require(modals.stack.layers.last)
        layer.panel.contentView?.layoutSubtreeIfNeeded()
        await waitUntil { layer.state.fillsWindow }
        modals.dismissSheet(id: "fill")
    }
}
