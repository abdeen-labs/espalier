import AppKit

/// Tells the app model when Espalier becomes or stops being the active app.
@MainActor
public final class ApplicationActivityMonitor {
    private weak var model: AppModel?
    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    /// Starts observing, and applies the current state.
    public init(model: AppModel, center: NotificationCenter = .default, isActive: Bool = NSApplication.shared.isActive) {
        self.model = model
        self.center = center
        model.setActive(isActive)
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated {
                    model?.setActive(true)
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated {
                    model?.setActive(false)
                }
            },
        ]
    }

    isolated deinit {
        stop()
    }

    /// Stops observing.
    public func stop() {
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }
}
