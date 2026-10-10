// The File menu. New Repository…, Add Local Repository…, and Clone
// Repository… replace SwiftUI's New Window: Espalier has one window. Close
// (⌘W) closes the key window; closing the main window quits after the quit
// guard.
//
// Close replaces the system's save group, whose hidden alternate Close All
// (⌥⌘W) took Show Worktrees' shortcut: SwiftUI gives a key equivalent the
// system's File menu holds to it and drops it from Espalier's item. With one
// main window, Close All has nothing to add.

import AppKit
import SwiftUI

struct FileCommands: Commands {
    let target: MenuTarget

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            MenuEntriesView(entries: MenuCatalog.file.entries, target: target)
        }
        CommandGroup(replacing: .saveItem) {
            CloseWindowItem()
        }
    }
}

/// File ▸ Close (⌘W): the system's Close, without its Close All alternate.
struct CloseWindowItem: View {
    var body: some View {
        Button("Close") {
            // Through the responder chain, as the system's item: the key
            // window closes (a sheet beeps, as it can't).
            NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("w")
    }
}
