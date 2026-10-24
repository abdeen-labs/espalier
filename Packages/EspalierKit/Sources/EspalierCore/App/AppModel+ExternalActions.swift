import Darwin
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Observation
import os

private let logger = Log.logger(category: "external-actions")

/// Something another app asked Espalier to do. The app delegate makes these
/// from what `application(_:open:)` receives.
public enum ExternalAction: Sendable, Equatable {
    /// An `espalier://` URL: `espalier://openRepo/<url>?branch=&pr=&filepath=`
    /// (`parseAppURL`), or a GitHub Desktop link (`x-github-client://`,
    /// `github-mac://`) with the same grammar.
    case url(URL)
    /// Folders opened with Espalier in the Finder or dropped on its Dock
    /// icon, and `espalier open <path>`: standardized paths without a
    /// trailing slash.
    case folders([String])
    /// `espalier clone [-b <branch>] <url | owner/name>`.
    case clone(url: String, branch: String?)
}

/// What handling an external action did, for the UI to present. Errors and
/// decisions the user must make are thrown instead, as by any intent.
public enum ExternalActionResult: Sendable, Equatable {
    /// A repository in the list was selected and the action's later steps
    /// ran in it.
    case opened(OpenedRepository)
    /// No repository in the list matches the URL. Show Clone on its URL tab
    /// prefilled with `request.url`; once cloned, call
    /// `continueExternalAction(_:in:confirmed:)` with the new repository so
    /// the branch, the pull request, and the file follow.
    case cloneRequested(ExternalCloneRequest)
    /// Folders were opened: those in the list (or worktrees of repositories
    /// in it) are existing, the others added, as Add adds them. Present it as
    /// Add's result. The first added, else existing, else unsafe repository
    /// is selected.
    case addedRepositories(AddRepositoriesResult)
    /// Nothing was done, for this reason: an unknown URL, for instance.
    case ignored(String)
    /// A GitHub Desktop link was passed on to GitHub Desktop, which opens
    /// it: GitHub Desktop is installed, and the setting to open them in
    /// Espalier is off or the link isn't one Espalier can open.
    case forwarded
}

/// The steps an external action ran in the repository it opened.
public struct OpenedRepository: Sendable, Equatable {
    public let repositoryID: RepositoryID
    /// What checking out the branch the action named did, when the
    /// repository has it and it wasn't the current branch. (A checkout that
    /// fails or needs the user is thrown.)
    public var checkout: CheckoutResult?
    /// The fetch before the checkout failed; the checkout went on.
    public var fetchError: OperationError?
    /// The pull request the action named, to show and check out with
    /// `RepositoryGitHubModel.checkout(_:strategy:confirmed:)`, which asks
    /// first.
    public var pullRequest: ExternalPullRequest?
    /// The file the action named, shown in the Finder. Nil when it named
    /// none, or one that is absolute, outside the repository, or missing.
    public var revealedFile: String?

    public init(
        repositoryID: RepositoryID,
        checkout: CheckoutResult? = nil,
        fetchError: OperationError? = nil,
        pullRequest: ExternalPullRequest? = nil,
        revealedFile: String? = nil
    ) {
        self.repositoryID = repositoryID
        self.checkout = checkout
        self.fetchError = fetchError
        self.pullRequest = pullRequest
        self.revealedFile = revealedFile
    }
}

/// A pull request an external action named: what showing and checking it out
/// takes. Check it out with
/// `RepositoryGitHubModel.checkout(_:strategy:confirmed:)`, which asks first
/// (`checkoutLinkedPullRequest`).
public struct ExternalPullRequest: Sendable, Equatable {
    public let number: Int
    public let title: String
    /// The login of the head repository's owner, which names a fork's
    /// remote.
    public let headRepositoryOwner: String
    /// The head repository's clone URL.
    public let headCloneURL: String
    /// The pull request's branch in the head repository.
    public let headRef: String
    /// The pull request as GitHub returned it, to show: the repository's
    /// own pull requests may not include it (a fork that contributes to
    /// itself has its own numbers).
    public var pullRequest: PullRequest?
}

/// A repository to clone before an external action can go on.
public struct ExternalCloneRequest: Sendable, Equatable {
    /// What the action asked for.
    public let action: OpenRepositoryFromURLAction
    /// The pull request the action named, already loaded.
    let pullRequest: APIPullRequest?

    /// The URL to clone.
    public var url: String {
        action.url
    }
}

extension AppModel {
    /// Handles an external action. Waits until the repository list has
    /// loaded.
    ///
    /// - `url`: a GitHub Desktop link goes to GitHub Desktop, without
    ///   waiting, when GitHub Desktop is installed and the setting to open
    ///   them in Espalier is off or the link isn't an action Espalier can
    ///   open; Espalier handles the others. With a
    ///   pull request, loads it from GitHub and opens the
    ///   repository its head or base belongs to; otherwise opens the
    ///   repository whose GitHub repository (or fork parent) the URL names.
    ///   With a branch other than the current one, the repository refreshes
    ///   and asks first (`checkoutLinkedBranch`, naming the repository and
    ///   the branch): until it's in `confirmed`, nothing is fetched or checked
    ///   out and the file isn't shown. Once confirmed, the repository fetches
    ///   and checks the branch out (local or remote, through checkout's
    ///   decisions). The current branch is neither fetched nor checked out.
    ///   Then the file is shown in the Finder. A URL no repository matches
    ///   asks for a clone; one that isn't an action is ignored.
    /// - `clone`: the same, without a pull request or file (`owner/name`
    ///   means GitHub.com).
    /// - `folders`: a folder's repository in the list is existing; a
    ///   worktree of a repository in the list switches that repository to
    ///   it; anything else is added (`addRepositories`). The first added,
    ///   else existing, else unsafe repository is selected.
    ///
    /// - Throws: `.confirmationRequired(.checkoutLinkedBranch)`, after the
    ///   repository is selected. Checking out the branch: its decisions and
    ///   confirmations (uncommitted changes), with the branch in the error's
    ///   `gitContext`, and its failures, `.precondition` when the repository
    ///   has no such branch; the file is shown first. `.precondition` for a
    ///   pull request whose fork was deleted, after the repository is
    ///   selected. A pull
    ///   request that can't be loaded: no account is signed in to its
    ///   server, or GitHub's error. A link GitHub Desktop couldn't be asked
    ///   to open.
    public func handle(_ action: ExternalAction, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> ExternalActionResult {
        if case .url(let url) = action, try await forwardToGitHubDesktop(url) {
            return .forwarded
        }
        await waitUntilLoaded()
        switch action {
        case .url(let url):
            switch parseAppURL(url.absoluteString) {
            case .openRepositoryFromURL(let action):
                return try await openRepositoryFromURL(action, confirmed: confirmed)
            case .unknown(let string):
                logger.warning("Unknown URL action: \(string, privacy: .private)")
                return .ignored("Espalier can't open this link: \(string)")
            }
        case .folders(let paths):
            return await openFolders(paths)
        case .clone(let url, let branch):
            // Assume name with owner slug if it looks like it.
            let url = isOwnerAndName(url) ? "https://github.com/\(url)" : url
            return try await openRepositoryFromURL(OpenRepositoryFromURLAction(url: url, branch: branch), confirmed: confirmed)
        }
    }

    /// Goes on with an action that asked for a clone, in the repository the
    /// clone added: its branch, pull request, and file, asking first as
    /// `handle(_:confirmed:)` does.
    ///
    /// - Throws: As `handle(_:confirmed:)`.
    public func continueExternalAction(
        _ request: ExternalCloneRequest,
        in id: RepositoryID,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) -> ExternalActionResult {
        await waitUntilLoaded()
        guard record(id) != nil else {
            logger.warning("Open Repository from URL failed, did not find or clone repository: \(request.url, privacy: .private)")
            return .ignored("The repository is no longer in the list.")
        }
        return try await openMatchedRepository(id, request.action, pullRequest: request.pullRequest, confirmed: confirmed)
    }

    // MARK: URLs

    private func openRepositoryFromURL(
        _ action: OpenRepositoryFromURLAction,
        confirmed: Set<ConfirmationKind>
    ) async throws(OperationError) -> ExternalActionResult {
        if let pr = action.pr {
            return try await openPullRequestFromURL(action, pr)
        }
        guard let id = repositoryMatchingURL(action.url) else {
            return .cloneRequested(ExternalCloneRequest(action: action, pullRequest: nil))
        }
        return try await openMatchedRepository(id, action, pullRequest: nil, confirmed: confirmed)
    }

    /// The pull request's checkout asks its own question
    /// (`RepositoryGitHubModel.checkout(_:strategy:confirmed:)`), so this
    /// needs no confirmation.
    private func openPullRequestFromURL(_ action: OpenRepositoryFromURLAction, _ pr: String) async throws(OperationError) -> ExternalActionResult {
        let pullRequest = try await fetchPullRequest(action.url, pr)

        // Find the repository where the PR is created in Espalier.
        if let id = repositoryFromPullRequest(pullRequest) ?? repositoryMatchingURL(action.url) {
            return try await openMatchedRepository(id, action, pullRequest: pullRequest, confirmed: [])
        }
        return .cloneRequested(ExternalCloneRequest(action: action, pullRequest: pullRequest))
    }

    /// Selects the repository, then runs the action's steps in it. A branch
    /// to check out asks first, unless `confirmed` has
    /// `checkoutLinkedBranch`.
    private func openMatchedRepository(
        _ id: RepositoryID,
        _ action: OpenRepositoryFromURLAction,
        pullRequest: APIPullRequest?,
        confirmed: Set<ConfirmationKind>
    ) async throws(OperationError) -> ExternalActionResult {
        select(.repository(id))
        if record(id)?.isMissing == true {
            await recoverMissingRepository(id)
        }
        guard let record = record(id), !record.isMissing, let model = repository(id) else {
            // Still missing: its missing view shows, and nothing runs in it.
            return .opened(OpenedRepository(repositoryID: id))
        }

        var opened = OpenedRepository(repositoryID: id)
        var checkoutError: OperationError?
        if let pullRequest {
            guard let gitHubRepository = record.gitHubRepository else {
                logger.warning("Received a non-GitHub repository when opening repository from URL: \(action.url, privacy: .private)")
                return .opened(opened)
            }
            // Ensure a fresh clone has its state before the next steps: the
            // pull request's checkout looks for its branch among the
            // repository's.
            await model.refresh(.full, reason: .selection)
            guard let head = pullRequest.head.repo else {
                // The head repository was deleted.
                throw OperationError(
                    .precondition("Couldn't check out pull request #\(pullRequest.number): the fork its branch was in has been deleted."),
                    operation: .checkoutPullRequest,
                    repositoryID: id
                )
            }
            opened.pullRequest = ExternalPullRequest(
                number: pullRequest.number,
                title: pullRequest.title,
                headRepositoryOwner: head.owner.login,
                headCloneURL: head.cloneURL,
                headRef: pullRequest.head.ref,
                pullRequest: background.pullRequests.store.model(for: pullRequest, in: gitHubRepository)
            )
        } else if let branch = action.branch {
            // Ensure a fresh clone has its state before the next steps.
            await model.refreshScheduler.waitForRequestedPass(covering: .full)
            if !isCurrentBranch(model, branch) {
                // Any web page can open a link, so nothing is fetched or
                // checked out until the user agrees.
                guard confirmed.contains(.checkoutLinkedBranch) else {
                    throw OperationError(
                        .confirmationRequired(.checkoutLinkedBranch(branch, repository: record.displayName)),
                        operation: .checkoutBranch,
                        repositoryID: id
                    )
                }
                // If the repo has a remote, fetch before switching branches
                // to ensure the checkout will be successful. This operation
                // could be a no-op.
                do {
                    try await model.sync.fetch()
                } catch {
                    if !error.isCancellation {
                        logger.error("Fetching before checking out \(branch, privacy: .private) failed: \(error.message, privacy: .public)")
                        opened.fetchError = error
                    }
                }
                do {
                    opened.checkout = try await checkoutLocalBranch(model, branch)
                } catch {
                    checkoutError = error
                }
            }
        }

        if let filepath = action.filepath {
            opened.revealedFile = revealFile(filepath, in: model.record.path)
        }
        if let checkoutError {
            throw checkoutError
        }
        return .opened(opened)
    }

    /// Whether the branch named `name` (a local branch, or a remote one
    /// without its remote) is the current branch.
    private func isCurrentBranch(_ model: RepositoryModel, _ name: String) -> Bool {
        guard let current = model.gitState.tip.branch else {
            return false
        }
        return JSCompat.strictEquals(current.nameWithoutRemote, name)
    }

    /// Checks out the branch named `name` (a local branch, or a remote one
    /// without its remote) unless it's the current branch.
    ///
    /// - Throws: `.precondition` when the repository has no such branch;
    ///   checkout's errors.
    private func checkoutLocalBranch(_ model: RepositoryModel, _ name: String) async throws(OperationError) -> CheckoutResult? {
        let state = model.gitState
        if isCurrentBranch(model, name) {
            return nil
        }
        guard let branch = state.branches.all.first(where: { JSCompat.strictEquals($0.nameWithoutRemote, name) }) else {
            throw OperationError(
                .precondition("Couldn't find a branch named \(name) in \(model.record.displayName)."),
                operation: .checkoutBranch,
                repositoryID: model.id
            )
        }
        return try await model.branches.checkout(branch)
    }

    /// Shows the file in the Finder, when it's a relative path inside the
    /// repository; returns the path shown.
    private func revealFile(_ filepath: String, in repositoryPath: String) -> String? {
        if POSIXPath.isAbsolute(filepath) {
            logger.error("Refusing to open absolute path: \(filepath, privacy: .private)")
            return nil
        }
        guard let resolved = resolveWithin(repositoryPath, filepath) else {
            logger.error("Prevented attempt to open path outside of the repository root: \(filepath, privacy: .private)")
            return nil
        }
        environment.workspace.revealInFinder(resolved)
        return resolved
    }

    /// The pull request `pr` of the repository at `url`: through the account
    /// of the repository in the list for it (the selected one first), asked
    /// for when it has none; else through the account that can see it,
    /// asked when several might. It throws when no account can be used, when
    /// no account's access could be checked, and when the user cancels the
    /// question.
    private func fetchPullRequest(_ url: String, _ pr: String) async throws(OperationError) -> APIPullRequest {
        let endpoint = getEndpointForRepository(url)
        let remoteURL = parseRemote(url)
        let host = remoteURL?.hostname ?? url
        let signIn = OperationError(.precondition("Sign in to \(host) to check out this pull request."), operation: .checkoutBranch)
        guard let remoteURL, !remoteURL.owner.isEmpty, !remoteURL.name.isEmpty else {
            guard !accounts.accounts(onEndpoint: endpoint).isEmpty else {
                throw signIn
            }
            throw OperationError(.precondition("\(url) isn't a GitHub repository."), operation: .checkoutBranch)
        }

        func names(_ repository: GitHubRepository?) -> Bool {
            guard let repository else {
                return false
            }
            return JSCompat.strictEquals(repository.endpoint, endpoint)
                && JSCompat.caseInsensitiveEquals(repository.owner.login, remoteURL.owner)
                && JSCompat.caseInsensitiveEquals(repository.name, remoteURL.name)
        }
        let matching = repositories.filter { names($0.gitHubRepository) || names($0.gitHubRepository?.parent) }
        let local = matching.first { selection == .repository($0.id) } ?? matching.first

        let account: Account?
        if let local {
            account = await ensureRepositoryAccount(local.id)
        } else {
            let choice: RemoteAccountChoice
            do {
                choice = try await chooseAccount(forRemote: url)
            } catch {
                throw OperationError(.api(apiFailure(from: error)), operation: .checkoutBranch, underlying: error)
            }
            switch choice {
            case .assigned(let assignment):
                account = assignment.account
            case .noAccess:
                account = nil
            case .undecided:
                throw OperationError(
                    .precondition("Couldn't check which of your accounts on \(host) can see \(remoteURL.owner)/\(remoteURL.name). Try again."),
                    operation: .checkoutBranch
                )
            case .cancelled:
                throw OperationError(.cancelled(.userCancelled), operation: .checkoutBranch)
            }
        }
        guard let account, JSCompat.strictEquals(account.endpoint, endpoint) else {
            throw signIn
        }
        let gitHub = environment.gitHub
        do {
            return try await environment.withRuntimes {
                try await API.fromAccount(account, runtime: gitHub)
                    .fetchPullRequest(owner: remoteURL.owner, name: remoteURL.name, prNumber: pr)
            }
        } catch {
            throw OperationError(.api(apiFailure(from: error)), operation: .checkoutBranch, underlying: error)
        }
    }

    /// The repository whose GitHub repository the pull request's head belongs
    /// to, else its base. None when either repository was deleted.
    private func repositoryFromPullRequest(_ pullRequest: APIPullRequest) -> RepositoryID? {
        // This likely means that the base repository has been deleted, and
        // checking out from refs/pulls/NNN/head isn't supported, so we bail.
        guard let headURL = pullRequest.head.repo?.cloneURL, let baseURL = pullRequest.base.repo?.cloneURL else {
            return nil
        }
        return repositoryMatchingURL(headURL) ?? repositoryMatchingURL(baseURL)
    }

    /// The first repository whose GitHub repository, or its parent, is the
    /// repository at `url`.
    ///
    /// Owner and name compare ignoring case, as GitHub does, so a link that
    /// spells them differently still finds the repository in the list.
    func repositoryMatchingURL(_ url: String) -> RepositoryID? {
        repositories.first { record in
            guard let gitHubRepository = record.gitHubRepository else {
                return false
            }
            return [gitHubRepository.htmlURL, gitHubRepository.parent?.htmlURL]
                .compactMap { $0 }
                .contains { urlsMatch($0, url) }
        }?.id
    }

    // MARK: Folders

    private func openFolders(_ paths: [String]) async -> ExternalActionResult {
        var result = AddRepositoriesResult()
        for path in paths {
            if let id = await switchToWorktreeOfListedRepository(path) {
                result.existing.append(id)
                result.repositories.append(id)
            } else {
                _ = await addRepository(at: path, into: &result)
            }
        }
        if !result.invalidPaths.isEmpty {
            result.invalidPathsMessage = invalidRepoPathsMessage(result.invalidPaths)
        }
        if let selected = result.added.first ?? result.existing.first ?? result.unsafe.first {
            select(.repository(selected))
        }
        return .addedRepositories(result)
    }

    /// When `path` (or the repository it's in) isn't in the list but is a
    /// worktree of a repository that is, switches that repository to it, so
    /// opening a worktree doesn't add a second repository. Returns the
    /// repository switched.
    private func switchToWorktreeOfListedRepository(_ path: String) async -> RepositoryID? {
        // The user may accidentally provide a folder within the repository;
        // this ensures we use the repository root, if it is actually a
        // repository.
        guard case .regular(let root, _) = await repositoryType(path), matchExistingRepository(root) == nil else {
            return nil
        }
        let worktrees: [WorktreeEntry]
        do {
            worktrees = try await environment.withRuntimes { try await listWorktrees(root) }
        } catch {
            logger.error("Could not list worktrees: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        func isWorktree(_ candidate: String) -> Bool {
            worktrees.contains { JSCompat.strictEquals(POSIXPath.normalize($0.path), POSIXPath.normalize(candidate)) }
        }
        guard let worktree = worktrees.first(where: { JSCompat.strictEquals(POSIXPath.normalize($0.path), POSIXPath.normalize(root)) }),
              let listed = repositories.first(where: { isWorktree($0.path) }),
              matchExistingRepository(root) == nil,
              let model = repository(listed.id)
        else {
            return nil
        }
        do {
            try await model.worktrees.switchToWorktree(worktree)
        } catch {
            logger.error("Could not switch to the worktree at \(root, privacy: .private): \(error.message, privacy: .public)")
            return nil
        }
        return listed.id
    }

    // MARK: Loading

    /// Waits until the repository list has loaded, loading it if nothing
    /// has (actions can arrive while the app launches).
    func waitUntilLoaded() async {
        if loadState == .notLoaded {
            await load()
        }
        while loadState != .ready {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = self.loadState
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}

/// `/^[^\/]+\/[^\/]+$/`: an owner and name, such as `torvalds/linux`.
private func isOwnerAndName(_ string: String) -> Bool {
    let parts = string.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
}

/// Resolves `segments` against `rootPath` when the result is at or under
/// it, with symbolic links resolved; nil otherwise, and when either can't
/// be resolved.
///
/// The result must be the root itself or a path below it: a plain prefix
/// check would let `/repo-other/file` through for the root `/repo`.
func resolveWithin(_ rootPath: String, _ segments: String...) -> String? {
    // An empty root path would let all relative paths through.
    guard !rootPath.isEmpty else {
        return nil
    }
    let normalizedRoot = POSIXPath.normalize(rootPath)
    let normalizedRelative = POSIXPath.normalize(POSIXPath.join(segments))

    // Null bytes has no place in paths.
    guard !normalizedRoot.unicodeScalars.contains("\0"), !normalizedRelative.unicodeScalars.contains("\0") else {
        return nil
    }

    // Resolve to an absolute path. Note that this will not contain any
    // directory traversal segments.
    let resolved = POSIXPath.resolve(normalizedRoot, normalizedRelative)

    guard let realRoot = realPathIfExists(normalizedRoot), let realResolved = realPathIfExists(resolved) else {
        return nil
    }
    let rootPrefix = JSCompat.endsWith(realRoot, "/") ? realRoot : realRoot + "/"
    return JSCompat.strictEquals(realResolved, realRoot) || JSCompat.startsWith(realResolved, rootPrefix) ? resolved : nil
}

/// `realpath(3)`, or nil when the path doesn't exist.
private func realPathIfExists(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else {
        return nil
    }
    defer { free(resolved) }
    return String(cString: resolved)
}
