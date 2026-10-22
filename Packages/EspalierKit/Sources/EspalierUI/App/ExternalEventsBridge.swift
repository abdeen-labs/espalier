// Where URL opens, folder opens from Finder, and folders dropped on the Dock
// icon go. They wait until the main window is up, then each brings Espalier
// and the window to the front and runs through
// `AppModel.handle(_:confirmed:)`, with the window's presenter showing its
// errors and asking its questions: a link's branch or pull request is
// checked out only once the user agrees, and a link Espalier can't act on
// says why.

import AppKit
import EspalierCore
import GitKit
import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "external-events")

extension ExternalAction {
    /// The actions for URLs the app was asked to open: file URLs become one
    /// folders action, the others URL actions.
    nonisolated public static func actions(for urls: [URL]) -> [ExternalAction] {
        let folders = urls.filter(\.isFileURL).map { url in
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        var actions = urls.filter { !$0.isFileURL }.map(ExternalAction.url)
        if !folders.isEmpty {
            actions.append(.folders(folders))
        }
        return actions
    }

    /// The actions for an Apple event the app handles itself: "get URL"
    /// (an `espalier://` link) or "open documents" (folders opened from
    /// Finder or dropped on the Dock icon). Other events give none.
    nonisolated public static func actions(forAppleEvent event: NSAppleEventDescriptor) -> [ExternalAction] {
        guard let directObject = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            return []
        }
        switch (event.eventClass, event.eventID) {
        case (AEEventClass(kInternetEventClass), AEEventID(kAEGetURL)):
            guard let string = directObject.stringValue, let url = URL(string: string) else {
                return []
            }
            return actions(for: [url])
        case (AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments)):
            // A list of files, or a single one.
            let items = directObject.numberOfItems > 0
                ? (1...directObject.numberOfItems).compactMap { directObject.atIndex($0) }
                : [directObject]
            return actions(for: items.compactMap(\.fileURLValue))
        default:
            return []
        }
    }
}

/// Holds external actions until the main window is up, then runs them one
/// at a time, in the order they arrived.
@MainActor
public final class ExternalEventsBridge {
    private var pending: [ExternalAction] = []
    private weak var context: WindowContext?
    private var runner: Task<Void, Never>?

    public init() {}

    /// Starts running actions in the main window `context`, beginning with
    /// the ones that arrived first.
    public func attach(_ context: WindowContext) {
        self.context = context
        runPending()
    }

    /// Runs `action` once the main window is up and the actions before it
    /// have finished.
    public func deliver(_ action: ExternalAction) {
        switch action {
        case .url(let url):
            logger.info("Received a \(url.scheme ?? "", privacy: .public) link: \(url.absoluteString, privacy: .private)")
        case .folders(let paths):
            logger.info("Received \(paths.count) folders to open")
        case .clone:
            logger.info("Received a clone")
        }
        pending.append(action)
        runPending()
    }

    /// Waits until the actions delivered so far have run.
    func idle() async {
        while let runner {
            await runner.value
        }
    }

    private func runPending() {
        guard runner == nil, context != nil, !pending.isEmpty else {
            return
        }
        runner = Task {
            while let context, !pending.isEmpty {
                await Self.run(pending.removeFirst(), in: context)
            }
            runner = nil
        }
    }

    /// Brings Espalier and the main window to the front, then runs `action`
    /// through the window's presenter and presents what it did. A link
    /// GitHub Desktop opens leaves Espalier where it is.
    ///
    /// A link's question (`checkoutLinkedBranch`) runs the whole action
    /// again once confirmed; cancelled, the repository stays selected with
    /// nothing fetched or checked out. A checkout the action started that
    /// needs a decision or a confirmation is thrown with the branch in the
    /// error's `gitContext`; once answered, the branch is checked out again
    /// with the answers rather than the whole action rerun.
    static func run(_ action: ExternalAction, in context: WindowContext) async {
        switch action {
        case .url(let url) where context.app.passesToGitHubDesktop(url):
            // GitHub Desktop opens the link.
            break
        default:
            // The app that sent the action, such as a browser, can leave
            // Espalier behind it, and `activate()` does nothing unless that
            // app yielded activation first.
            NSApp.activate(ignoringOtherApps: true)
            context.revealWindow()
        }
        await run({ app, answers throws(OperationError) in try await app.handle(action, confirmed: answers.confirmed) }, in: context)
    }

    /// Goes on with a link that asked for a clone, in the repository the
    /// clone added (`continueExternalAction`): its branch, pull request, and
    /// file, asked and presented as `run` asks and presents an action.
    static func continueAfterClone(_ request: ExternalCloneRequest, in id: RepositoryID, context: WindowContext) async {
        await run({ app, answers throws(OperationError) in
            try await app.continueExternalAction(request, in: id, confirmed: answers.confirmed)
        }, in: context)
    }

    private static func run(
        _ intent: @escaping @MainActor (AppModel, IntentAnswers) async throws(OperationError) -> ExternalActionResult,
        in context: WindowContext
    ) async {
        let app = context.app
        let retry = PendingCheckout()
        let result = await context.presenter.perform { answers throws(OperationError) in
            if let repository = retry.repository, let branch = retry.branch {
                let checkout = try await repository.branches.checkout(branch, strategy: answers.strategy, confirmed: answers.confirmed)
                return ExternalActionResult.opened(OpenedRepository(repositoryID: repository.id, checkout: checkout))
            }
            do throws(OperationError) {
                return try await intent(app, answers)
            } catch {
                retry.remember(error, in: app)
                throw error
            }
        }
        if let result {
            await present(result, in: context)
        }
    }

    /// Shows what an action did, or why it did nothing. The app model has
    /// already selected the repository and shown the action's file in the
    /// Finder.
    static func present(_ result: ExternalActionResult, in context: WindowContext) async {
        switch result {
        case .opened(let opened):
            if let fetchError = opened.fetchError {
                context.presenter.present(fetchError)
            }
            if let checkout = opened.checkout, let toast = BranchActions.toast(for: checkout) {
                context.presenter.show(toast)
            }
            if let pullRequest = opened.pullRequest {
                if let model = pullRequest.pullRequest {
                    context.state.show(linked: model, in: opened.repositoryID)
                } else {
                    context.select(.pullRequest(number: pullRequest.number))
                }
                await checkOut(pullRequest, in: opened.repositoryID, context: context)
            }

        case .cloneRequested(let request):
            // Clone opens on URL with the link's repository, once the
            // sheets and alerts in front of it close; once it's cloned,
            // `continueAfterClone` runs the link's later steps.
            RepositoryActions.presentClone(for: request, in: context)

        case .addedRepositories(let added):
            await RepositoryActions.present(added, in: context)

        case .ignored(let reason):
            logger.info("Ignored an external action: \(reason, privacy: .private)")
            context.presenter.present(OperationError(.precondition(reason), operation: .openLink))

        case .forwarded:
            // GitHub Desktop opens the link.
            break
        }
    }
}

extension ExternalEventsBridge {
    /// Checks out a link's pull request, asking first (naming the pull
    /// request, and the remote added for its fork), then about uncommitted
    /// changes as any checkout does, and shows what it did. Cancelled, the
    /// pull request stays shown with nothing added, fetched, or checked out.
    static func checkOut(_ pullRequest: ExternalPullRequest, in id: RepositoryID, context: WindowContext) async {
        guard let repository = context.app.repository(id) else {
            return
        }
        let result = await context.presenter.perform { answers throws(OperationError) in
            try await repository.gitHub.checkout(pullRequest, strategy: answers.strategy, confirmed: answers.confirmed)
        }
        if let result, let toast = BranchActions.toast(for: result) {
            context.presenter.show(toast)
        }
    }
}

/// The checkout an external action left waiting for an answer.
@MainActor
private final class PendingCheckout {
    private(set) var repository: RepositoryModel?
    private(set) var branch: Branch?

    /// Keeps the checkout `error` asks about, if it's a checkout's decision
    /// or confirmation.
    func remember(_ error: OperationError, in app: AppModel) {
        switch error.reason {
        case .decisionRequired, .confirmationRequired:
            break
        default:
            return
        }
        guard case .checkout(let branch)? = error.gitContext, let id = error.repositoryID, let repository = app.repository(id) else {
            return
        }
        self.repository = repository
        self.branch = branch
    }
}
