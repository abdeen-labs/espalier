// "Initialize Git LFS", asked after adding or cloning repositories that use
// Git LFS (`lfsInitializationPrompt(for:)`), and "Replace Hooks?", asked
// when hooks of the repositories' own are where Git LFS installs its own
// (`Decision.replaceLFSHooks`). "Update Existing Git LFS Filters?" is an
// error's presentation (the shell's ErrorHost and StateNotices), which
// initializing asks too.

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

    /// Replace Hooks? as an alert: the question with the hooks listed after
    /// its first paragraph (their count past the list in `numberFormat`),
    /// [Replace Hooks] [Don't Replace]. Replacing moves the hooks to the
    /// Trash, so its button is destructive.
    static func replaceHooksAlert(_ decision: Decision, numberFormat: NumberFormat) -> AlertContent {
        var lines: [String] = []
        if case .replaceLFSHooks(let repositories) = decision {
            lines = LFSHooksToReplace.listLines(repositories)
        }
        return AlertContent(
            title: decision.title,
            message: AlertList.insert(lines, intoMessage: decision.message, numberFormat: numberFormat),
            buttons: [
                AlertContent.Button(decision.confirmButton, role: .destructive),
                AlertContent.Button("Don't Replace", role: .cancel),
            ]
        )
    }

    /// Asks whether to initialize Git LFS in `ids`, and does it; a
    /// repository that fails shows its error, and the others go on.
    ///
    /// Hooks in Git LFS's way are asked about first (Replace Hooks?). When
    /// the global filters have other values, their question shows ("Update
    /// Existing Git LFS Filters?"), and once Update Existing Filters has
    /// updated them, initializing starts again.
    static func initializeLFS(in ids: [RepositoryID], context: WindowContext) async {
        let app = context.app
        guard let prompt = app.lfsInitializationPrompt(for: ids) else {
            return
        }
        guard await context.modals.alert(initializeAlert(prompt, numberFormat: context.app.preferences.numberFormat)).buttonIndex == 0 else {
            return
        }
        while true {
            do throws(OperationError) {
                let failures = try await context.presenter.performThrowing { answers throws(OperationError) in
                    try await app.initializeLFS(in: prompt.repositories, replacingHooks: answers.lfsHooks)
                }
                for failure in failures ?? [] {
                    context.presenter.present(failure)
                }
                return
            } catch {
                guard error.reason == .lfsAttributeMismatch else {
                    context.presenter.present(error)
                    return
                }
                guard await updateFilters(for: error, in: context) else {
                    return
                }
            }
        }
    }

    /// Asks the global filters' question for `error` ("Update Existing Git
    /// LFS Filters?"): Update Existing Filters updates them, returning
    /// whether it did; Edit Global Git Config… opens the file in the
    /// editor, leaving the filters to the user; Not Now does nothing.
    private static func updateFilters(for error: OperationError, in context: WindowContext) async -> Bool {
        guard case .alert(let content, let recoveries) = error.presentation(context.app.preferences.numberFormat) else {
            return false
        }
        let response = await context.modals.alert(content)
        guard recoveries.indices.contains(response.buttonIndex) else {
            return false
        }
        let recovery = recoveries[response.buttonIndex]
        guard case .updateLFSFilters = recovery else {
            await context.presenter.run(recovery)
            return false
        }
        let integrations = context.app.integrations
        let updated: Void? = await context.presenter.perform { _ throws(OperationError) in
            try await integrations.updateGlobalLFSFilters()
        }
        return updated != nil
    }
}
