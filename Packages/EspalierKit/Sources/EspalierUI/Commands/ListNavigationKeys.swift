// Control-P and Control-N move up and down a list, as they move up and down
// the lines of text. AppKit's and SwiftUI's lists know only the arrow keys,
// so the key press becomes the arrow's before anything sees it: every list
// takes it, and so does a filter field whose arrows move its list's
// highlight. A text view keeps the keys: there the text system moves the
// insertion point itself.

import AppKit

/// Control-P and Control-N as the Up and Down Arrow keys.
@MainActor
enum ListNavigationKeys {
    /// The arrow key press `event` becomes while `firstResponder` has the
    /// keyboard: Up for Control-P and Down for Control-N, with no other
    /// modifier. `nil` leaves the event as it is.
    static func arrowEvent(for event: NSEvent, firstResponder: NSResponder?) -> NSEvent? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .control else {
            return nil
        }
        let isUp: Bool
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "p": isUp = true
        case "n": isUp = false
        default: return nil
        }
        if let textView = firstResponder as? NSTextView, !textView.isFieldEditor {
            return nil
        }
        let arrow = isUp ? "\u{F700}" : "\u{F701}"
        return NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: [.numericPad, .function],
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: arrow,
            charactersIgnoringModifiers: arrow,
            isARepeat: event.isARepeat,
            keyCode: isUp ? KeyCode.upArrow : KeyCode.downArrow
        )
    }

    private static var monitor: Any?

    /// Turns the keys into arrows in every window, from now on.
    static func install() {
        guard monitor == nil else {
            return
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            var arrow: NSEvent?
            MainActor.assumeIsolated {
                arrow = arrowEvent(for: event, firstResponder: event.window?.firstResponder)
            }
            return arrow ?? event
        }
    }
}
