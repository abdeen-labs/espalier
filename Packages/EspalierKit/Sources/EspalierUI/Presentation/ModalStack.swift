// One window's modal layers, bottom to top: the sheets and alerts drawn in
// the window. Each layer is a `ModalLayerPanel` covering the window's frame,
// a child window of the layer below it (the window for the first), so it
// moves with the window and stays above what it blocks. The panels follow
// the window's size, corners, screen, and full screen, leave while it's
// minimized or closed, and come back with it. A layer opened while the
// window isn't on screen shows when it is, without motion.
//
// The top layer is the key window whenever the window would be: it takes
// focus when it opens, the window passes focus on to it when it becomes key,
// and when it closes, focus goes back to where it was when it opened.

import AppKit
import Observation
import SwiftUI

/// A card on a window's modal layer: a sheet's content or an alert.
@MainActor
final class ModalLayer {
    let panel = ModalLayerPanel()
    let state: ModalLayerState
    /// The alert the layer shows; nil for a sheet.
    let alert: AlertCardModel?
    /// Where focus was when the layer opened.
    fileprivate var focus: ModalFocus?
    /// Whether the panel is on screen, as a child window.
    fileprivate(set) var isOrderedIn = false
    /// Whether the layer has left its stack.
    private(set) var isClosed = false

    /// - Parameters:
    ///   - content: The sheet's content, or the alert's card.
    ///   - alert: The alert, which answers Return, Escape, and ⌘., and
    ///     names the card; nil for a sheet, named by its scaffold.
    init(content: AnyView, alert: AlertCardModel? = nil) {
        self.alert = alert
        let title = alert?.content.title
        state = ModalLayerState(coversWindow: true, title: title)
        state.panel = panel
        let host = NSHostingView(rootView: ModalLayerView(state: state, content: content))
        host.sizingOptions = []
        panel.contentView = host
        if let alert {
            panel.keyAction = { [weak alert] key in
                alert?.press(key)
            }
        }
        panel.title = title ?? ""
    }

    /// Fades the layer out when `animated`, then closes its panel and ends
    /// its content.
    fileprivate func leave(animated: Bool, completion: @escaping () -> Void) {
        isClosed = true
        panel.ignoresMouseEvents = true
        panel.keyAction = nil
        guard animated else {
            state.phase = .leaving
            completion()
            return
        }
        withAnimation(Motion.animation(Motion.leave)) {
            state.phase = .leaving
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.leave) {
            completion()
        }
    }

    /// Puts keyboard focus in a sheet's card: its first field, when nothing
    /// in it has focus yet. An alert focuses its default button itself.
    func focusFirstField() {
        guard alert == nil, let content = panel.contentView, panel.firstResponder === panel || panel.firstResponder === content else {
            return
        }
        panel.selectKeyView(following: content)
    }
}

/// Where focus was: a window and the view in it that had focus (the field,
/// for a field being edited).
private struct ModalFocus {
    weak var window: NSWindow?
    weak var responder: NSResponder?

    init(_ window: NSWindow) {
        self.window = window
        responder = Self.owner(of: window.firstResponder)
    }

    /// The field a field editor edits, or `responder` itself.
    static func owner(of responder: NSResponder?) -> NSResponder? {
        if let text = responder as? NSTextView, text.isFieldEditor, let field = text.delegate as? NSView {
            return field
        }
        return responder
    }
}

/// One window's modal layers.
@MainActor @Observable
final class ModalStack {
    /// The window the layers cover.
    @ObservationIgnored private(set) weak var window: NSWindow?
    /// Bottom to top.
    private(set) var layers: [ModalLayer] = []
    /// Called when the window closes, to close the layers' modals.
    @ObservationIgnored var onWindowClose: (() -> Void)?

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Set once the window is closing: layers close without motion.
    @ObservationIgnored private var isWindowClosing = false

    /// The window a new modal goes on: the top layer's panel, or the window.
    var topWindow: NSWindow? {
        layers.last?.panel ?? window
    }

    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Covers `window` from now on, moving any layers to it.
    func attach(to window: NSWindow?) {
        guard window !== self.window else {
            return
        }
        for layer in layers where layer.isOrderedIn {
            orderOut(layer)
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        self.window = window
        isWindowClosing = false
        guard let window else {
            return
        }
        observe(window)
        for layer in layers {
            layer.panel.coveredWindow = window
            layer.panel.appearance = window.appearance
        }
        syncFrames()
        syncVisibility()
    }

    /// Opens `layer` on top. It takes focus when the window, or the layer
    /// below, has it (or no window does: Espalier is inactive).
    func push(_ layer: ModalLayer) {
        guard let window, let below = topWindow else {
            return
        }
        let keyWindow = NSApp.keyWindow
        let takesKey = keyWindow == nil || keyWindow === window || layers.contains { $0.panel === keyWindow }
        layer.focus = ModalFocus(below)
        layers.append(layer)
        layer.panel.coveredWindow = window
        layer.panel.appearance = window.appearance
        sync(layer)
        if isWindowShowing {
            orderIn(layer, at: layers.count - 1, takesKey: takesKey, animated: true)
        } else {
            layer.state.phase = .shown
        }
    }

    /// Closes `layer`. The top layer fades out when motion runs; focus goes
    /// back to where it was when the layer opened.
    func remove(_ layer: ModalLayer) {
        guard let index = layers.firstIndex(where: { $0 === layer }) else {
            return
        }
        let isTop = index == layers.count - 1
        let wasKey = layer.panel.isKeyWindow
        layers.remove(at: index)
        if layer.isOrderedIn, layers.indices.contains(index), layers[index].isOrderedIn {
            // The layer above now rests on the one below.
            let above = layers[index]
            layer.panel.removeChildWindow(above.panel)
            parentWindow(at: index)?.addChildWindow(above.panel, ordered: .above)
        }
        let animated = isTop && layer.isOrderedIn && !isWindowClosing && Motion.animates(layer.panel.contentView)
        layer.leave(animated: animated) { [weak self, weak layer] in
            guard let layer else {
                return
            }
            self?.orderOut(layer)
            layer.panel.contentView = nil
        }
        if isTop {
            restore(layer.focus, makesKey: wasKey)
        }
    }

    // MARK: The window

    /// Whether the window is on screen, so the layers can be.
    private var isWindowShowing: Bool {
        guard let window else {
            return false
        }
        return window.isVisible && !window.isMiniaturized && !isWindowClosing
    }

    /// The window a layer at `index` is a child of.
    private func parentWindow(at index: Int) -> NSWindow? {
        index == 0 ? window : layers[index - 1].panel
    }

    private func orderIn(_ layer: ModalLayer, at index: Int, takesKey: Bool, animated: Bool) {
        guard let parent = parentWindow(at: index) else {
            return
        }
        layer.panel.contentView?.layoutSubtreeIfNeeded()
        parent.addChildWindow(layer.panel, ordered: .above)
        if !layer.panel.isVisible {
            layer.panel.orderFront(nil)
        }
        layer.isOrderedIn = true
        if takesKey {
            layer.panel.makeKey()
            layer.focusFirstField()
        }
        guard animated, layer.state.phase == .hidden, Motion.animates(layer.panel.contentView) else {
            layer.state.phase = .shown
            return
        }
        // The next turn, so the clear frame draws first.
        DispatchQueue.main.async { [weak layer] in
            guard let layer, !layer.isClosed else {
                return
            }
            withAnimation(Motion.animation(Motion.arrive)) {
                layer.state.phase = .shown
            }
        }
    }

    private func orderOut(_ layer: ModalLayer) {
        layer.panel.parent?.removeChildWindow(layer.panel)
        layer.panel.orderOut(nil)
        layer.isOrderedIn = false
    }

    /// Puts the layers on screen while the window is, and takes them off
    /// while it isn't.
    private func syncVisibility() {
        let isShowing = isWindowShowing
        for (index, layer) in layers.enumerated() {
            if isShowing, !layer.isOrderedIn {
                orderIn(layer, at: index, takesKey: false, animated: false)
            } else if !isShowing, layer.isOrderedIn {
                orderOut(layer)
            }
        }
        passFocusToTop()
    }

    /// Makes the top layer key while the window is key.
    private func passFocusToTop() {
        guard let window, let top = layers.last, top.isOrderedIn, window.isKeyWindow else {
            return
        }
        top.panel.makeKey()
    }

    /// Covers the window's frame, in its corners, with every layer.
    private func syncFrames() {
        for layer in layers {
            sync(layer)
        }
    }

    private func sync(_ layer: ModalLayer) {
        guard let window else {
            return
        }
        if layer.panel.frame != window.frame {
            layer.panel.setFrame(window.frame, display: layer.isOrderedIn)
        }
        let radii = Self.cornerRadii(of: window)
        if layer.state.cornerRadii != radii {
            layer.state.cornerRadii = radii
        }
    }

    /// `window`'s corner radii, as the window server rounds its frame.
    static func cornerRadii(of window: NSWindow) -> RectangleCornerRadii {
        guard let radii = window.contentView?.superview?.effectiveCornerRadii ?? window.contentView?.effectiveCornerRadii else {
            return RectangleCornerRadii()
        }
        return RectangleCornerRadii(
            topLeading: radii.topLeft,
            bottomLeading: radii.bottomLeft,
            bottomTrailing: radii.bottomRight,
            topTrailing: radii.topRight
        )
    }

    /// Gives focus back: to the view that had it in the window below when a
    /// layer opened, making that window key when the layer was.
    private func restore(_ focus: ModalFocus?, makesKey: Bool) {
        guard let top = topWindow else {
            return
        }
        let target = focus?.window.flatMap { window in window === top ? window : nil } ?? top
        if let responder = focus?.responder, target === focus?.window,
           (responder as? NSView)?.window === target || responder === target,
           ModalFocus.owner(of: target.firstResponder) !== responder {
            target.makeFirstResponder(responder)
        }
        if makesKey, target.isVisible {
            target.makeKey()
        }
    }

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ action: @escaping @MainActor (ModalStack) -> Void) {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self {
                        action(self)
                    }
                }
            })
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            on(name) { $0.syncFrames() }
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            on(name) { stack in
                stack.syncFrames()
                stack.syncVisibility()
            }
        }
        on(NSWindow.willMiniaturizeNotification) { stack in
            for layer in stack.layers where layer.isOrderedIn {
                stack.orderOut(layer)
            }
        }
        for name in [NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            on(name) { $0.syncVisibility() }
        }
        on(NSWindow.willCloseNotification) { stack in
            stack.isWindowClosing = true
            stack.onWindowClose?()
            stack.isWindowClosing = false
        }
    }
}
