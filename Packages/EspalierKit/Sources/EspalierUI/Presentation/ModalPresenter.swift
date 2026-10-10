// Presents alerts and sheets on the main window. Each modal attaches to the
// topmost sheet of the window, so a confirmation or a prompt git is waiting
// on can appear over a feature's sheet.

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
/// app: a beep and a critical Dock bounce, as macOS does for an inactive
/// app's modal panel.
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

/// Shows alerts and sheets attached to the main window, on top of any sheet
/// already showing.
@MainActor @Observable
public final class ModalPresenter {
    /// The window modals attach to; the window observer sets it.
    @ObservationIgnored public weak var window: NSWindow?
    /// Applies the window's environment to a sheet's content.
    @ObservationIgnored var environment: ((AnyView) -> AnyView)?
    /// Asks for attention when a modal appears while Espalier is inactive.
    @ObservationIgnored var attention = ModalAttention.live

    private var sheets: [String: ModalSheet] = [:]
    private var alertCount = 0
    @ObservationIgnored private var alerts: [String: NSAlert] = [:]

    /// Whether an alert or a sheet is showing (menus disable themselves).
    public var isPresenting: Bool {
        !sheets.isEmpty || alertCount > 0
    }

    public init() {}

    /// Whether a sheet with `id` is showing.
    public func isPresentingSheet(id: String) -> Bool {
        sheets[id] != nil
    }

    /// Shows `content` and waits for the user's answer. Without a window it
    /// runs as an app-modal alert. An alert with an `id` can be closed with
    /// `dismissAlert(id:)`, which answers with its cancel button.
    public func alert(_ content: AlertContent, id: String? = nil) async -> AlertResponse {
        let alert = content.makeAlert()
        requestAttentionIfInactive()
        guard let window = topmostWindow() else {
            let modalResponse = alert.runModal()
            return content.response(modalResponse, alert: alert)
        }
        if let id {
            alerts[id] = alert
        }
        alertCount += 1
        let modalResponse = await alert.beginSheetModal(for: window)
        alertCount -= 1
        if let id, alerts[id] === alert {
            alerts[id] = nil
        }
        return content.response(modalResponse, alert: alert)
    }

    /// Closes the alert shown with `id`, if it's showing.
    public func dismissAlert(id: String) {
        guard let alert = alerts.removeValue(forKey: id), let parent = alert.window.sheetParent else {
            return
        }
        parent.endSheet(alert.window, returnCode: .abort)
    }

    /// Shows a SwiftUI sheet on the topmost sheet of the window. A sheet
    /// with the same id that's already showing is replaced.
    ///
    /// The content gets the window's environment, a `dismissModal` action,
    /// and the sheet's presentation (`sheetPresentation()`); `onDismiss`
    /// runs when the sheet closes, however it closes.
    @discardableResult
    public func presentSheet<Content: View>(id: String, onDismiss: (() -> Void)? = nil, @ViewBuilder content: () -> Content) -> ModalSheet? {
        dismissSheet(id: id)
        guard let window = topmostWindow() else {
            logger.error("No window to show the sheet \(id, privacy: .public) on")
            onDismiss?()
            return nil
        }
        let sheet = ModalSheet(id: id, onDismiss: onDismiss)
        sheets[id] = sheet
        let dismiss = DismissModalAction { [weak self] in
            self?.dismissSheet(id: id)
        }
        let body = AnyView(content().sheetPresentation().environment(\.dismissModal, dismiss))
        let decorated = environment?(body) ?? body
        let representation = window.beginSheet(content: { decorated }, completionHandler: { [weak self] in
            self?.sheetDidEnd(id: id, sheet: sheet)
        })
        requestAttentionIfInactive()
        sheet.end = { [weak window] in
            window?.endSheet(representation)
        }
        return sheet
    }

    /// Closes the sheet with `id`, if it's showing.
    public func dismissSheet(id: String) {
        guard let sheet = sheets[id] else {
            return
        }
        if let end = sheet.end {
            sheet.end = nil
            end()
        } else {
            sheetDidEnd(id: id, sheet: sheet)
        }
    }

    private func sheetDidEnd(id: String, sheet: ModalSheet) {
        guard sheets[id] === sheet else {
            return
        }
        sheets[id] = nil
        sheet.end = nil
        sheet.onDismiss?()
    }

    /// A modal appeared: while Espalier is inactive it beeps and bounces the
    /// Dock icon until the user comes back, so an error or a question that
    /// arrives after the user switched apps doesn't sit unnoticed.
    private func requestAttentionIfInactive() {
        if !attention.isAppActive() {
            attention.request()
        }
    }

    /// The window to attach a new modal to: the main window's topmost
    /// sheet.
    private func topmostWindow() -> NSWindow? {
        guard var host = window else {
            return nil
        }
        while let sheet = host.attachedSheet {
            host = sheet
        }
        return host
    }
}
