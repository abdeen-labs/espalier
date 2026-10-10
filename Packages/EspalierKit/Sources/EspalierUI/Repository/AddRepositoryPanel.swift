// Add (⌘O), the system's open panel: folders, several at once, "Add
// Repository". What adding did is shown by `RepositoryActions.present`.

import AppKit
import EspalierCore
import GitKit

/// Add's open panel.
@MainActor
enum AddRepositoryPanel {
    /// The panel's settings: folders only, several at once, created folders
    /// allowed (a new, empty folder then offers "Create a Repository…"), "Add
    /// Repository".
    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Add Repository"
        panel.message = "Choose the folders of the repositories to add."
        return panel
    }

    /// Shows the panel on the window, then adds what was chosen.
    static func present(in context: WindowContext) {
        let panel = makePanel()
        Task {
            let response: NSApplication.ModalResponse
            if let window = context.modals.window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK else {
                return
            }
            await RepositoryActions.addRepositories(panel.urls.map(folderPath), in: context)
        }
    }

    /// A folder URL's path, without the trailing slash folder URLs have.
    static func folderPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
