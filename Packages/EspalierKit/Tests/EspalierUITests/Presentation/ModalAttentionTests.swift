// A modal that appears while the app is inactive beeps and bounces the Dock
// icon; while it's active, nothing.

import AppKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Modal attention", .hangGuard(minutes: 5)) @MainActor
struct ModalAttentionTests {
    /// Whether the app is active, and the attention requests made.
    @MainActor
    private final class Recorder {
        var isActive = true
        var requests = 0
    }

    /// A presenter on an offscreen window (the presenter holds it weakly:
    /// keep it alive), asking `recorder` for attention.
    private func presenter(_ recorder: Recorder) -> (ModalPresenter, NSWindow) {
        let modals = ModalPresenter()
        modals.attention = ModalAttention(isAppActive: { recorder.isActive }, request: { recorder.requests += 1 })
        let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        modals.window = window
        return (modals, window)
    }

    @Test("a sheet shown while Espalier is inactive asks for attention; while it's active, never")
    func sheets() {
        let recorder = Recorder()
        let (active, activeWindow) = presenter(recorder)
        defer { withExtendedLifetime(activeWindow) {} }
        active.presentSheet(id: "active") { Text("Active") }
        #expect(active.isPresentingSheet(id: "active"))
        #expect(recorder.requests == 0)

        recorder.isActive = false
        let (inactive, inactiveWindow) = presenter(recorder)
        defer { withExtendedLifetime(inactiveWindow) {} }
        inactive.presentSheet(id: "inactive") { Text("Inactive") }
        #expect(inactive.isPresentingSheet(id: "inactive"))
        #expect(recorder.requests == 1)

        // Without a window nothing shows, so nothing asks.
        let windowless = ModalPresenter()
        windowless.attention = ModalAttention(isAppActive: { recorder.isActive }, request: { recorder.requests += 1 })
        windowless.presentSheet(id: "nowhere") { Text("Nowhere") }
        #expect(recorder.requests == 1)
    }

    @Test("an alert shown while Espalier is inactive asks for attention")
    func alerts() async {
        let recorder = Recorder()
        let (modals, window) = presenter(recorder)
        defer { withExtendedLifetime(window) {} }
        recorder.isActive = false
        let content = AlertContent(title: "Push failed", message: "The remote refused the push.", buttons: [AlertContent.Button("Close", role: .primary)])
        let task = Task { await modals.alert(content, id: "error") }
        await waitUntil { modals.isPresenting }
        #expect(recorder.requests == 1)
        modals.dismissAlert(id: "error")
        _ = await task.value
        #expect(!modals.isPresenting)
    }
}
