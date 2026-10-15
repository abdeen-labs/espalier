// The View menu. The system adds the inspector, the toolbar items, and
// Enter Full Screen (⌃⌘F) around these; Show/Hide Sidebar (⌘S) is
// Espalier's.

import SwiftUI

struct ViewCommands: Commands {
    let target: MenuTarget

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            MenuEntriesView(entries: MenuCatalog.viewPlaces.entries, target: target)
            Divider()
        }
        CommandGroup(after: .sidebar) {
            Divider()
            MenuEntriesView(entries: MenuCatalog.view.entries, target: target)
        }
    }
}
