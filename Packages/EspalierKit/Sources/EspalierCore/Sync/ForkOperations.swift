// Ported from desktop/app/src/lib/stores/helpers/find-forked-remotes-to-prune.ts

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "forks")

/// Function to determine which of the fork remotes added by the app are not
/// referenced anymore (by pull requests or local branches) and can be removed
/// from a repository.
///
/// Fork remotes are named `espalier-<owner>` or `github-desktop-<owner>`.
///
/// - Parameters:
///   - remotes: All remotes available in the repository.
///   - openPRs: All open pull requests available in the repository.
///   - allBranches: All branches available in the repository.
public func findForkedRemotesToPrune(_ remotes: [Remote], _ openPRs: [PullRequest], _ allBranches: [Branch]) -> [Remote] {
    let prRemoteUrls = openPRs.compactMap(\.head.gitHubRepository.cloneURL).exactSet
    let branchRemotes = allBranches.compactMap(\.upstreamRemoteName).exactSet

    return remotes.filter { remote in
        isForkedRemoteName(remote.name)
            && !prRemoteUrls.contains(ExactString(remote.url))
            && !branchRemotes.contains(ExactString(remote.name))
    }
}

extension SyncModel {
    /// Forks the repository on GitHub under the signed-in account and makes
    /// the fork the repository's default remote ("Fork This Repository", the
    /// recovery for pushing without write access). See `convertToFork(_:)`.
    ///
    /// - Throws: `.precondition` without a GitHub repository or an account
    ///   for it; `.api` with "Creating your fork <login>/<name> failed." and
    ///   the error; `convertToFork`'s errors.
    public func createFork() async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw notInList(.convertToFork)
        }
        guard let gitHubRepository = repository.record.gitHubRepository else {
            throw precondition("Only repositories on GitHub can be forked.", .convertToFork)
        }
        guard let account = app.accounts.account(for: repository.record) else {
            throw precondition("Sign in to \(getHTMLURL(gitHubRepository.endpoint)) to fork this repository.", .convertToFork)
        }

        let api = API.fromAccount(account, runtime: repository.environment.gitHub)
        let fork: APIFullRepository
        do {
            fork = try await api.forkRepository(owner: gitHubRepository.owner.login, name: gitHubRepository.name)
        } catch {
            logger.error("Fork creation through API failed: \(String(describing: error), privacy: .private)")
            let failure = apiFailure(from: error)
            throw OperationError(
                .api(APIFailure(
                    message: "Creating your fork \(account.login)/\(gitHubRepository.name) failed. \(failure.message)",
                    status: failure.status
                )),
                operation: .convertToFork,
                repositoryID: repository.id,
                underlying: error
            )
        }
        try await convertToFork(fork)
    }

    /// Makes `fork` the repository's default remote and GitHub repository:
    /// the default remote's URL becomes the fork's clone URL, the `upstream`
    /// remote points at the old URL (added, or updated when it exists), and
    /// the repository is associated with the fork. Returns after the refresh.
    ///
    /// Nothing happens without a remote. GitHub creates forks
    /// asynchronously; nothing waits for it.
    public func convertToFork(_ fork: APIFullRepository) async throws(OperationError) {
        guard let repository else {
            throw notInList(.convertToFork)
        }
        guard let gitHubRepository = repository.record.gitHubRepository else {
            throw precondition("Only repositories on GitHub can be forked.", .convertToFork)
        }
        let endpoint = gitHubRepository.endpoint

        let descriptor = OperationDescriptor(kind: .convertToFork, lanes: [.network], refreshAfter: .full)
        let converted = try await repository.perform(descriptor) { ctx -> Bool in
            // make sure there is a default remote (there should be)
            let remotes = try await getRemotes(ctx.repository)
            guard let defaultRemote = findDefaultRemote(remotes) else {
                return false
            }
            // update default remote
            try await GitKit.setRemoteURL(ctx.repository, defaultRemote.name, fork.cloneURL)
            try await ensureUpstreamRemoteURL(ctx.repository, defaultRemote.url)
            return true
        }
        guard converted else {
            return
        }
        // update associated github repo
        associate(fork, endpoint: endpoint)
        await repository.awaitOperationRefresh(covering: .full)
    }

    /// Removes the fork remotes nothing uses any more; it runs whenever the
    /// open pull requests are loaded. Background work: skipped behind another
    /// network operation, failures only logged.
    func pruneForkedRemotes(openPullRequests: [PullRequest]) async {
        guard let repository else {
            return
        }
        let branches = repository.gitState.branches.all
        let descriptor = OperationDescriptor(kind: .setRemoteURL, lanes: [.network], policy: .background, refreshAfter: [])
        do {
            let removed = try await repository.performIfIdle(descriptor) { ctx -> Int in
                let remotes = try await getRemotes(ctx.repository)
                let remotesToPrune = findForkedRemotesToPrune(remotes, openPullRequests, branches)
                for remote in remotesToPrune {
                    try await removeRemote(ctx.repository, remote.name)
                }
                return remotesToPrune.count
            }
            if let removed, removed > 0 {
                repository.requestRefresh([.remotes, .refs], reason: .operation(.setRemoteURL))
            }
        } catch {
            SyncModel.logFailure("Pruning fork remotes failed", error)
        }
    }

    /// Stores `apiRepository` and its parent in the GitHub repository table
    /// and associates the repository with it. Records associated with the
    /// rows it touched get the new data too.
    func associate(_ apiRepository: APIFullRepository, endpoint: String) {
        guard let repository, let app = repository.app else {
            return
        }
        let associated = app.upsertGitHubRepository(endpoint, apiRepository)
        app.setGitHubRepository(associated, for: repository.id)
    }
}

/// Sets the `upstream` remote's URL, adding the remote when there's none.
private func ensureUpstreamRemoteURL(_ repository: Repository, _ remoteURL: String) async throws {
    do {
        try await addRemote(repository, upstreamRemoteName, remoteURL)
    } catch let error as GitError where error.result.gitError == .remoteAlreadyExists {
        // update upstream remote if it already exists
        try await GitKit.setRemoteURL(repository, upstreamRemoteName, remoteURL)
    }
}
