// The Settings window's own context: it stays on screen, it shows the
// selected pane or waits for the app to launch, and recoveries open their
// pane.

import AppKit
import EspalierCore
import EspalierCoreTestSupport
import Foundation
import GitKit
import SwiftUI
import Testing
import TestSupport
@testable import EspalierUI

@Suite("Settings window", .offline) @MainActor
struct SettingsWindowTests {
    @Test("a pane that grows the window past the screen's bottom moves it up; one that fits leaves it")
    func staysOnScreen() {
        // A small display's visible frame, below the menu bar and above the Dock.
        let visible = CGRect(x: 0, y: 80, width: 1372, height: 786)
        // The window keeps its top edge (y 866) as the Git pane makes it 760 tall.
        let grown = CGRect(x: 400, y: 106, width: 560, height: 760)
        #expect(SettingsWindowFitter.fitted(grown, in: visible) == grown)
        let pastBottom = CGRect(x: 400, y: 20, width: 560, height: 760)
        #expect(SettingsWindowFitter.fitted(pastBottom, in: visible) == CGRect(x: 400, y: 80, width: 560, height: 760))
        // Taller than the screen: its top edge goes to the screen's top.
        let taller = CGRect(x: 400, y: -40, width: 560, height: 900)
        #expect(SettingsWindowFitter.fitted(taller, in: visible) == CGRect(x: 400, y: -34, width: 560, height: 900))
    }

    @Test("the Settings view builds every pane, and waits for the app to launch")
    func rendersEveryPane() async throws {
        try await withIsolatedGitConfig { _ in
            let harness = try AppHarness()
            let app = harness.makeApp()
            let navigation = SettingsNavigation()
            // Each tab shows its own pane: no two look the same.
            var panes: [Data: SettingsTab] = [:]
            for tab in SettingsTab.allCases {
                navigation.selectedTab = tab
                let image = Snapshot.render(
                    SettingsView(model: app).environment(navigation),
                    size: CGSize(width: Metrics.SettingsWindow.width, height: 600),
                    appearance: .light
                )
                let png = try #require(image.representation(using: .png, properties: [:]))
                #expect(panes[png] == nil, "\(tab) shows what \(String(describing: panes[png])) shows")
                panes[png] = tab
            }
            // Before the app launches: the window at its size, the sidebar
            // beside a spinner.
            let launching = Snapshot.render(SettingsView(model: nil).environment(navigation), appearance: .light)
            #expect(launching.pixelsWide == Int(Metrics.SettingsWindow.width))
            #expect(launching.pixelsHigh == Int(Metrics.SettingsWindow.height))
        }
    }

    @Test("a recovery shown in Settings opens its pane")
    func recoveryOpensPane() async throws {
        let harness = try AppHarness()
        let app = harness.makeApp()
        app.preferences.hasShownWelcomeFlow = true
        let pane = SettingsPane.integrations
        let (context, navigation) = SettingsFixtures.context(app, tab: .accounts)

        // As the Settings window's error alert does: close it, run the
        // button's recovery.
        let error = OperationError(.integration(.shell(message: "Could not find executable for 'Kitty'.")), operation: .openInShell, recoveries: [.openSettings(pane)])
        context.presenter.present(error)
        let presented = try #require(context.presenter.error)
        await context.presenter.recover(presented.id, with: .openSettings(pane))
        await context.actions.idle()

        #expect(navigation.selectedTab == .integrations)
        #expect(context.presenter.error == nil)
    }
}
