// Presents alerts and sheets on a window, as Espalier's cards on the
// window's modal layer (`ModalStack`). Each modal stacks above the ones
// already showing, so a confirmation or a prompt git is waiting on can
// appear over a feature's sheet; each blocks the ones below. With no window,
// an alert shows on its own, app-modally (`AppModalAlert`).

import AppKit
import EspalierSupport
import Observation
import SwiftUI
import os

private let logger = Log.logger(category: "modals")

/// Closes the sheet a view is in. `ModalPresenter` puts it in each sheet's
/// environment.
public struct DismissModalAction: Sendable {
    let action: @MainActor @Sendable () -> Void

    @MainActor
    public func callAsFunction() {
        action()
    }
}

extension EnvironmentValues {
    /// Closes the modal sheet the view is in (sheets shown through
    /// `ModalPresenter`).
    @Entry public var dismissModal = DismissModalAction(action: {})
}

/// A sheet shown by `ModalPresenter`.
@MainActor
public final class ModalSheet: Identifiable {
    public let id: String
    fileprivate var end: (() -> Void)?
    fileprivate let onDismiss: (() -> Void)?

    fileprivate init(id: String, onDismiss: (() -> Void)?) {
        self.id = id
        self.onDismiss = onDismiss
    }
}

/// How a modal asks for the user's attention when Espalier isn't the active
/// app: a beep and a critical Dock bounce.
@MainActor
struct ModalAttention {
    var isAppActive: @MainActor () -> Bool
    var request: @MainActor () -> Void

    /// The app's own state. Outside an app bundle (the test runner) it
    /// counts as active, so tests never beep.
    static let live = ModalAttention(
        isAppActive: { Bundle.main.bundleURL.pathExtension != "app" || NSApplication.shared.isActive },
        request: {
            NSSound.beep()
            NSApplication.shared.requestUserAttention(.criticalRequest)
        }
    )
}

/// Shows alerts and sheets on a window, each above the ones already
/// showing.
@MainActor @Observable
public final class ModalPresenter {
    /// The window modals cover; the window observer sets it.
    @ObservationIgnored public weak var window: NSWindow? {
        didSet {
            stack.attach(to: window)
        }
    }
    /// Applies the window's environment to a modal's content.
    @ObservationIgnored var environment: ((AnyView) -> AnyView)?
    /// Asks for attention when a modal appears while Espalier is inactive.
    @ObservationIgnored var attention = ModalAttention.live
    /// The window's modal layers.
    @ObservationIgnored let stack = ModalStack()

    private var sheets: [String: ModalSheet] = [:]
    private var alertCount = 0
    /// Every alert showing, and those shown with an id by it.
    @ObservationIgnored private var shownAlerts: [AlertCardModel] = []
    @ObservationIgnored private var alerts: [String: AlertCardModel] = [:]

    /// Whether an alert or a sheet is showing (menus disable themselves).
    public var isPresenting: Bool {
        !sheets.isEmpty || alertCount > 0
    }

    public init() {
        stack.onWindowClose = { [weak self] in
            self?.dismissAll()
        }
    }

    /// Whether a sheet with `id` is showing.
    public func isPresentingSheet(id: String) -> Bool {
        sheets[id] != nil
    }

    /// Shows `content` and waits for the user's answer. Without a window it
    /// shows on its own, app-modally. An alert with an `id` can be closed
    /// with `dismissAlert(id:)`, which answers with its cancel button.
    public func alert(_ content: AlertContent, id: String? = nil) async -> AlertResponse {
        requestAttentionIfInactive()
        guard window != nil else {
            return AppModalAlert.run(content)
        }
        let model = AlertCardModel(content)
        let layer = ModalLayer(content: decorate(AnyView(AlertCard(model: model))), alert: model)
        alertCount += 1
        shownAlerts.append(model)
        if let id {
            alerts[id] = model
        }
        return await withCheckedContinuation { continuation in
            model.onAnswer = { [weak self, weak layer] response in
                if let self {
                    self.alertCount -= 1
                    self.shownAlerts.removeAll { $0 === model }
                    if let id, self.alerts[id] === model {
                        self.alerts[id] = nil
                    }
                    if let layer {
                        self.stack.remove(layer)
                    }
                }
                continuation.resume(returning: response)
            }
            stack.push(layer)
        }
    }

    /// Closes the alert shown with `id`, if it's showing, answering with its
    /// cancel button.
    public func dismissAlert(id: String) {
        alerts[id]?.answer(nil)
    }

    /// Shows a SwiftUI sheet above the modals already showing. A sheet with
    /// the same id that's already showing is replaced.
    ///
    /// The content gets the window's environment and a `dismissModal`
    /// action; `onDismiss` runs when the sheet closes, however it closes.
    @discardableResult
    public func presentSheet<Content: View>(id: String, onDismiss: (() -> Void)? = nil, @ViewBuilder content: () -> Content) -> ModalSheet? {
        dismissSheet(id: id)
        guard window != nil else {
            logger.error("No window to show the sheet \(id, privacy: .public) on")
            onDismiss?()
            return nil
        }
        let sheet = ModalSheet(id: id, onDismiss: onDismiss)
        sheets[id] = sheet
        let dismiss = DismissModalAction { [weak self] in
            self?.dismissSheet(id: id)
        }
        let layer = ModalLayer(content: decorate(AnyView(content().environment(\.dismissModal, dismiss))))
        sheet.end = { [weak self, weak layer] in
            if let self, let layer {
                self.stack.remove(layer)
            }
        }
        stack.push(layer)
        requestAttentionIfInactive()
        return sheet
    }

    /// Closes the sheet with `id`, if it's showing.
    public func dismissSheet(id: String) {
        guard let sheet = sheets[id] else {
            return
        }
        sheets[id] = nil
        let end = sheet.end
        sheet.end = nil
        end?()
        sheet.onDismiss?()
    }

    /// The window a new modal goes on: the top modal's, or the window.
    /// Panels that show as sheets attach to it.
    func topmostWindow() -> NSWindow? {
        stack.topWindow
    }

    /// The window closed: every modal on it closes, sheets as when
    /// dismissed and alerts with their cancel button.
    private func dismissAll() {
        for id in Array(sheets.keys) {
            dismissSheet(id: id)
        }
        for model in shownAlerts.reversed() {
            model.answer(nil)
        }
    }

    /// `content` with the window's environment.
    private func decorate(_ content: AnyView) -> AnyView {
        environment?(content) ?? content
    }

    /// A modal appeared: while Espalier is inactive it beeps and bounces the
    /// Dock icon until the user comes back, so an error or a question that
    /// arrives after the user switched apps doesn't sit unnoticed.
    private func requestAttentionIfInactive() {
        if !attention.isAppActive() {
            attention.request()
        }
    }
}
