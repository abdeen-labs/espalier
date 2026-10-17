// The Settings window as a titled window draws it offscreen, with its
// chrome: Appearance scrolled so its first section has passed under the
// header band, where the pane's scroll view reaches up under the titlebar.
// It's drawn in the run's look: `--look islands-lagoon` shows the pane as a
// card.

import AppKit
@testable import EspalierCore
import EspalierCoreTestSupport
import Foundation
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Settings window", .captures, .offline, .serialized, .hangGuard(minutes: 5)) @MainActor
struct SettingsWindowCaptures {
    private let area = "Settings"

    @Test("Appearance scrolled under the header band")
    func appearanceScrolled() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        for appearance in CaptureAppearance.allCases {
            let stage = SettingsWindowStage(appearance: appearance) {
                SettingsLayout(selection: .constant(.appearance)) {
                    AppearanceForm(preferences: app.preferences, openAppearanceSettings: {})
                }
            }
            await stage.settle()
            stage.scroll(by: 60)
            await stage.settle()
            let image = Capture.image(of: stage.frame)
            stage.close()
            capture(named: "appearance-scrolled", area: area, appearances: [appearance]) { _ in image }
        }
    }
}

/// The Settings window on an offscreen titled window, with the chrome
/// `SettingsWindowChrome` gives it.
@MainActor
private final class SettingsWindowStage {
    let window: CaptureWindow

    init(appearance: CaptureAppearance, @ViewBuilder content: () -> some View) {
        _ = Capture.look
        let size = CGSize(width: Metrics.SettingsWindow.width, height: Metrics.SettingsWindow.height)
        let controller = NSHostingController(rootView: Capture.prepared(content().frame(width: size.width, height: size.height)))
        controller.sceneBridgingOptions = [.toolbars]
        window = CaptureWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance.appearance
        window.contentViewController = controller
        SettingsWindowChrome.apply(to: window)
        SettingsWindowChrome.fillWindow(window)
        window.setFrame(CGRect(origin: .zero, size: size), display: false)
    }

    /// The window's frame view: its content, titlebar, and buttons.
    var frame: NSView {
        window.contentView?.superview ?? window.contentView ?? NSView()
    }

    /// Lets the toolbar and the pane's scroll view finish, on later turns
    /// of the run loop.
    func settle() async {
        for _ in 0..<5 {
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else {
                return
            }
        }
    }

    /// Scrolls the pane down by `offset`.
    func scroll(by offset: CGFloat) {
        for scrollView in frame.captureDescendants(NSScrollView.self) {
            let clip = scrollView.contentView
            clip.scroll(to: CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + offset))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// Takes the window down, and its toolbar with it.
    func close() {
        window.contentViewController = nil
        window.toolbar = nil
        window.close()
    }
}
