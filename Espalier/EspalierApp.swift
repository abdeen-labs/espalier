import EspalierUI
import SwiftUI

/// Espalier's entry point. The scenes, the delegate, and everything else
/// live in EspalierUI.
@main
struct EspalierApp: App {
    @NSApplicationDelegateAdaptor(EspalierAppDelegate.self) private var appDelegate

    var body: some Scene {
        EspalierScenes(delegate: appDelegate)
    }
}
