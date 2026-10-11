// The window a modal card is drawn in: a borderless, transparent panel. On a
// window it covers the window's whole frame (the title bar included) and
// takes every click on it; with no window (`AppModalAlert`) it holds just the
// card and its shadow. It becomes key, never main, so the window behind keeps
// its active look. Return, Escape, and ⌘. go to an alert's buttons; on a
// sheet, ⌘. is Escape, which the sheet's Cancel button answers. Minimize,
// Zoom, and Full Screen act on the window behind. An open panel shown on it
// as a sheet attaches below the window's toolbar.

import AppKit

/// A key that answers a modal card.
nonisolated enum ModalKey: Equatable, Sendable {
    /// Return or Enter: the default button.
    case confirm
    /// Escape or ⌘.: the cancel button.
    case cancel

    /// The key `event` presses, if it's one: Return or Enter, Escape, or ⌘.,
    /// with no other modifiers.
    init?(_ event: NSEvent) {
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers else {
            return nil
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (characters, modifiers) {
        case ("\r", []), ("\u{3}", []):
            self = .confirm
        case ("\u{1b}", []), (".", .command):
            self = .cancel
        default:
            return nil
        }
    }

    /// Whether `event` is ⌘.
    static func isCommandPeriod(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.charactersIgnoringModifiers == "."
            && event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
    }
}

/// A borderless, transparent panel holding a modal card.
final class ModalLayerPanel: NSPanel {
    /// Answers Return, Escape, and ⌘. (an alert's buttons); nil for a sheet,
    /// whose own buttons take them.
    var keyAction: ((ModalKey) -> Void)?
    /// The window the panel covers; nil on its own (no window).
    weak var coveredWindow: NSWindow?
    /// Positions sheets shown on the panel.
    private let sheetPositioner = ModalSheetPositioner()

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        ignoresMouseEvents = false
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        delegate = sheetPositioner
        setAccessibilitySubrole(.dialog)
        setAccessibilityModal(true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: Keys

    /// Handles `event` if it answers the card. Returns whether it did.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let key = ModalKey(event) else {
            return false
        }
        if let keyAction {
            keyAction(key)
            return true
        }
        guard ModalKey.isCommandPeriod(event), let escape = Self.escape(like: event) else {
            return false
        }
        if !super.performKeyEquivalent(with: escape) {
            super.sendEvent(escape)
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleKey(event) || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey(event) {
            return
        }
        super.sendEvent(event)
    }

    /// An Escape key press at `event`'s time and place.
    private static func escape(like event: NSEvent) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: [],
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )
    }

    // MARK: The window behind

    override func performMiniaturize(_ sender: Any?) {
        coveredWindow?.performMiniaturize(sender)
    }

    override func miniaturize(_ sender: Any?) {
        coveredWindow?.miniaturize(sender)
    }

    override func performZoom(_ sender: Any?) {
        coveredWindow?.performZoom(sender)
    }

    override func toggleFullScreen(_ sender: Any?) {
        coveredWindow?.toggleFullScreen(sender)
    }
}

/// Attaches a sheet shown on a modal panel (an open panel) below the covered
/// window's title bar and toolbar, where it attaches to the window itself.
private final class ModalSheetPositioner: NSObject, NSWindowDelegate {
    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        guard let panel = window as? ModalLayerPanel, let covered = panel.coveredWindow else {
            return rect
        }
        let top = covered.contentLayoutRect.maxY
        return NSRect(x: 0, y: top, width: panel.frame.width, height: 0)
    }
}
