// The Branch menu.

import SwiftUI

struct BranchCommands: Commands {
    let target: MenuTarget

    var body: some Commands {
        CommandMenu(MenuCatalog.branch.title) {
            MenuEntriesView(entries: MenuCatalog.branch.entries, target: target)
        }
    }
}
