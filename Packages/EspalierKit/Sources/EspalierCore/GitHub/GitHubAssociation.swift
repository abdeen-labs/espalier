// The GitHub repositories live in the repository list document's table.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "github-association")

extension AppModel {
    /// Looks the repository up on GitHub and updates its association, then
    /// returns the record.
    ///
    /// The default remote's host picks the account (`matchGitHubRepository`).
    /// Without a match nothing changes: an association is never cleared. When
    /// the API can't be reached, the association stays, unless the repository
    /// had none or its endpoint changed: then a skeleton row (owner and name
    /// from the remote) is better than nothing. Otherwise the row is updated
    /// from the API, with the user's permissions and the fork's parent, and the
    /// default remote is pointed at the new clone URL when the repository was
    /// renamed or transferred (`updateRemoteUrl`).
    ///
    /// Returns nil when the repository is no longer in the list.
    @discardableResult
    func repositoryWithRefreshedGitHubRepository(_ id: RepositoryID) async -> RepositoryRecord? {
        var refreshed: RepositoryRecord?
        await accounts.track {
            refreshed = await self.refreshGitHubRepository(id)
        }
        return refreshed
    }

    /// Refreshes the repository's GitHub association, as after selecting it,
    /// then restarts the background services that depend on it.
    func refreshGitHubAssociation(_ id: RepositoryID) async {
        await repositoryWithRefreshedGitHubRepository(id)
        if case .repository(id) = selection {
            background.update()
        }
    }

    /// The record for a network operation (push, pull, fetch, and the
    /// others): refreshed first when no signed-in account matches its GitHub
    /// repository, because the association may be missing or out of date.
    @discardableResult
    func withRefreshedGitHubRepository(_ id: RepositoryID) async -> RepositoryRecord? {
        guard let record = record(id) else {
            return nil
        }
        if accounts.account(for: record) != nil {
            return record
        }
        return await repositoryWithRefreshedGitHubRepository(id)
    }

    /// After signing in or out: refreshes the selected repository's
    /// association, which updates its permissions.
    ///
    /// A repository without a GitHub repository is refreshed too, so one whose
    /// remote matches the account just signed in to is associated at once.
    func refreshSelectedRepositoryAfterAccountChange() async {
        guard case .repository(let id) = selection, let record = record(id), !record.isMissing else {
            return
        }
        await refreshGitHubAssociation(id)
    }

    // MARK: Matching

    /// Matches the repository's default remote with a signed-in account by
    /// host. The remotes are read fresh.
    func matchGitHubRepository(_ record: RepositoryRecord) async -> MatchedGitHubRepository? {
        let accounts = accounts.accounts
        guard !accounts.isEmpty, !record.isMissing, let remote = await defaultRemote(of: record) else {
            return nil
        }
        return GitHubKit.matchGitHubRepository(accounts, remote.url)
    }

    /// The repository's default remote, read from its configuration.
    func defaultRemote(of record: RepositoryRecord) async -> Remote? {
        do {
            let remotes = try await environment.withRuntimes {
                try await getRemotes(record.gitRepository)
            }
            return findDefaultRemote(remotes)
        } catch {
            logger.info("Could not read the remotes of \(record.path, privacy: .private): \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    // MARK: The association

    private func refreshGitHubRepository(_ id: RepositoryID) async -> RepositoryRecord? {
        guard let record = record(id) else {
            return nil
        }

        // Associations are never cleared, so we can bail early here.
        guard let match = await matchGitHubRepository(record) else {
            return self.record(id)
        }

        let account = match.account
        let endpoint = account.endpoint
        let gitHub = environment.gitHub
        let apiRepository = await environment.withRuntimes {
            await API.fromAccount(account, runtime: gitHub).fetchRepository(owner: match.owner, name: match.name)
        }

        // The repository may have been removed, or changed, meanwhile.
        guard let current = self.record(id) else {
            return nil
        }

        guard let apiRepository else {
            // If the request fails, we want to preserve the existing GitHub
            // repository info. But if we didn't have a GitHub repository
            // already or the endpoint changed, the skeleton repository is
            // better than nothing.
            if endpoint != current.gitHubRepository?.endpoint {
                setGitHubRepository(upsertGitHubRepositoryFromMatch(match), for: id)
            }
            return self.record(id)
        }

        if let previous = current.gitHubRepository {
            await updateRemoteUrl(id, previous, apiRepository.repository)
        }

        setGitHubRepository(upsertGitHubRepository(endpoint, apiRepository), for: id)
        await models[id]?.gitHub.refreshBranchProtection()
        return self.record(id)
    }

    /// Associates the repository with `gitHubRepository` (nothing is written
    /// when it's unchanged).
    func setGitHubRepository(_ gitHubRepository: GitHubRepository, for id: RepositoryID) {
        updateRecord(id) { $0.gitHubRepository = gitHubRepository }
    }

    // MARK: The GitHub repository table

    /// Inserts or updates the row for a repository the API returned, with
    /// its parent, and returns it with its parent chain.
    @discardableResult
    func upsertGitHubRepository(_ endpoint: String, _ apiRepository: APIFullRepository) -> GitHubRepository {
        upsert { table in
            Self.upsert(
                endpoint,
                apiRepository.repository,
                parent: apiRepository.parent,
                permissions: apiRepository.permissions,
                ignoreParent: false,
                into: &table
            )
        }
    }

    /// Inserts or updates the row for a repository from an API response
    /// that doesn't describe its parent (pull request heads and bases),
    /// keeping the parent it had.
    @discardableResult
    func upsertGitHubRepositoryLight(_ endpoint: String, _ apiRepository: APIRepository) -> GitHubRepository {
        upsert { table in
            Self.upsert(endpoint, apiRepository, parent: nil, permissions: nil, ignoreParent: true, into: &table)
        }
    }

    /// The row for a matched remote: the existing row for its owner and name,
    /// else a new skeleton row without URLs.
    func upsertGitHubRepositoryFromMatch(_ match: MatchedGitHubRepository) -> GitHubRepository {
        upsert { table in
            let endpoint = match.account.endpoint
            if let existing = table.row(endpoint: endpoint, ownerLogin: match.owner, name: match.name) {
                return existing.id
            }
            return table.insert(StoredGitHubRepository(
                id: 0,
                name: match.name,
                owner: StoredOwner(login: match.owner, endpoint: endpoint)
            ))
        }
    }

    /// Changes the table, rebuilds the records' GitHub repositories from it,
    /// and returns the repository with row `id`.
    private func upsert(_ change: (inout GitHubRepositoryTable) -> Int) -> GitHubRepository {
        var id = 0
        updateGitHubRepositories { id = change(&$0) }
        rebuildGitHubRepositories()
        guard let repository = gitHubRepositories.gitHubRepository(withID: id) else {
            preconditionFailure("The GitHub repository table lost row \(id)")
        }
        return repository
    }

    /// Updates every record's GitHub repository from the table, so a changed
    /// row (a fork's parent, say) reaches every repository that refers to
    /// it.
    func rebuildGitHubRepositories() {
        for record in repositories {
            guard let current = record.gitHubRepository,
                  let rebuilt = gitHubRepositories.gitHubRepository(withID: current.dbID),
                  rebuilt != current
            else {
                continue
            }
            updateRecord(record.id) { $0.gitHubRepository = rebuilt }
        }
    }

    /// Inserts or updates the row for `apiRepository` and returns its ID.
    ///
    /// - Parameters:
    ///   - parent: The repository's parent, upserted first, when the API
    ///     described it.
    ///   - permissions: The user's permissions, when the API sent them.
    ///   - ignoreParent: The API response can't tell whether the repository
    ///     has a parent: keep the one the row has.
    static func upsert(
        _ endpoint: String,
        _ apiRepository: APIRepository,
        parent: APIRepository?,
        permissions: APIRepositoryPermissions?,
        ignoreParent: Bool,
        into table: inout GitHubRepositoryTable
    ) -> Int {
        let parentID = parent.map {
            upsert(endpoint, $0, parent: nil, permissions: nil, ignoreParent: true, into: &table)
        }

        let owner = apiRepository.owner
        let existing = table.row(endpoint: endpoint, ownerLogin: owner.login, name: apiRepository.name)

        // If we can't resolve permissions for the current repository chances
        // are that it's because it's the parent repository of another
        // repository and we ended up here because the "actual" repository is
        // trying to upsert its parent. We don't want to overwrite the
        // permissions of the parent if we can help it, or updating the fork
        // would clear the parent's permissions and updating the parent would
        // reinstate them.
        let resolvedPermissions = getPermissionsString(permissions) ?? existing?.permissions

        // If we're told to ignore the parent we keep the existing parent:
        // the API data came from an endpoint that doesn't include it, and
        // going from having a parent to not having one is rare enough that
        // we assume the value we have is valid until we're certain it's not.
        let resolvedParentID = ignoreParent ? existing?.parentID : parentID

        let row = StoredGitHubRepository(
            id: existing?.id ?? 0,
            name: apiRepository.name,
            owner: StoredOwner(login: owner.login, endpoint: endpoint, id: owner.id, type: owner.type),
            isPrivate: apiRepository.private,
            htmlURL: apiRepository.htmlURL,
            cloneURL: apiRepository.cloneURL,
            parentID: resolvedParentID,
            issuesEnabled: apiRepository.hasIssues,
            isArchived: apiRepository.archived,
            permissions: resolvedPermissions,
            lastPruneDate: existing?.lastPruneDate
        )

        guard let existing else {
            return table.insert(row)
        }
        // Skip writing when nothing has changed since the last time we
        // stored the API info.
        if row != existing {
            table.update(row)
        }
        return existing.id
    }
}

/// The user's permission level from the API's permissions: nil when the
/// API sent none.
func getPermissionsString(_ permissions: APIRepositoryPermissions?) -> GitHubRepositoryPermission? {
    guard let permissions else {
        return nil
    }
    if permissions.admin {
        return .admin
    } else if permissions.push {
        return .write
    } else if permissions.pull {
        return .read
    } else {
        return nil
    }
}
