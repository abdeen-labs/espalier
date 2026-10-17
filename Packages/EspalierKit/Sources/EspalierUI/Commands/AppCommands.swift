// The menu bar, built from `MenuCatalog` with `.commands`. Every item runs
// through the main window's `WindowActions`, which validates it; with the
// main window minimized, the menus still act on it and bring it back first
// (`MenuTarget`).

import AppKit
import SwiftUI

/// Espalier's menus. The app's main window scene declares them.
public struct EspalierCommands: Commands {
    @FocusedValue(WindowContext.self) private var focused: WindowContext?
    private let updater: Updater
    private let mainWindowContext: @MainActor () -> WindowContext?

    /// - Parameters:
    ///   - updater: The app's updater, for Check for Updates….
    ///   - mainWindowContext: The main window's context, which the menus
    ///     act on when no window is key (the main window is minimized).
    public init(updater: Updater, mainWindowContext: @escaping @MainActor () -> WindowContext? = { nil }) {
        self.updater = updater
        self.mainWindowContext = mainWindowContext
    }

    public var body: some Commands {
        let target = MenuTarget(focused: focused, main: mainWindowContext())
        InspectorCommands()
        ToolbarCommands()
        TextEditingCommands()
        AppMenuCommands(target: target, updater: updater)
        FileCommands(target: target)
        EditCommands(target: target)
        ViewCommands(target: target)
        GoCommands(target: target)
        RepositoryCommands(target: target)
        BranchCommands(target: target)
        CommitCommands(target: target)
        HelpCommands(target: target)
        DebugCommands(target: target)
    }
}

/// The Espalier menu: About, Check for Updates…, and Install Command Line
/// Tool….
struct AppMenuCommands: Commands {
    let target: MenuTarget
    let updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(ActionKind.about.title) {
                openWindow(id: EspalierScenes.aboutWindowID)
            }
            CheckForUpdatesButton(updater: updater)
        }
        CommandGroup(after: .appSettings) {
            MenuEntriesView(entries: Array(MenuCatalog.espalier.entries.dropFirst()), target: target)
        }
    }
}

/// Check for Updates…, disabled while Sparkle can't check. A view, so the
/// menu item follows the updater's state.
private struct CheckForUpdatesButton: View {
    let updater: Updater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}

/// Help: Report Issue…, Keyboard Shortcuts, and Show Logs in Finder (the
/// system adds the search field).
struct HelpCommands: Commands {
    let target: MenuTarget

    var body: some Commands {
        CommandGroup(replacing: .help) {
            MenuEntriesView(entries: MenuCatalog.help.entries, target: target)
        }
    }
}

/// The Debug menu, in Debug builds only (`DebugMenu.isEnabled`).
struct DebugCommands: Commands {
    let target: MenuTarget

    var body: some Commands {
        if DebugMenu.isEnabled {
            CommandMenu(MenuCatalog.debug.title) {
                MenuEntriesView(entries: MenuCatalog.debug.entries, target: target)
            }
        }
    }
}

// MARK: - Rendering entries

/// A menu's entries: buttons and toggles validated by the window's actions.
struct MenuEntriesView: View {
    let entries: [MenuEntry]
    let target: MenuTarget

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .submenu(let title, let children):
                Menu(title) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        MenuLeafView(entry: child, target: target)
                    }
                }
            default:
                MenuLeafView(entry: entry, target: target)
            }
        }
    }
}

/// An item, a toggle, or a separator.
struct MenuLeafView: View {
    let entry: MenuEntry
    let target: MenuTarget

    private var actions: WindowActions? {
        target.context?.actions
    }

    var body: some View {
        switch entry {
        case .item(let action) where actions?.isHidden(action) == true:
            EmptyView()
        case .item(let action):
            Button(actions?.title(for: action) ?? action.defaultTitle) {
                target.perform(action)
            }
            .keyboardShortcut(action.kind.shortcut?.keyboardShortcut)
            .disabled(!(actions?.canPerform(action) ?? false))
        case .toggle(let action):
            Toggle(actions?.title(for: action) ?? action.defaultTitle, isOn: Binding(
                get: { actions?.isChecked(action) ?? false },
                set: { _ in target.perform(action) }
            ))
            .keyboardShortcut(action.kind.shortcut?.keyboardShortcut)
            .disabled(!(actions?.canPerform(action) ?? false))
        case .separator:
            Divider()
        case .submenu:
            EmptyView()
        }
    }
}
