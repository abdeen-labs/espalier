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
    /// The default remote decides the endpoint. A remote on another endpoint
    /// than the association's clears it, with the account assignment (a
    /// repository's account belongs to its endpoint). A repository without
    /// an association whose remote is on GitHub.com, a ghe.com host, or a
    /// server an account is signed in to is associated with it without an
    /// account. Without a default remote, or with one that isn't a
    /// GitHub-style URL, the association stays as it is.
    ///
    /// Then the repository's assigned account, if it's signed in, asks the
    /// API about it; no other account is used. When the API can't be
    /// reached, the association stays, unless the endpoint changed: then a
    /// skeleton row (owner and name from the remote) is better than nothing.
    /// Otherwise the account's row is updated from the API, with its
    /// permissions and the fork's parent, and the default remote is pointed
    /// at the new clone URL when the repository was renamed or transferred
    /// (`updateRemoteUrl`). An answer for an account or GitHub repository the
    /// repository no longer has is dropped.
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
    /// others): refreshed first when its assigned account isn't signed in,
    /// because the association may be missing or out of date.
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
    /// association, which updates its permissions when its account signed
    /// in again. Signing in never assigns an account to a repository.
    func refreshSelectedRepositoryAfterAccountChange() async {
        guard case .repository(let id) = selection, let record = record(id), !record.isMissing else {
            return
        }
        await refreshGitHubAssociation(id)
    }

    // MARK: Matching

    /// Matches the repository's default remote with its assigned account,
    /// when it's signed in. The remotes are read fresh.
    func matchGitHubRepository(_ record: RepositoryRecord) async -> MatchedGitHubRepository? {
        guard !record.isMissing, let remote = await defaultRemote(of: record) else {
            return nil
        }
        return matchGitHubRepository(record, remote: remote)
    }

    /// Matches `remote` with the repository's assigned account, when it's
    /// signed in.
    private func matchGitHubRepository(_ record: RepositoryRecord, remote: Remote) -> MatchedGitHubRepository? {
        guard let account = accounts.account(for: record) else {
            return nil
        }
        return GitHubKit.matchGitHubRepository([account], remote.url)
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
        guard !record.isMissing, let remote = await defaultRemote(of: record) else {
            return self.record(id)
        }
        associateWithEndpoint(of: remote, id)

        guard let current = self.record(id), let match = matchGitHubRepository(current, remote: remote) else {
            return self.record(id)
        }

        let account = match.account
        let endpoint = account.endpoint
        let gitHub = environment.gitHub
        let apiRepository = await environment.withRuntimes {
            await API.fromAccount(account, runtime: gitHub).fetchRepository(owner: match.owner, name: match.name)
        }

        // The repository may have been removed, or given another account or
        // GitHub repository, meanwhile: this answer is for the old one.
        guard let latest = self.record(id) else {
            return nil
        }
        guard JSCompat.strictEquals(latest.accountLogin ?? "", current.accountLogin ?? ""),
              latest.gitHubRepository?.dbID == current.gitHubRepository?.dbID
        else {
            return latest
        }

        guard let apiRepository else {
            // If the request fails, we want to preserve the existing GitHub
            // repository info. But if we didn't have a GitHub repository
            // already or the endpoint changed, the skeleton repository is
            // better than nothing.
            if endpoint != latest.gitHubRepository?.endpoint {
                setGitHubRepository(upsertGitHubRepositoryFromMatch(match), for: id)
            }
            return self.record(id)
        }

        if let previous = latest.gitHubRepository {
            await updateRemoteUrl(id, previous, apiRepository.repository)
        }

        setGitHubRepository(upsertGitHubRepository(endpoint, apiRepository, accountLogin: account.login), for: id)
        await models[id]?.gitHub.refreshBranchProtection()
        return self.record(id)
    }

    /// Keeps the association on the default remote's endpoint: clears it
    /// (with the account) when the remote is on another endpoint, and
    /// associates a repository without one, without an account, when its
    /// remote is on a GitHub host Espalier knows. A remote that isn't a
    /// GitHub-style URL (a path, say) changes nothing.
    private func associateWithEndpoint(of remote: Remote, _ id: RepositoryID) {
        guard let record = record(id), let parsed = parseRemote(remote.url) else {
            return
        }
        // The current association first, so it survives its account being
        // signed out, then the signed-in accounts' endpoints.
        let known = accounts.accounts.map(\.endpoint)
        let candidates = (record.gitHubRepository.map { [$0.endpoint] } ?? []) + known
        let endpoint = getEndpointForRemote(parsed, candidates: candidates)
        if let associated = record.gitHubRepository?.endpoint, associated != endpoint {
            clearGitHubRepository(id)
        }
        guard let endpoint, self.record(id)?.gitHubRepository == nil,
              isDotCom(endpoint) || isGHE(endpoint) || known.contains(endpoint)
        else {
            return
        }
        let match = toAnonymousMatch(endpoint: endpoint, owner: parsed.owner, name: parsed.name)
        setGitHubRepository(upsertGitHubRepositoryFromMatch(match), for: id, accountLogin: nil)
    }

    /// Associates a repository without a GitHub repository with `endpoint`,
    /// Git asking credentials for it, when its default remote is on it: the
    /// first time a GitHub Enterprise Server without a signed-in account, or
    /// a remote added outside Espalier, is noticed. Returns the record as
    /// it is then.
    @discardableResult
    func associateRepository(_ id: RepositoryID, withEndpoint endpoint: String) async -> RepositoryRecord? {
        guard let record = record(id), record.gitHubRepository == nil, !record.isMissing,
              let remote = await defaultRemote(of: record),
              let parsed = parseRemote(remote.url),
              remoteMatchesEndpoint(parsed, endpoint),
              self.record(id)?.gitHubRepository == nil
        else {
            return self.record(id)
        }
        let match = toAnonymousMatch(endpoint: endpoint, owner: parsed.owner, name: parsed.name)
        setGitHubRepository(upsertGitHubRepositoryFromMatch(match), for: id, accountLogin: nil)
        return self.record(id)
    }

    /// Associates the repository with `gitHubRepository`, keeping its
    /// account unless the endpoint changes (then it has none), on that
    /// account's row of it (nothing is written when it's unchanged).
    func setGitHubRepository(_ gitHubRepository: GitHubRepository, for id: RepositoryID) {
        guard let record = record(id) else {
            return
        }
        let keepsEndpoint = record.gitHubRepository.map { JSCompat.caseInsensitiveEquals($0.endpoint, gitHubRepository.endpoint) } ?? true
        setGitHubRepository(gitHubRepository, for: id, accountLogin: keepsEndpoint ? record.accountLogin : nil)
    }

    /// Associates the repository with `gitHubRepository` and assigns it
    /// `accountLogin` (nil: none), on that account's row of it, made when it
    /// has none (`GitHubRepositoryTable.scopedRowID`). A GitHub repository
    /// the table doesn't have is associated as it is.
    func setGitHubRepository(_ gitHubRepository: GitHubRepository, for id: RepositoryID, accountLogin: String?) {
        var scopedID: Int?
        if gitHubRepositories[gitHubRepository.dbID] != nil {
            updateGitHubRepositories { table in
                scopedID = table.scopedRowID(for: gitHubRepository.dbID, accountLogin: accountLogin)
            }
        }
        let scoped = scopedID.flatMap(gitHubRepositories.gitHubRepository(withID:)) ?? gitHubRepository
        updateRecord(id) { record in
            record.gitHubRepository = scoped
            record.accountLogin = accountLogin
        }
    }

    /// Clears the repository's association and account.
    func clearGitHubRepository(_ id: RepositoryID) {
        updateRecord(id) { record in
            record.gitHubRepository = nil
            record.accountLogin = nil
        }
    }

    // MARK: The GitHub repository table

    /// Inserts or updates the row of `accountLogin` (the account that
    /// fetched it; empty for none) for a repository the API returned, with
    /// its parent, and returns it with its parent chain.
    @discardableResult
    func upsertGitHubRepository(_ endpoint: String, _ apiRepository: APIFullRepository, accountLogin: String = "") -> GitHubRepository {
        upsert { table in
            Self.upsert(
                endpoint,
                apiRepository.repository,
                parent: apiRepository.parent,
                permissions: apiRepository.permissions,
                ignoreParent: false,
                accountLogin: accountLogin,
                into: &table
            )
        }
    }

    /// Inserts or updates the row of `accountLogin` for a repository from an
    /// API response that doesn't describe its parent (pull request heads and
    /// bases), keeping the parent it had.
    @discardableResult
    func upsertGitHubRepositoryLight(_ endpoint: String, _ apiRepository: APIRepository, accountLogin: String = "") -> GitHubRepository {
        upsert { table in
            Self.upsert(endpoint, apiRepository, parent: nil, permissions: nil, ignoreParent: true, accountLogin: accountLogin, into: &table)
        }
    }

    /// The row for a matched remote, of the match's account: the existing
    /// row for its owner and name, else a new skeleton row without URLs.
    func upsertGitHubRepositoryFromMatch(_ match: MatchedGitHubRepository) -> GitHubRepository {
        upsert { table in
            let endpoint = match.account.endpoint
            let accountLogin = match.account.login
            if let existing = table.row(endpoint: endpoint, ownerLogin: match.owner, name: match.name, accountLogin: accountLogin) {
                return existing.id
            }
            return table.insert(StoredGitHubRepository(
                id: 0,
                name: match.name,
                owner: StoredOwner(login: match.owner, endpoint: endpoint),
                accountLogin: accountLogin
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

    /// Inserts or updates the row of `accountLogin` for `apiRepository` and
    /// returns its ID.
    ///
    /// - Parameters:
    ///   - parent: The repository's parent, upserted first (for the same
    ///     account), when the API described it.
    ///   - permissions: The user's permissions, when the API sent them.
    ///   - ignoreParent: The API response can't tell whether the repository
    ///     has a parent: keep the one the row has.
    static func upsert(
        _ endpoint: String,
        _ apiRepository: APIRepository,
        parent: APIRepository?,
        permissions: APIRepositoryPermissions?,
        ignoreParent: Bool,
        accountLogin: String,
        into table: inout GitHubRepositoryTable
    ) -> Int {
        let parentID = parent.map {
            upsert(endpoint, $0, parent: nil, permissions: nil, ignoreParent: true, accountLogin: accountLogin, into: &table)
        }

        let owner = apiRepository.owner
        let existing = table.row(endpoint: endpoint, ownerLogin: owner.login, name: apiRepository.name, accountLogin: accountLogin)

        // When the API sends no permissions for the repository chances are
        // it's the parent of another repository and we ended up here because
        // the "actual" repository is upserting its parent. We don't want to
        // overwrite the permissions of the parent if we can help it, or
        // updating the fork would clear the parent's permissions and updating
        // the parent would reinstate them. Permissions the API sent are the
        // account's now, even when they grant nothing.
        let resolvedPermissions = permissions != nil ? getPermissionsString(permissions) : existing?.permissions

        // If we're told to ignore the parent we keep the existing parent:
        // the API data came from an endpoint that doesn't include it, and
        // going from having a parent to not having one is rare enough that
        // we assume the value we have is valid until we're certain it's not.
        let resolvedParentID = ignoreParent ? existing?.parentID : parentID

        let row = StoredGitHubRepository(
            id: existing?.id ?? 0,
            name: apiRepository.name,
            owner: StoredOwner(login: owner.login, endpoint: endpoint, id: owner.id, type: owner.type),
            accountLogin: accountLogin,
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
/// API sent none, or they grant nothing.
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
