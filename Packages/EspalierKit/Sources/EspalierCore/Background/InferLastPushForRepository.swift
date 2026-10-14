// Ported from desktop/app/src/lib/infer-last-push-for-repository.ts
//
// The remotes are read fresh; the current branch comes from the
// repository's last status.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "repository-indicators")

extension AppModel {
    /// Use the GitHub API to find the last push date for a repository,
    /// favouring the current remote (if defined) or falling back to the
    /// detected GitHub remote if no tracking information set for the current
    /// branch.
    ///
    /// Returns nil if no date can be detected: the repository has no GitHub
    /// repository, no account is signed in to its server, or the API can't
    /// tell. A repository GitHub says was never pushed to counts as pushed
    /// at the epoch.
    ///
    /// The account asked about a remote's repository is the one for that
    /// remote's server.
    func inferLastPushForRepository(_ repository: RepositoryModel) async -> Date? {
        let record = repository.record
        let accounts = accounts.accounts
        guard let account = getAccountForRepository(accounts, record.gitHubRepository) else {
            return nil
        }

        let tip = repository.gitState.tip
        let gitRepository = record.gitRepository
        let gitHub = environment.gitHub
        return await environment.withRuntimes {
            if let currentRemote = await currentRemote(gitRepository, tip: tip),
               let matchedRepository = GitHubKit.matchGitHubRepository(accounts, currentRemote.url) {
                let api = API.fromAccount(matchedRepository.account, runtime: gitHub)
                if let repo = await api.fetchRepository(owner: matchedRepository.owner, name: matchedRepository.name) {
                    return pushedAtDate(repo.pushedAt)
                }
            }

            if let gitHubRepository = record.gitHubRepository {
                let api = API.fromAccount(account, runtime: gitHub)
                if let repo = await api.fetchRepository(owner: gitHubRepository.owner.login, name: gitHubRepository.name) {
                    return pushedAtDate(repo.pushedAt)
                }
            }

            return nil
        }
    }
}

/// The remote the current branch tracks, else the default remote.
private func currentRemote(_ repository: Repository, tip: Tip) async -> Remote? {
    let remotes: [Remote]
    do {
        remotes = try await getRemotes(repository)
    } catch {
        logger.error("Could not load the remotes: \(error.localizedDescription, privacy: .public)")
        return nil
    }
    let defaultRemote = findDefaultRemote(remotes)
    return tip.branch?.resolvingRemotes(remotes.map(\.name)).upstreamRemoteName.flatMap { name in
        remotes.first { JSCompat.strictEquals($0.name, name) }
    } ?? defaultRemote
}

/// GitHub's ISO 8601 `pushed_at` date. A repository never pushed to has
/// none, which counts as the epoch; a date that can't be read is never
/// later than a fetch.
private func pushedAtDate(_ pushedAt: String?) -> Date {
    guard let pushedAt else {
        return Date(timeIntervalSince1970: 0)
    }
    if let date = try? Date(pushedAt, strategy: .iso8601) {
        return date
    }
    if let date = try? Date(pushedAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
        return date
    }
    return .distantPast
}
