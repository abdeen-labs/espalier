// Espalier's text input: the selection and insertion point of every text
// view and field editor. Selected text is the accent at 24%, the insertion
// point is the accent, and text an input method is still composing has the
// soft accent behind it.
//
// Espalier's own text views (`EspalierTextView`) start out this way. Every
// other text view, SwiftUI's text fields' field editors included, is set up
// when it takes focus: `TextInputStyling` watches each window's first
// responder.

import AppKit
import ObjectiveC

/// Sets up a text view the Espalier way.
@MainActor
enum TextInputStyle {
    /// Gives `textView` Espalier's selection, insertion point, and marked
    /// text. It can run again on a view already set up.
    static func apply(to textView: NSTextView) {
        if textView.selectedTextAttributes[.backgroundColor] as? NSColor !== Palette.textSelection {
            textView.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
        }
        textView.insertionPointColor = Palette.caret
        if textView.markedTextAttributes?[.backgroundColor] as? NSColor !== Palette.markedText {
            textView.markedTextAttributes = [.backgroundColor: Palette.markedText]
        }
    }
}

/// Sets up the text views of every window as they take focus: SwiftUI's
/// text fields edit in field editors of SwiftUI's own, set up each time
/// editing starts.
@MainActor
public enum TextInputStyling {
    private static var isInstalled = false
    private static var observerKey: UInt8 = 0

    /// Watches every window that becomes key: once at launch.
    public static func install() {
        guard !isInstalled else {
            return
        }
        isInstalled = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                if let window {
                    attach(to: window)
                }
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                if let window {
                    detach(from: window)
                }
            }
        }
    }

    /// Sets up `window`'s first responder now and each time it changes,
    /// once per window.
    static func attach(to window: NSWindow) {
        guard objc_getAssociatedObject(window, &observerKey) == nil else {
            return
        }
        let observation = window.observe(\.firstResponder, options: [.initial, .new]) { window, _ in
            MainActor.assumeIsolated {
                if let textView = window.firstResponder as? NSTextView {
                    TextInputStyle.apply(to: textView)
                }
            }
        }
        objc_setAssociatedObject(window, &observerKey, observation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Stops watching `window` (it's closing; it's watched again if it
    /// becomes key again).
    static func detach(from window: NSWindow) {
        (objc_getAssociatedObject(window, &observerKey) as? NSKeyValueObservation)?.invalidate()
        objc_setAssociatedObject(window, &observerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
