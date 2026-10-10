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
    func fieldRegion() -> some View {
        background(FieldRegion())
    }
}

/// A `FieldRegionView` filling the view whose background it is.
struct FieldRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> FieldRegionView {
        FieldRegionView()
    }

    func updateNSView(_ view: FieldRegionView, context: Context) {}
}

/// The area of the text field inside it. It draws nothing and takes no
/// clicks.
final class FieldRegionView: NSView {
    /// The regions in a window.
    static let shown = NSHashTable<FieldRegionView>.weakObjects()

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
    }
}
