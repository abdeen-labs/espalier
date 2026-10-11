// An alert with no window to cover (the quit guard while the main window is
// hidden or minimized, an alert before the window exists): the card and its
// shadow in a panel of their own, centered on the active screen, run
// app-modally until a button answers it.

import AppKit
import SwiftUI

/// Alerts shown on their own, app-modally.
@MainActor
enum AppModalAlert {
    /// Shows `content` and waits, app-modally, for the answer.
    static func run(_ content: AlertContent) -> AlertResponse {
        let model = AlertCardModel(content)
        let panel = makePanel(for: model, on: NSScreen.main)
        var response: AlertResponse?
        model.onAnswer = { answer in
            response = answer
            NSApp.stopModal()
        }
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.contentView = nil
        return response ?? content.response(buttonIndex: nil, isSuppressed: model.isSuppressed)
    }

    /// The panel for `model`: the card's size with room for its shadow, at
    /// most `screen`'s, centered on it; Return, Escape, and ⌘. answer it.
    static func makePanel(for model: AlertCardModel, on screen: NSScreen?) -> ModalLayerPanel {
        let state = ModalLayerState(coversWindow: false, title: model.content.title)
        state.phase = .shown
        let panel = ModalLayerPanel()
        state.panel = panel
        panel.title = model.content.title
        panel.level = .modalPanel
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.keyAction = { [weak model] key in
            model?.press(key)
        }
        let host = NSHostingView(rootView: ModalLayerView(state: state, content: AnyView(AlertCard(model: model))))
        host.sizingOptions = [.intrinsicContentSize]
        let fitting = host.fittingSize
        host.sizingOptions = []
        panel.contentView = host
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: fitting)
        let size = CGSize(width: min(ceil(fitting.width), visible.width), height: min(ceil(fitting.height), visible.height))
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        panel.setFrame(CGRect(origin: origin, size: size).integral, display: false)
        return panel
    }
}
