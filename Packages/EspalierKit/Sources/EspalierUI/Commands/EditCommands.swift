// Espalier's Edit items, after the standard ones. Delete (⌘⌫) acts on the
// focused list's selection and is disabled otherwise, so ⌘⌫ still reaches
// text fields; Copy Path is Finder's ⌥⌘C. Find comes from
// `TextEditingCommands`.

import SwiftUI

struct EditCommands: Commands {
    let target: MenuTarget

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            MenuEntriesView(entries: MenuCatalog.edit.entries, target: target)
        }
    }
}
