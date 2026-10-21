// The GitHub actions: the pages that open in the browser (View on GitHub,
// Create Issue on GitHub, the branch and its comparison on GitHub, a pull
// request; `GitHubWebURLs`), signing in (the device-flow sheet, then a
// recovery's operation runs again), checking out a pull request through the
// uncommitted changes decision, Create and Preview Pull Request, and the
// recoveries for forks and push protection.
//
// It runs for the main window and for Settings (which signs in from
// Accounts), so it only registers handlers and sets the window's image
// loader; everything it shows goes through the window's own presenter and
// modal presenter.

import EspalierCore
import GitHubKit
import GitKit
import Foundation
import SwiftUI

/// Registers the GitHub actions.
@MainActor
enum GitHubActions {
    static func register(into actions: WindowActions, context: WindowContext) {
        context.useAuthenticatedImageLoader()
        registerPages(into: actions, context: context)
        registerSignIn(into: actions, context: context)
        registerPullRequests(into: actions, context: context)
        registerRecoveries(into: actions, context: context)
    }

    // MARK: Pages

    private static func registerPages(into actions: WindowActions, context: WindowContext) {
        actions.register(.viewOnGitHub) { [weak context] _ in
            guard let context, let record = context.repository?.record else {
                return
            }
            open(GitHubWebURLs.repository(record), in: context)
        }

        actions.register(.createIssueOnGitHub) { [weak context] _ in
            guard let context, let record = context.repository?.record else {
                return
            }
            open(GitHubWebURLs.newIssue(record), in: context)
        }

        // The current branch's upstream, or a named local branch's.
        actions.register(.viewBranchOnGitHub) { [weak context] action in
            guard case .viewBranchOnGitHub(let name) = action, let context, let repository = context.repository,
                  let gitHubRepository = repository.record.gitHubRepository,
                  let branch = branch(named: name, in: repository) else {
                return
            }
            open(GitHubWebURLs.branch(branch, in: gitHubRepository), in: context)
        }

        actions.register(.compareOnGitHub) { [weak context] _ in
            guard let context, let repository = context.repository,
                  let gitHubRepository = repository.record.gitHubRepository,
                  let branch = branch(named: nil, in: repository) else {
                return
            }
            open(GitHubWebURLs.compare(branch, in: gitHubRepository), in: context)
        }

        actions.register(.viewPullRequestOnGitHub, isEnabled: { [weak context] action in
            guard case .viewPullRequestOnGitHub(let number) = action, let repository = context?.repository else {
                return false
            }
            return pullRequestURL(number, in: repository) != nil
        }) { [weak context] action in
            guard case .viewPullRequestOnGitHub(let number) = action, let context, let repository = context.repository else {
                return
            }
            open(pullRequestURL(number, in: repository), in: context)
        }
    }

    // MARK: Signing in

    private static func registerSignIn(into actions: WindowActions, context: WindowContext) {
        actions.register(.signIn) { [weak context] action in
            guard case .signIn(let endpoint, let then) = action, let context else {
                return
            }
            presentSignIn(SignInRequest(endpoint: endpoint, reason: then == nil ? .user : .recovery), then: then, in: context)
        }
    }

    /// Shows the sign-in sheet; once signed in, `then` (a recovery's
    /// operation) runs again through the window's presenter.
    static func presentSignIn(_ request: SignInRequest, then: (any RetryableOperation)?, in context: WindowContext) {
        context.modals.presentSheet(id: SignInSheet.sheetID) { [weak context] in
            SignInSheet(request: request) { account in
                guard let context else {
                    return
                }
                Task {
                    await finishSignIn(account, then: then, in: context)
                }
            }
        }
    }

    /// After a sign-in: a recovery's operation runs again once the user
    /// signed in, and reports its outcome as its first run does; a
    /// cancelled sign-in runs nothing.
    static func finishSignIn(_ account: Account?, then: (any RetryableOperation)?, in context: WindowContext) async {
        guard account != nil, let then else {
            return
        }
        let app = context.app
        let outcome = await context.presenter.perform { answers throws(OperationError) in
            try await then.perform(in: app, confirmed: answers.confirmed)
        }
        context.presenter.report(outcome)
    }

    // MARK: Pull requests

    private static func registerPullRequests(into actions: WindowActions, context: WindowContext) {
        // Checking out the current branch's pull request does nothing.
        actions.register(.checkoutPullRequest, isEnabled: { [weak context] action in
            guard case .checkoutPullRequest(let number) = action, let repository = context?.repository else {
                return false
            }
            // Not while an operation is in progress (the intent refuses).
            return repository.record.gitHubRepository != nil
                && repository.gitHub.currentPullRequest?.pullRequestNumber != number
                && repository.operations.checkoutRefusal == nil
        }) { [weak context] action in
            guard case .checkoutPullRequest(let number) = action, let context, let repository = context.repository else {
                return
            }
            await context.presenter.perform { answers throws(OperationError) in
                try await repository.gitHub.checkoutPullRequest(number: number, strategy: answers.strategy, confirmed: answers.confirmed)
            } outcome: { result in
                BranchActions.toast(for: result)
            }
        }

        // "Create Pull Request…", or "View Pull Request on GitHub" when the
        // branch has one.
        actions.register(.createPullRequest) { [weak context] _ in
            guard let context, let repository = context.repository else {
                return
            }
            if let url = repository.gitHub.currentPullRequestURL {
                context.app.integrations.openInBrowser(url)
                return
            }
            await CreatePullRequestPrompts.run(in: context)
        }

        actions.register(.previewPullRequest) { [weak context] _ in
            guard let context else {
                return
            }
            PreviewPullRequestSheet.present(in: context)
        }
    }

    // MARK: Recoveries

    private static func registerRecoveries(into actions: WindowActions, context: WindowContext) {
        actions.register(.createFork) { [weak context] action in
            guard case .createFork(let repositoryID) = action, let context else {
                return
            }
            CreateForkSheet.present(repositoryID: repositoryID, in: context)
        }

        actions.register(.reviewPushProtection) { [weak context] action in
            guard case .reviewPushProtection(let repositoryID, let secrets) = action, let context else {
                return
            }
            PushProtectionSheet.present(repositoryID: repositoryID, secrets: secrets, in: context)
        }
    }

    // MARK: Helpers

    /// The local branch named `name`, or the current branch when nil.
    private static func branch(named name: String?, in repository: RepositoryModel) -> Branch? {
        guard let name else {
            return repository.gitState.tip.branch
        }
        return repository.gitState.branches.all.first { $0.type == .local && $0.name == name }
    }

    /// Pull request `number`'s page, or the current branch's pull
    /// request's when nil.
    static func pullRequestURL(_ number: Int?, in repository: RepositoryModel) -> URL? {
        guard let number else {
            return repository.gitHub.currentPullRequestURL
        }
        if let pullRequest = repository.gitHub.openPullRequests.first(where: { $0.pullRequestNumber == number }) {
            return GitHubWebURLs.pullRequest(pullRequest)
        }
        return getNonForkGitHubRepository(repository.record).flatMap { GitHubWebURLs.pullRequest(number: number, in: $0) }
    }

    /// Opens `url` in the browser; nothing when there's no page (no GitHub
    /// repository, or a branch without an upstream).
    private static func open(_ url: URL?, in context: WindowContext) {
        guard let url else {
            return
        }
        context.app.integrations.openInBrowser(url)
    }
}
