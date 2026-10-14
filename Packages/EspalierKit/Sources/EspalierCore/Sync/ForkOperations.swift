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
/// Fork remotes are the ones Espalier marked when it added them
/// (`markForkRemote`); a remote without the mark is the user's, whatever its
/// name.
///
/// - Parameters:
///   - remotes: All remotes available in the repository.
///   - forkRemoteNames: The remotes Espalier marked (`getForkRemoteNames`).
///   - openPRs: All open pull requests available in the repository.
///   - allBranches: All branches available in the repository.
public func findForkedRemotesToPrune(
    _ remotes: [Remote],
    forkRemoteNames: Set<ExactString>,
    _ openPRs: [PullRequest],
    _ allBranches: [Branch]
) -> [Remote] {
    let prRemoteUrls = openPRs.compactMap(\.head.gitHubRepository.cloneURL).exactSet
    let branchRemotes = allBranches.compactMap(\.upstreamRemoteName).exactSet

    return remotes.filter { remote in
        forkRemoteNames.contains(ExactString(remote.name))
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
    /// remote points at the old URL (added when there's none), and the
    /// repository is associated with the fork. Returns after the refresh.
    ///
    /// When the only remote is `upstream`, it's renamed to `origin`, which
    /// moves its branches' tracking to `origin`; then `upstream` is added at
    /// the old URL, and `origin` is pointed at the fork last. A failure after
    /// the rename leaves `origin` at the old URL, which converting again
    /// finishes; the error says the remote was renamed.
    ///
    /// An `upstream` remote that points elsewhere (neither at the old URL nor
    /// at the repository being forked) is left as it is and becomes
    /// `upstreamRemoteConflict`, which asks whether to point it at the fork's
    /// parent, unless the user chose to ignore it. Nothing happens without a
    /// remote. GitHub creates forks asynchronously; nothing waits for it.
    public func convertToFork(_ fork: APIFullRepository) async throws(OperationError) {
        guard let repository else {
            throw notInList(.convertToFork)
        }
        guard let gitHubRepository = repository.record.gitHubRepository else {
            throw precondition("Only repositories on GitHub can be forked.", .convertToFork)
        }
        let endpoint = gitHubRepository.endpoint

        let descriptor = OperationDescriptor(kind: .convertToFork, lanes: [.network], refreshAfter: .full)
        let progress = ForkConversionProgress()
        let conversion: ForkConversion
        do throws(OperationError) {
            conversion = try await repository.perform(descriptor) { ctx -> ForkConversion in
                // make sure there is a default remote (there should be)
                let remotes = try await getRemotes(ctx.repository)
                guard let defaultRemote = findDefaultRemote(remotes) else {
                    return .noRemote
                }
                // only `upstream`: make it `origin`, the fork, and add
                // `upstream` back at the old URL
                if remotes.count == 1, JSCompat.strictEquals(defaultRemote.name, upstreamRemoteName) {
                    try await renameRemote(ctx.repository, upstreamRemoteName, "origin")
                    progress.renamedUpstream = true
                    try await addRemote(ctx.repository, upstreamRemoteName, defaultRemote.url)
                    try await GitKit.setRemoteURL(ctx.repository, "origin", fork.cloneURL)
                    return .converted
                }
                // update default remote
                try await GitKit.setRemoteURL(ctx.repository, defaultRemote.name, fork.cloneURL)
                if let existing = remotes.first(where: { JSCompat.strictEquals($0.name, upstreamRemoteName) }),
                   !JSCompat.strictEquals(existing.name, defaultRemote.name) {
                    let pointsAtParent = JSCompat.strictEquals(existing.url, defaultRemote.url)
                        || repositoryMatchesRemote(gitHubRepository, remoteURL: existing.url)
                    return pointsAtParent ? .converted : .upstreamPointsElsewhere(existing)
                }
                try await ensureUpstreamRemoteURL(ctx.repository, defaultRemote.url)
                return .converted
            }
        } catch where progress.renamedUpstream && !error.isCancellation {
            throw OperationError(
                .other("The upstream remote is now named origin, but it still points at the original repository. Try forking again to finish. \(error.message)"),
                operation: .convertToFork,
                repositoryID: repository.id,
                underlying: error
            )
        }
        if case .noRemote = conversion {
            return
        }
        // update associated github repo
        associate(fork, endpoint: endpoint)
        if case .upstreamPointsElsewhere(let existing) = conversion {
            raiseUpstreamRemoteConflict(existing)
        }
        await repository.awaitOperationRefresh(covering: .full)
    }

    /// Asks about the `upstream` remote `existing`, which a fork conversion
    /// left pointing elsewhere (`upstreamRemoteConflict`), unless the user
    /// chose to ignore it or the fork's parent isn't known.
    private func raiseUpstreamRemoteConflict(_ existing: Remote) {
        guard let repository, !repository.record.ignoresExistingUpstreamRemote,
              let parent = repository.record.gitHubRepository?.parent
        else {
            return
        }
        upstreamRemoteConflict = UpstreamRemoteConflict(
            repositoryName: repository.record.name,
            parentFullName: parent.fullName,
            existingRemote: existing,
            expectedURL: parent.cloneURL ?? ""
        )
    }

    /// Removes the fork remotes Espalier added that nothing uses any more; it
    /// runs whenever the open pull requests are loaded. Background work: skipped behind another
    /// network operation, failures only logged.
    ///
    /// The remotes and branches are read from the repository as it prunes:
    /// a repository that shares the selected one's pull requests may never
    /// have loaded its branches, and branches made since the last refresh
    /// count.
    func pruneForkedRemotes(openPullRequests: [PullRequest]) async {
        guard let repository else {
            return
        }
        let descriptor = OperationDescriptor(kind: .setRemoteURL, lanes: [.network], policy: .background, refreshAfter: [])
        do {
            let removed = try await repository.performIfIdle(descriptor) { ctx -> Int in
                let remotes = try await getRemotes(ctx.repository)
                let forkRemoteNames = try await getForkRemoteNames(ctx.repository)
                let branches = try await getBranches(ctx.repository)
                let remotesToPrune = findForkedRemotesToPrune(remotes, forkRemoteNames: forkRemoteNames, openPullRequests, branches)
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

/// What converting to a fork did.
private enum ForkConversion: Sendable {
    /// Nothing: the repository has no remote.
    case noRemote
    /// Converted, with `upstream` pointing at the old URL or the repository
    /// forked.
    case converted
    /// Converted, leaving the `upstream` remote, which points elsewhere.
    case upstreamPointsElsewhere(Remote)
}

/// How far a fork conversion got, for its error.
@MainActor
private final class ForkConversionProgress {
    /// Whether the only remote, `upstream`, was renamed to `origin`.
    var renamedUpstream = false
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
