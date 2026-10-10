// The Commit menu. It makes every commit action reachable from the
// keyboard.

import SwiftUI

struct CommitCommands: Commands {
    let target: MenuTarget

    var body: some Commands {
        CommandMenu(MenuCatalog.commit.title) {
            MenuEntriesView(entries: MenuCatalog.commit.entries, target: target)
        }
    }
}
