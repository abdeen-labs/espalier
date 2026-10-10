// Two of Espalier's shortcuts are also the system Find submenu's
// (`TextEditingCommands`): Go to Commit Message (⌘J) is Jump to Selection's
// and Search (⌥⌘F) Find and Replace…'s. SwiftUI keeps one key equivalent per
// menu bar and decides which item gets it; in the running app, with
// History's list focused, Espalier's items get neither. Both must work from
// anywhere, typing included, so in the main window these two run Espalier's
// actions before the menu bar sees the key, whichever item holds it. In
// other windows (Settings, a sheet) the keys go on as usual.
//
// Next Place (⌃⇥) and Previous Place (⇧⌃⇥) run here too: the keyboard
// types ⇧⌃⇥ as the back-tab character, which no menu item showing ⌃⇧⇥
// matches, so in the main window both keys run here, before a text view or
// a list can take them to move focus.

import AppKit

/// Espalier's shortcuts the system's text items also claim.
@MainActor
enum ContestedShortcuts {
    /// Go to Commit Message (Jump to Selection's ⌘J), Search (Find and
    /// Replace…'s ⌥⌘F), and Next and Previous Place (⌃⇥ and ⇧⌃⇥, which
    /// text views and lists use to move focus).
    static let actions: [ActionID] = [.goToCommitMessage, .search, .showNextPlace, .showPreviousPlace]

    /// The action `event` is the shortcut of, if it's one of `actions`.
    static func action(for event: NSEvent) -> ActionID? {
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }
        var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var key = characters
        if key.count == 1, let character = key.first, character.isUppercase {
            key = key.lowercased()
            modifiers.insert(.shift)
        }
        let pressed = MenuKeyEquivalent(key: key, modifiers: modifiers)
        return actions.first { action in
            action.kind.shortcut.map(MenuKeyEquivalent.init) == pressed
        }
    }

    /// Runs the action `event` is the shortcut of when the event is for
    /// `context`'s window itself (not a sheet on it) and the action can
    /// run. Returns whether it ran, so the event is used up.
    static func handle(_ event: NSEvent, in context: WindowContext) -> Bool {
        guard let window = context.modals.window, event.window === window,
              let action = action(for: event), context.actions.canPerform(action) else {
            return false
        }
        context.actions.perform(action)
        return true
    }

    /// Handles the contested shortcuts in `context`'s window until the
    /// returned monitor is removed (`NSEvent.removeMonitor`).
    static func install(for context: WindowContext) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak context] event in
            let handled = MainActor.assumeIsolated {
                context.map { handle(event, in: $0) } ?? false
            }
            return handled ? nil : event
        }
    }
}
