// "Initialize Git LFS", asked after adding or cloning repositories that use
// Git LFS (`lfsInitializationPrompt(for:)`). "Update Existing Git LFS
// Filters?" is an error's presentation (the shell's ErrorHost and
// StateNotices).

import EspalierCore
import GitKit

/// The Git LFS alerts.
@MainActor
enum LFSAlerts {
    /// Initialize Git LFS as an alert: the question, the folders listed
    /// under it (their count past the list in `numberFormat`), [Initialize
    /// Git LFS] [Not Now].
    static func initializeAlert(_ prompt: LFSInitializationPrompt, numberFormat: NumberFormat) -> AlertContent {
        var message = prompt.message
        if !prompt.paths.isEmpty {
            message += "\n\n" + AlertList.lines(prompt.paths, numberFormat: numberFormat)
        }
        return AlertContent(
            title: prompt.title,
            message: message,
            buttons: [
                AlertContent.Button(prompt.initializeButton, role: .primary),
                AlertContent.Button(prompt.cancelButton, role: .cancel),
            ]
        )
    }

    /// Asks whether to initialize Git LFS in `ids`, and does it; a
    /// repository that fails shows its error, and the others go on.
    static func initializeLFS(in ids: [RepositoryID], context: WindowContext) async {
        let app = context.app
        guard let prompt = app.lfsInitializationPrompt(for: ids) else {
            return
        }
        guard await context.modals.alert(initializeAlert(prompt, numberFormat: context.app.preferences.numberFormat)).buttonIndex == 0 else {
            return
        }
        for failure in await app.initializeLFS(in: prompt.repositories) {
            context.presenter.present(failure)
        }
    }
}
