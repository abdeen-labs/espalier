// A click away from a text field ends its editing. AppKit moves focus only
// to a view that takes it, so a click on the window's background, a label,
// or a SwiftUI button would leave the field focused. In the main window, a
// left mouse down anywhere but the focused field, or the area around it
// that belongs to it (`fieldRegion()`: a search capsule, the commit message
// card's summary or description), makes the window its own first responder
// before the click goes on; a list or the diff then takes focus as a click
// on it does. A Control-click, which opens a context menu, leaves the field
// focused.

import AppKit
import SwiftUI

/// Ends a text field's editing when a click lands away from it.
@MainActor
enum ClickAwayFocus {
    /// Ends the focused field's editing on a click away from it in
    /// `window` until the returned monitor is removed
    /// (`NSEvent.removeMonitor`).
    static func install(in window: NSWindow) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            MainActor.assumeIsolated {
                if let window, event.window === window, !event.modifierFlags.contains(.control) {
                    endEditing(forClickAt: event.locationInWindow, in: window)
                }
            }
            return event
        }
    }

    /// Ends the editing of the field focused in `window`, unless `point`
    /// (in the window's coordinates) is in the field or in an area that
    /// belongs to it.
    static func endEditing(forClickAt point: CGPoint, in window: NSWindow) {
        guard let field = editedView(window.firstResponder) else {
            return
        }
        if let hit = window.contentView?.superview?.hitTest(point), hit.isDescendant(of: field) {
            return
        }
        let fieldFrame = field.convert(field.bounds, to: nil)
        let fieldCenter = CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)
        for region in FieldRegionView.shown.allObjects where region.window === window && !region.isHiddenOrHasHiddenAncestor {
            let frame = region.convert(region.bounds, to: nil)
            if frame.contains(point), frame.contains(fieldCenter) {
                return
            }
        }
        window.makeFirstResponder(nil)
    }

    /// The view whose text is edited while `responder` has focus: the
    /// field a field editor edits, or a text view's scroll view. Nil when
    /// no text is being edited.
    static func editedView(_ responder: NSResponder?) -> NSView? {
        guard let textView = responder as? NSTextView, textView.isEditable else {
            return nil
        }
        if textView.isFieldEditor {
            return textView.delegate as? NSView ?? textView
        }
        return textView.enclosingScrollView ?? textView
    }
}

extension View {
    /// Marks the view as the area of the text field inside it: a click
    /// around the field, in the area, leaves the field focused
    /// (`ClickAwayFocus`).
    ///
    /// SwiftUI's focus state neither follows nor moves a field in the
    /// toolbar; the area does both through AppKit.
    ///
    /// - Parameters:
    ///   - focusRequest: Changed to focus the field.
    ///   - onEditingChange: Told whether the field is being edited as the
    ///     window's first responder changes.
    func fieldRegion(focusRequest: Int = 0, onEditingChange: ((Bool) -> Void)? = nil) -> some View {
        background(FieldRegion(focusRequest: focusRequest, onEditingChange: onEditingChange))
    }
}

/// A `FieldRegionView` filling the view whose background it is.
struct FieldRegion: NSViewRepresentable {
    var focusRequest = 0
    var onEditingChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> FieldRegionView {
        FieldRegionView()
    }

    func updateNSView(_ view: FieldRegionView, context: Context) {
        view.onEditingChange = onEditingChange
        view.focusRequest = focusRequest
    }
}

/// The area of the text field inside it. It draws nothing and takes no
/// clicks. It focuses the field in it on request, and given
/// `onEditingChange`, it watches its window's first responder and tells
/// whether the field is being edited.
final class FieldRegionView: NSView {
    /// The regions in a window.
    static let shown = NSHashTable<FieldRegionView>.weakObjects()

    /// Told whether the field in the area is being edited, as that
    /// changes.
    var onEditingChange: ((Bool) -> Void)? {
        didSet {
            observeFirstResponder()
        }
    }
    /// Changed to focus the field in the area.
    var focusRequest = 0 {
        didSet {
            if focusRequest != oldValue {
                isFocusPending = true
                scheduleFocus()
            }
        }
    }
    private var firstResponderObservation: NSKeyValueObservation?
    private var isEditing = false
    /// A focus request that waits for a window.
    private var isFocusPending = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.shown.remove(self)
        } else {
            Self.shown.add(self)
        }
        firstResponderObservation = nil
        observeFirstResponder()
        scheduleFocus()
    }

    /// Focuses the field the next turn, outside the view update that asked
    /// for it.
    private func scheduleFocus() {
        guard isFocusPending, window != nil else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.focusField()
        }
    }

    /// Makes the field in the area the first responder, if a request
    /// waits.
    private func focusField() {
        guard isFocusPending, let window else {
            return
        }
        isFocusPending = false
        if let field = fieldInArea(), ClickAwayFocus.editedView(window.firstResponder) !== field {
            window.makeFirstResponder(field)
        }
    }

    /// The editable text field centered in the area, among the views
    /// around it, the nearest first.
    private func fieldInArea() -> NSTextField? {
        let area = convert(bounds, to: nil)
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable {
                let frame = field.convert(field.bounds, to: nil)
                if area.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    return field
                }
            }
            for subview in view.subviews {
                if let found = field(in: subview) {
                    return found
                }
            }
            return nil
        }
        var ancestor = superview
        while let view = ancestor {
            if let found = field(in: view) {
                return found
            }
            ancestor = view.superview
        }
        return nil
    }

    /// Watches the window's first responder, once, while there's someone
    /// to tell.
    private func observeFirstResponder() {
        guard let window, onEditingChange != nil else {
            firstResponderObservation = nil
            updateEditing()
            return
        }
        guard firstResponderObservation == nil else {
            return
        }
        firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                // The next turn, outside the view update that may have
                // moved focus.
                DispatchQueue.main.async { [weak self] in
                    self?.updateEditing()
                }
            }
        }
    }

    /// Tells `onEditingChange` when whether the field is being edited has
    /// changed: the first responder edits a view centered in the area.
    private func updateEditing() {
        var isEditing = false
        if onEditingChange != nil, let window, let field = ClickAwayFocus.editedView(window.firstResponder) {
            let fieldFrame = field.convert(field.bounds, to: nil)
            isEditing = convert(bounds, to: nil).contains(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY))
        }
        guard isEditing != self.isEditing else {
            return
        }
        self.isEditing = isEditing
        onEditingChange?(isEditing)
    }
}
