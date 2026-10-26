// View ▸ Command Palette… (⌘K) opens the palette, gathering what it lists
// as it opens, and closes it while it's open, as ⌘T and ⌘B do their
// popovers. Not while the welcome flow fills the window. A row runs as its
// source does: an action through the window's actions, as its menu item
// (whose intents ask for any confirmation); a repository as the
// repository popover switches; a branch through Check Out, as the branch
// list does.

import EspalierCore

/// Registers the palette's action, and runs its rows.
@MainActor
enum CommandPaletteActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        actions.register(.showCommandPalette, isEnabled: { [weak context] _ in
            !(context?.showsWelcome ?? true)
        }) { [weak context] _ in
            guard let context else {
                return
            }
            let state = context.state
            state.commandPalette = state.commandPalette == nil ? CommandPaletteModel(context: context) : nil
        }
    }

    /// Closes the palette and runs `command` in `context`'s window.
    static func run(_ command: CommandPaletteCommand, in context: WindowContext) {
        context.state.commandPalette = nil
        switch command {
        case .action(let action):
            context.actions.perform(action)
        case .repository(let id):
            RepositoryActions.switchTo(.repository(id), in: context)
        case .branch(let name):
            context.actions.perform(.checkoutBranch(name: name))
        }
    }
}
