import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "pull-requests")

/// What must happen before a pull request can be created from the current
/// branch.
public enum CreatePullRequestStep: Sendable, Equatable {
    /// The branch has no upstream: it must be published first.
    case publishBranch(Branch)
    /// The branch has commits its upstream doesn't: push them first, or
    /// create the pull request without them.
    case pushCommits(Branch, unpushedCommits: Int)

    public var title: String {
        switch self {
        case .publishBranch: "Publish Branch?"
        case .pushCommits: "Push Local Changes?"
        }
    }

    public var message: String {
        switch self {
        case .publishBranch(let branch):
            return "\(branch.name) needs to be published before you can open a pull request for it."
        case .pushCommits(let branch, let unpushedCommits):
            if unpushedCommits == 1 {
                return "\(branch.name) has 1 local commit that hasn't been pushed. Push it before opening the pull request?"
            }
            return "\(branch.name) has \(unpushedCommits) local commits that haven't been pushed. Push them before opening the pull request?"
        }
    }

    /// The default button: "Publish Branch" or "Push Commits".
    public var confirmButton: String {
        switch self {
        case .publishBranch: "Publish Branch"
        case .pushCommits: "Push Commits"
        }
    }

    /// The other button, for pushing commits: "Create Without Pushing".
    public var alternativeButton: String? {
        switch self {
        case .publishBranch: nil
        case .pushCommits: "Create Without Pushing"
        }
    }
}

/// The user's answer to a `CreatePullRequestStep`.
public enum CreatePullRequestChoice: Sendable, Equatable {
    /// Publish the branch, or push its commits, then create the pull request.
    case pushFirst
    /// Create the pull request without pushing the local commits.
    case createWithoutPushing
}

/// What `createPullRequest(base:choice:)` did.
public enum CreatePullRequestOutcome: Sendable, Equatable {
    /// GitHub's form for the pull request opened in the browser.
    case opened(URL)
    /// Nothing ran: ask, then call again with the choice.
    case choiceRequired(CreatePullRequestStep)
    /// The repository has no remote: publish it first (from the push).
    case publishRepositoryRequired
}

extension RepositoryGitHubModel {
    // MARK: Checking out

    /// Checks out a pull request's branch.
    ///
    /// The pull request's head repository is found among the remotes, or
    /// added as a remote named `espalier-<owner>`; its branch is fetched
    /// when it isn't known yet. A local branch that tracks it is checked
    /// out; otherwise a branch of the repository's own remotes is checked
    /// out as a local branch tracking it, and a fork's as `pr/<number>`
    /// (many pull requests from forks come from their default branch, which
    /// would clash with a local branch).
    ///
    /// The checkout is `BranchesModel.checkout(_:strategy:confirmed:)`'s,
    /// with its decision for uncommitted changes and its confirmations:
    /// answer them by calling again with the choice.
    ///
    /// - Throws: `.precondition("Finish or abort the merge first.")` (naming
    ///   the operation) while one is in progress, before anything is added,
    ///   fetched, or created; `.other` when the fork's remote can't be
    ///   added, or when the pull request's branch can't be found (its author
    ///   may have deleted the branch or the fork); the fetch's errors; the
    ///   checkout's.
    @discardableResult
    public func checkout(
        _ pullRequest: PullRequest,
        strategy: UncommittedChangesStrategy? = nil,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) -> CheckoutResult {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .checkoutPullRequest)
        }
        try repository.branches.requireCheckoutAllowed(.checkoutPullRequest)
        let branch = try await findPullRequestBranch(pullRequest, in: repository)
        return try await repository.branches.checkout(branch, strategy: strategy, confirmed: confirmed)
    }

    /// Checks out the pull request a link named: by its head's owner, clone
    /// URL, and branch, without looking the pull request up again. Its head may
    /// be this very repository, a fork that contributes to itself, whose own
    /// pull requests don't include it.
    ///
    /// Asks first, unless `confirmed` has `checkoutLinkedPullRequest` or the
    /// pull request's branch is the current one: until then, no remote is
    /// added and nothing is fetched, created, or checked out. The question
    /// names the repository, the pull request, and the remote added for its
    /// fork when the repository has none for it.
    ///
    /// The fork remote, the fetch, `pr/<number>`, the checkout's decision
    /// and confirmations, and the errors are `checkout(_:strategy:confirmed:)`'s.
    ///
    /// - Throws: `.confirmationRequired(.checkoutLinkedPullRequest)`; then as
    ///   `checkout(_:strategy:confirmed:)`.
    @discardableResult
    public func checkout(
        _ pullRequest: ExternalPullRequest,
        strategy: UncommittedChangesStrategy? = nil,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) -> CheckoutResult {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .checkoutPullRequest)
        }
        // Any web page can open a link, so the user agrees before anything
        // is added, fetched, or checked out.
        if !confirmed.contains(.checkoutLinkedPullRequest), let confirmation = await linkedCheckoutConfirmation(pullRequest, in: repository) {
            throw OperationError(.confirmationRequired(confirmation), operation: .checkoutPullRequest, repositoryID: repository.id)
        }
        let branch = try await findPullRequestBranch(
            number: pullRequest.number,
            headRepositoryOwner: pullRequest.headRepositoryOwner,
            headCloneURL: pullRequest.headCloneURL,
            headRef: pullRequest.headRef,
            in: repository
        )
        return try await repository.branches.checkout(branch, strategy: strategy, confirmed: confirmed)
    }

    /// Checks out pull request `number`, loading it from GitHub when it
    /// isn't among the open pull requests (a link's or a notification's).
    ///
    /// - Throws: `.precondition` when GitHub can't say what the pull request
    ///   is; otherwise as `checkout(_:strategy:confirmed:)`.
    @discardableResult
    public func checkoutPullRequest(
        number: Int,
        strategy: UncommittedChangesStrategy? = nil,
        confirmed: Set<ConfirmationKind> = []
    ) async throws(OperationError) -> CheckoutResult {
        guard let pullRequest = await pullRequest(number: number) else {
            throw OperationError(
                .precondition("Couldn't find pull request #\(number)."),
                operation: .checkoutPullRequest,
                repositoryID: repository?.id
            )
        }
        return try await checkout(pullRequest, strategy: strategy, confirmed: confirmed)
    }

    /// The branch `pullRequest`'s commits are on, as checking it out finds it
    /// (dropping commits on a pull request uses it to pick the cherry-pick's
    /// target): a local branch that tracks its head, else the remote branch of
    /// one of the repository's own remotes, else `pr/<number>`, created from a
    /// fork's branch. A fork's remote may be added and its branch fetched
    /// first.
    ///
    /// - Throws: As `checkout(_:strategy:confirmed:)`, before its checkout.
    public func branch(for pullRequest: PullRequest) async throws(OperationError) -> Branch {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .checkoutPullRequest)
        }
        return try await findPullRequestBranch(pullRequest, in: repository)
    }

    /// The question checking out a link's pull request asks: nil when its
    /// branch is already the current one, so the checkout does nothing.
    private func linkedCheckoutConfirmation(_ pullRequest: ExternalPullRequest, in repository: RepositoryModel) async -> Confirmation? {
        let remote = await headRemote(pullRequest.headCloneURL, in: repository)
        if let remote,
           let tracking = localBranchTracking("\(remote.name)/\(pullRequest.headRef)", in: repository),
           let current = repository.gitState.tip.branch,
           JSCompat.strictEquals(current.name, tracking.name) {
            return nil
        }
        let forkRemote: Remote? = remote == nil
            ? Remote(name: forkPullRequestRemoteName(pullRequest.headRepositoryOwner), url: pullRequest.headCloneURL)
            : nil
        return .checkoutLinkedPullRequest(
            number: pullRequest.number,
            title: pullRequest.title,
            repository: repository.record.displayName,
            forkRemote: forkRemote
        )
    }

    /// The repository's remote for a pull request's head repository, set up
    /// by Espalier or outside it; nil when it has none.
    private func headRemote(_ headCloneURL: String, in repository: RepositoryModel) async -> Remote? {
        let gitRepository = repository.gitRepository
        let remotes = await repository.environment.withRuntimes {
            (try? await getRemotes(gitRepository)) ?? []
        }
        return remotes.first { urlMatchesRemote(headCloneURL, remoteURL: $0.url) }
    }

    /// The first local branch that tracks `remoteRef`.
    private func localBranchTracking(_ remoteRef: String, in repository: RepositoryModel) -> Branch? {
        repository.gitState.branches.all.first { branch in
            branch.type == .local && branch.upstream.map { JSCompat.strictEquals($0, remoteRef) } == true
        }
    }

    /// The branch a pull request model's commits are on.
    private func findPullRequestBranch(_ pullRequest: PullRequest, in repository: RepositoryModel) async throws(OperationError) -> Branch {
        let head = pullRequest.head
        guard let headCloneURL = head.gitHubRepository.cloneURL else {
            throw notFound(head.ref, remote: nil, repository)
        }
        return try await findPullRequestBranch(
            number: pullRequest.pullRequestNumber,
            headRepositoryOwner: head.gitHubRepository.owner.login,
            headCloneURL: headCloneURL,
            headRef: head.ref,
            in: repository
        )
    }

    /// The branch a pull request's commits are on, from its number and its
    /// head's owner, clone URL, and branch.
    private func findPullRequestBranch(
        number: Int,
        headRepositoryOwner: String,
        headCloneURL: String,
        headRef headRefName: String,
        in repository: RepositoryModel
    ) async throws(OperationError) -> Branch {

        // Find an existing remote (regardless if set up by us or outside of
        // Espalier).
        var remote = await headRemote(headCloneURL, in: repository)

        // If we can't find one we'll create a fork remote, marked as
        // Espalier's so it's hidden and pruned once unused. Remote
        // configuration holds the network lane (it's shared by worktrees).
        if remote == nil {
            let forkRemoteName = forkPullRequestRemoteName(headRepositoryOwner)
            let descriptor = OperationDescriptor(kind: .checkoutPullRequest, lanes: [.network], refreshAfter: [.remotes, .refs])
            do {
                remote = try await repository.perform(descriptor) { ctx in
                    let added = try await addRemote(ctx.repository, forkRemoteName, headCloneURL)
                    try await markForkRemote(ctx.repository, forkRemoteName)
                    return added
                }
            } catch {
                throw OperationError(
                    .other("Couldn't add a remote for the pull request's fork. \(error.message)"),
                    operation: .checkoutPullRequest,
                    repositoryID: repository.id,
                    underlying: error
                )
            }
            await repository.awaitOperationRefresh(covering: [.remotes, .refs])
        }
        guard let remote else {
            throw notFound(headRefName, remote: nil, repository)
        }

        let remoteRef = "\(remote.name)/\(headRefName)"

        // Start by trying to find a local branch that is tracking the remote
        // ref.
        if let existing = localBranchTracking(remoteRef, in: repository) {
            return existing
        }

        func findRemoteBranch() -> Branch? {
            repository.gitState.branches.all.first { $0.type == .remote && JSCompat.strictEquals($0.name, remoteRef) }
        }

        // No such luck, let's see if we can at least find the remote branch
        // then. It's quite possible that the PR was created after our last
        // fetch of the remote so let's fetch it and then try again.
        var existingBranch = findRemoteBranch()
        if existingBranch == nil {
            try await repository.sync.fetchRemote(remote)
            existingBranch = findRemoteBranch()
        }
        guard existingBranch != nil else {
            throw notFound(headRefName, remote: remote.name, repository)
        }

        // For fork remotes we checkout the ref as pr/[123] instead of using
        // the head ref name since many PRs from forks are created from their
        // default branch so we'll have a very high likelihood of a
        // conflicting local branch
        let remotesState = repository.gitState.remotes
        let isForkRemote = remote.name != remotesState.defaultRemote?.name && remote.name != remotesState.upstreamRemote?.name
        if isForkRemote {
            return try await repository.branches.createBranch(
                "pr/\(number)",
                startPoint: remoteRef,
                noTrack: false,
                checkout: false
            )
        }

        return existingBranch!
    }

    private func notFound(_ headRefName: String, remote: String?, _ repository: RepositoryModel) -> OperationError {
        let location = remote.map { " on \($0)" } ?? ""
        return OperationError(
            .other(
                "Couldn't find the branch \(headRefName)\(location). "
                    + "The pull request's author may have deleted the branch or the fork."
            ),
            operation: .checkoutPullRequest,
            repositoryID: repository.id
        )
    }

    // MARK: Creating

    /// "Create Pull Request": opens GitHub's form for a pull request from the
    /// current branch into `base` (the default branch when nil) once the branch
    /// is on GitHub.
    ///
    /// A branch without an upstream must be published first, and one with
    /// unpushed commits may push them first: without `choice`, nothing runs and
    /// `.choiceRequired` carries the question. With `.pushFirst`, the branch is
    /// published or pushed, then the form opens; with `.createWithoutPushing`,
    /// the form opens at once.
    ///
    /// Pass the same `base` again with the choice.
    ///
    /// - Throws: `.precondition` without a GitHub repository or a current
    ///   branch; the push's errors.
    public func createPullRequest(base: Branch? = nil, choice: CreatePullRequestChoice? = nil) async throws(OperationError) -> CreatePullRequestOutcome {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .createPullRequest)
        }
        guard repository.record.gitHubRepository != nil else {
            throw OperationError(.precondition("Only repositories on GitHub can have pull requests."), operation: .createPullRequest, repositoryID: repository.id)
        }
        guard case .valid(let compareBranch) = repository.gitState.tip else {
            throw OperationError(.precondition("The current branch isn't known yet."), operation: .createPullRequest, repositoryID: repository.id)
        }

        let step: CreatePullRequestStep?
        if let aheadBehind = repository.gitState.aheadBehind {
            step = aheadBehind.ahead > 0 ? .pushCommits(compareBranch, unpushedCommits: aheadBehind.ahead) : nil
        } else {
            step = .publishBranch(compareBranch)
        }

        if let step {
            switch (step, choice) {
            case (_, nil), (.publishBranch, .createWithoutPushing?):
                return .choiceRequired(step)
            case (.publishBranch, .pushFirst?):
                if case .publishRepositoryRequired = try await repository.sync.publishBranch() {
                    return .publishRepositoryRequired
                }
            case (.pushCommits, .pushFirst?):
                if case .publishRepositoryRequired = try await repository.sync.push() {
                    return .publishRepositoryRequired
                }
            case (.pushCommits, .createWithoutPushing?):
                break
            }
        }

        // The branch as it is now (pushing gave it an upstream).
        let branch = repository.gitState.tip.branch ?? compareBranch
        guard let url = GitHubWebURLs.createPullRequest(for: repository.record, compare: branch, base: base) else {
            throw OperationError(.precondition("The repository's page on GitHub isn't known yet."), operation: .createPullRequest, repositoryID: repository.id)
        }
        _ = app.integrations.openInBrowser(url)
        return .opened(url)
    }

    // MARK: Push protection

    /// Asks GitHub to allow pushing a detected secret, with the reason the user
    /// gave. Then the user pushes again.
    ///
    /// - Throws: `.api` with "Couldn't create the push protection bypass...",
    ///   which ends with the bypass page's address; `.precondition` without a
    ///   GitHub repository or an account.
    @discardableResult
    public func bypassPushProtection(_ secret: SecretScanResult, reason: BypassReason) async throws(OperationError) -> APICreatePushProtectionBypassResponse {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .push)
        }
        guard let gitHubRepository = repository.record.gitHubRepository else {
            logger.error("[bypassPushProtection] - No GitHub repository selected")
            throw OperationError(.precondition("Only repositories on GitHub can bypass push protection."), operation: .push, repositoryID: repository.id)
        }
        guard let account = app.accounts.account(forEndpoint: gitHubRepository.endpoint) else {
            logger.error("[bypassPushProtection] - No account found for endpoint - \(gitHubRepository.endpoint, privacy: .public)")
            throw OperationError(
                .precondition("Sign in to \(getHTMLURL(gitHubRepository.endpoint)) to bypass push protection."),
                operation: .push,
                repositoryID: repository.id
            )
        }
        let api = API.fromAccount(account, runtime: repository.environment.gitHub)
        do {
            return try await api.createPushProtectionBypass(
                owner: gitHubRepository.owner.login,
                name: gitHubRepository.name,
                reason: reason,
                placeholderId: secret.id,
                bypassURL: secret.bypassURL
            )
        } catch {
            throw OperationError(.api(apiFailure(from: error)), operation: .push, repositoryID: repository.id, underlying: error)
        }
    }

    /// Opens GitHub's page for bypassing push protection for `secret`, where
    /// the user gives a reason or, when the secret needs approval, asks for
    /// it (the dialog's link). Use `bypassPushProtection(_:reason:)` to
    /// bypass from Espalier.
    ///
    /// - Throws: `.other` when the page isn't on github.com or the
    ///   repository's GitHub server (`bypassPage(onGitHubAt:)`), or doesn't
    ///   open.
    public func bypassPushProtection(_ secret: SecretScanResult) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .push)
        }
        guard let url = secret.bypassPage(onGitHubAt: repository.record.gitHubRepository?.endpoint) else {
            throw OperationError(.other("Espalier didn't open the bypass page: it isn't on GitHub."), operation: .push, repositoryID: repository.id)
        }
        guard app.integrations.openInBrowser(url) else {
            throw OperationError(.other("Couldn't open \(secret.bypassURL)."), operation: .push, repositoryID: repository.id)
        }
    }
}
