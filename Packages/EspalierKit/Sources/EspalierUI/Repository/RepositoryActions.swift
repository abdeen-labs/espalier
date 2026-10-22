// The File menu and the Repository menu's repository actions: Add (the open
// panel and every result of adding), Clone, Create, Publish, Repository
// Settings, Alias, Open With, Remove, and the open actions. Every intent runs
// through the window's presenter.

import AppKit
import EspalierCore
import EspalierSupport
import GitHubKit
import GitKit
import SwiftUI

/// Registers the repository actions, and runs the flows other features and
/// the shell start (Add's result, clones, URL actions).
@MainActor
enum RepositoryActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        actions.register(.addLocalRepository) { [weak context] _ in
            guard let context else {
                return
            }
            AddRepositoryPanel.present(in: context)
        }

        actions.register(.addRepositories) { [weak context] action in
            guard case .addRepositories(let paths) = action, let context else {
                return
            }
            await addRepositories(paths, in: context)
        }

        actions.register(.newRepository) { [weak context] action in
            guard case .newRepository(let path) = action, let context else {
                return
            }
            CreateRepositorySheet.present(forFolder: path, in: context)
        }

        actions.register(.cloneRepository) { [weak context] action in
            guard case .cloneRepository(let url) = action, let context else {
                return
            }
            // A link's clone goes on with the link afterwards.
            let external = url.flatMap {
                context.state.featureState(PendingExternalClones.self) { PendingExternalClones() }.requests.removeValue(forKey: $0)
            }
            CloneSheet.present(initialURL: url, externalRequest: external, in: context)
        }

        // Publishing is for a repository without a remote (the intent refuses
        // one with `origin`).
        actions.register(.publishRepository, isEnabled: { [weak context] _ in
            context?.repository?.gitState.remotes.all.isEmpty ?? false
        }) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            PublishRepositorySheet.present(for: repository, in: context)
        }

        actions.register(.repositorySettings) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            RepositorySettingsSheet.present(for: repository, in: context)
        }

        actions.register(.changeAlias) { [weak context] action in
            guard case .changeAlias(let id) = action, let context, let repositoryID = id ?? context.repository?.id else {
                return
            }
            AliasSheet.present(for: repositoryID, in: context)
        }

        actions.register(.removeAlias) { [weak context] action in
            guard case .removeAlias(let id) = action, let context, let repositoryID = id ?? context.repository?.id else {
                return
            }
            context.app.setAlias(nil, for: repositoryID)
        }

        actions.register(.removeRepository) { [weak context] action in
            guard case .removeRepository(let id) = action, let context, let repositoryID = id ?? context.repository?.id else {
                return
            }
            await remove(repositoryID, in: context)
        }

        actions.register(.openWith) { [weak context] action in
            guard case .openWith(let path) = action, let context, let target = path ?? context.repository?.record.path else {
                return
            }
            OpenWithSheet.present(path: target, in: context)
        }

        actions.register(.openInEditor) { [weak context] action in
            guard case .openInEditor(let path) = action, let context, let target = path ?? context.repository?.record.path else {
                return
            }
            await openInEditor(target, in: context)
        }

        actions.register(.openInTerminal) { [weak context] action in
            guard case .openInTerminal(let path) = action, let context, let target = path ?? context.repository?.record.path else {
                return
            }
            await openInShell(target, in: context)
        }

        actions.register(.showInFinder) { [weak context] action in
            guard case .showInFinder(let path) = action, let context else {
                return
            }
            if let path {
                context.app.integrations.showInFinder(path)
            } else if let repositoryPath = context.repository?.record.path {
                await showInFinder(repositoryPath, in: context)
            }
        }

        actions.register(.openWithDefaultProgram) { [weak context] action in
            guard case .openWithDefaultProgram(let path) = action, let context else {
                return
            }
            // Says when nothing could open the file.
            let integrations = context.app.integrations
            await context.presenter.perform { _ throws(OperationError) in
                try integrations.openWithDefaultApplication(path)
            }
        }
    }

    // MARK: Switching and copying

    /// Switches the window to a repository or a clone in progress (a
    /// repository row's click), closing the repository popover.
    static func switchTo(_ entry: RepositoryListEntryID, in context: WindowContext) {
        context.state.isRepositoryPopoverPresented = false
        switch entry {
        case .repository(let id):
            context.app.select(.repository(id))
        case .clone(let id):
            context.app.select(.clone(id))
        }
    }

    /// Puts `text` on the pasteboard.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Opening

    static func openInEditor(_ path: String, in context: WindowContext) async {
        let integrations = context.app.integrations
        await context.presenter.perform { _ throws(OperationError) in
            try await integrations.openInEditor(path)
        }
    }

    static func openInShell(_ path: String, in context: WindowContext) async {
        let integrations = context.app.integrations
        await context.presenter.perform { _ throws(OperationError) in
            try await integrations.openInShell(path)
        }
    }

    /// Shows a repository's folder in the Finder; one that looks like an
    /// application is revealed only after asking.
    static func showInFinder(_ path: String, in context: WindowContext) async {
        let integrations = context.app.integrations
        guard await integrations.showFolderContents(path) == .applicationBundle else {
            return
        }
        let alert = AlertContent(
            title: ShowFolderContentsResult.applicationBundleTitle,
            message: "\(ShowFolderContentsResult.applicationBundleMessage)\n\n\(ShowFolderContentsResult.applicationBundleDetail)",
            buttons: [
                AlertContent.Button(ShowFolderContentsResult.applicationBundleConfirmButton, role: .primary),
                AlertContent.Button("Cancel", role: .cancel),
            ]
        )
        if await context.modals.alert(alert).buttonIndex == 0 {
            integrations.showInFinder(path)
        }
    }

    // MARK: Removing

    /// Removes a repository (Remove… or Remove): the model asks first while
    /// "Removing repositories" is on, with "Also move this repository to
    /// Trash"; a missing repository is removed at once.
    static func remove(_ id: RepositoryID, in context: WindowContext) async {
        let app = context.app
        await context.presenter.perform { answers throws(OperationError) in
            try await app.removeRepository(id, moveToTrash: answers.moveToTrash, confirmed: answers.confirmed)
        }
    }

    // MARK: Adding

    /// Adds the repositories at `paths` (Add's panel, folders dropped on the
    /// window or the Dock icon) and presents what happened.
    static func addRepositories(_ paths: [String], in context: WindowContext) async {
        let app = context.app
        let result = await context.presenter.perform { _ throws(OperationError) in
            try await app.addRepositories(paths)
        }
        if let result {
            await present(result, in: context)
        }
    }

    /// Shows what adding repositories did, from Add or from folders opened
    /// from outside: selects the first added, else existing, else unsafe
    /// repository (the Unsafe view then offers Trust); tells about the paths
    /// that aren't repositories, offering to create one in a single such
    /// folder; then asks to initialize Git LFS where it's used.
    static func present(_ result: AddRepositoriesResult, in context: WindowContext) async {
        if let first = result.added.first ?? result.existing.first ?? result.unsafe.first {
            context.app.select(.repository(first))
        }
        if let alert = AddRepositoryAlert(result) {
            let response = await context.modals.alert(alert.content)
            if case .createRepository(let path) = alert, response.buttonIndex == 0 {
                CreateRepositorySheet.present(forFolder: path, in: context)
            }
        }
        if !result.usingLFS.isEmpty {
            await LFSAlerts.initializeLFS(in: result.usingLFS, context: context)
        }
    }

    // MARK: Cloning

    /// Clones `request`, then asks what the new repository needs: whether to
    /// initialize Git LFS, and how a fork will be used. A failure shows
    /// "Clone failed" with Retry Clone, which clones again here, so a retried
    /// clone gets the same questions. `then` goes on with the repository once
    /// it's added (a URL action's branch, pull request, and file).
    static func clone(
        _ request: CloneRequest,
        in context: WindowContext,
        then: (@MainActor (RepositoryID) async -> Void)? = nil
    ) async {
        let clones = context.app.clones
        var retry: CloneRetry?
        while true {
            let attempt = retry
            do throws(OperationError) {
                let result: CloneResult?? = try await context.presenter.performThrowing { _ throws(OperationError) -> CloneResult? in
                    if let attempt {
                        return try await clones.retry(attempt)
                    }
                    return try await clones.clone(request)
                }
                guard let result = result ?? nil else {
                    return
                }
                await followUp(result, in: context)
                await then?(result.repositoryID)
                return
            } catch {
                guard let recovery = await chooseRecovery(for: error, in: context) else {
                    return
                }
                if case .retry(let operation) = recovery, let cloneRetry = operation as? CloneRetry {
                    retry = cloneRetry
                    continue
                }
                await context.presenter.run(recovery)
                return
            }
        }
    }

    /// What a finished clone asks: initializing Git LFS, then how a fork
    /// will be used.
    static func followUp(_ result: CloneResult, in context: WindowContext) async {
        if result.usesLFS {
            await LFSAlerts.initializeLFS(in: [result.repositoryID], context: context)
        }
        if result.isFork {
            ChooseForkSettingsSheet.present(for: result.repositoryID, in: context)
        }
    }

    /// Opens Clone for a link to a repository that isn't in the list,
    /// prefilled with its URL (the `.cloneRepository(url:)` action); once
    /// cloned, the link's branch, pull request, and file follow
    /// (`continueExternalAction`).
    ///
    /// While Clone can't open (a sheet or an alert shows, or the welcome
    /// flow), the link waits and Clone opens once it can, links in the order
    /// they came.
    static func presentClone(for request: ExternalCloneRequest, in context: WindowContext) {
        let pending = context.state.featureState(PendingExternalClones.self) { PendingExternalClones() }
        pending.requests[request.url] = request
        if pending.waiting.isEmpty, context.actions.canPerform(.cloneRepository(url: request.url)) {
            context.actions.perform(.cloneRepository(url: request.url))
        } else {
            pending.wait(for: request.url, in: context)
        }
    }

    /// Shows an error the way the presenter does, and waits for the answer:
    /// the recovery chosen, or nil when the user closed it. For flows that
    /// run a recovery themselves (Retry Clone).
    static func chooseRecovery(for error: OperationError, in context: WindowContext) async -> Recovery? {
        switch error.presentation(context.app.preferences.numberFormat) {
        case .alert(let content, let recoveries):
            let response = await context.modals.alert(content)
            return recoveries.indices.contains(response.buttonIndex) ? recoveries[response.buttonIndex] : nil
        case .rawOutput(let content, let recoveries):
            let modals = context.modals
            return await withCheckedContinuation { (continuation: CheckedContinuation<Recovery?, Never>) in
                let answer = SingleAnswer(continuation)
                modals.presentSheet(id: ErrorHost.sheetID, onDismiss: {
                    answer.resume(nil)
                }) {
                    RawOutputSheet(content, onRecovery: { index in
                        answer.resume(recoveries.indices.contains(index) ? recoveries[index] : nil)
                        modals.dismissSheet(id: ErrorHost.sheetID)
                    }, onClose: {
                        modals.dismissSheet(id: ErrorHost.sheetID)
                    })
                }
            }
        case .none:
            return nil
        case .pushProtection, .createFork:
            context.presenter.present(error)
            return nil
        }
    }
}

/// Links that asked for a clone, by URL, until Clone opens for them.
@MainActor
final class PendingExternalClones {
    var requests: [String: ExternalCloneRequest] = [:]
    /// The URLs whose Clone waits until it can open, in order.
    private(set) var waiting: [String] = []
    private var waiter: Task<Void, Never>?

    /// Opens Clone for `url` once it can open, after the links waiting
    /// before it; each waits for the previous Clone to close.
    func wait(for url: String, in context: WindowContext) {
        waiting.append(url)
        guard waiter == nil else {
            return
        }
        waiter = Task { [weak self, weak context] in
            while let self, let context, let next = self.waiting.first {
                let actions = context.actions
                await Observing.until { actions.canPerform(.cloneRepository(url: next)) }
                guard !Task.isCancelled else {
                    break
                }
                self.waiting.removeFirst()
                // Clone shows before this returns, so the next link waits
                // for it to close.
                await actions.performAndWait(.cloneRepository(url: next))
            }
            self?.waiter = nil
        }
    }
}

/// Resumes a continuation once: the first answer wins.
@MainActor
final class SingleAnswer<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// What Add says about paths that aren't repositories.
nonisolated enum AddRepositoryAlert: Sendable, Equatable {
    /// One folder that isn't a repository: offers to create one there.
    case createRepository(path: String)
    /// One bare repository.
    case bareRepository(path: String)
    /// Several: one combined message.
    case invalidPaths(message: String)

    init?(_ result: AddRepositoriesResult) {
        switch result.invalidPaths.count {
        case 0:
            return nil
        case 1:
            let path = result.invalidPaths[0]
            self = result.barePaths.contains(path) ? .bareRepository(path: path) : .createRepository(path: path)
        default:
            self = .invalidPaths(message: result.invalidPathsMessage ?? "")
        }
    }

    var content: AlertContent {
        switch self {
        case .createRepository(let path):
            AlertContent(
                title: "\(path) isn't a Git repository.",
                message: "Would you like to create a repository here instead?",
                buttons: [AlertContent.Button("Create a Repository…", role: .primary), AlertContent.Button("Cancel", role: .cancel)]
            )
        case .bareRepository(let path):
            AlertContent(
                title: "This folder is a bare repository.",
                message: "Espalier doesn't support bare repositories.\n\n\(path)",
                buttons: [AlertContent.Button("OK", role: .primary)]
            )
        case .invalidPaths(let message):
            AlertContent(
                title: "Couldn't add these folders.",
                message: message,
                buttons: [AlertContent.Button("OK", role: .primary)]
            )
        }
    }
}
