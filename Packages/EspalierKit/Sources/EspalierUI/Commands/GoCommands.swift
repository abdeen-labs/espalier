// The Go menu: navigation history and parent jumps.

import SwiftUI

struct GoCommands: Commands {
    let target: MenuTarget

    var body: some Commands {
        CommandMenu(MenuCatalog.go.title) {
            MenuEntriesView(entries: MenuCatalog.go.entries, target: target)
        }
    }
}
