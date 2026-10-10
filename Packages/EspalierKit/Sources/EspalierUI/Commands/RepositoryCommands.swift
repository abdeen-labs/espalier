// The Repository menu.

import SwiftUI

struct RepositoryCommands: Commands {
    let target: MenuTarget

    var body: some Commands {
        CommandMenu(MenuCatalog.repository.title) {
            MenuEntriesView(entries: MenuCatalog.repository.entries, target: target)
        }
    }
}
