// App updates, through Sparkle: it checks the appcast at Info.plist's
// SUFeedURL in the background, verifies the appcast (SURequireSignedFeed)
// and an update before unpacking it (SUVerifyUpdateBeforeExtraction) with
// SUPublicEDKey, and shows its own windows for it. Espalier ▸ Check for
// Updates… checks now. docs/RELEASING.md publishes the appcast.

import EspalierSupport
import Observation
import Sparkle

/// Sparkle's updater, for the app's lifetime. It starts once the main
/// window has appeared (`start()`), and only in Release builds: a Debug
/// build has its own bundle identifier, and Sparkle would offer to replace
/// it with the released app.
@MainActor @Observable
public final class Updater {
    /// Whether Check for Updates… can run now: false while a check or an
    /// update is under way, before the updater starts, and in Debug builds.
    public private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var isStarted = false

    public init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Starts the updater, once; the main window calls it as it appears.
    /// Sparkle may open a window as soon as it starts (asking whether to
    /// check automatically). Started before the main window opens at
    /// launch, that window takes the main window's place, and closing it
    /// closes the app's last window, which quits Espalier.
    func start() {
        guard !isStarted, !BuildConfiguration.isDebug else {
            return
        }
        isStarted = true
        controller.startUpdater()
    }

    /// Checks for an update now, with Sparkle's windows.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
