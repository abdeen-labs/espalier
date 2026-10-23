// Ported from desktop/app/src/lib/stores/pull-request-store.ts and pull-request-coordinator.ts
//
// Pull requests are kept in memory and in a rebuildable cache file per
// GitHub repository (GitHubCaches.swift).

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "pull-requests")

/// A pull request as the cache keeps it, with the head and base
/// repositories as the API described them.
struct CachedPullRequest: Codable, Sendable, Equatable {
    struct Ref: Codable, Sendable, Equatable {
        var ref: String
        var sha: String
        var repository: APIRepository
    }

    var number: Int
    var title: String
    var createdAt: String
    var updatedAt: String
    var head: Ref
    var base: Ref
    var body: String
    var author: String
    /// The author's avatar URL; nil when the API gave none, and in a cache
    /// written before it was kept, until the pull request is fetched again.
    var authorAvatarURL: String?
    var draft: Bool
}

/// The cache file of a GitHub repository's open pull requests.
struct PullRequestCacheFile: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var repository: CachedRepositoryIdentity
    /// The most recent `updated_at` of the pull requests fetched: later
    /// refreshes ask only for pull requests updated since. Nil until a fetch
    /// returned any.
    var lastUpdated: String?
    var pullRequests: [CachedPullRequest]
}

/// The open pull requests of every GitHub repository Espalier has asked
/// about, shared by the local repositories that contribute to it.
///
/// The first refresh of a repository loads its open pull requests; later
/// ones load only those updated since the last one seen (GitHub has no
/// `since` for pull requests, so they're sorted by update and paged until an
/// older one comes), store the open ones, and drop the closed ones. Over 320
/// updated pull requests, or an API error, fall back to loading the open
/// ones again. One refresh per GitHub repository runs at a time.
@MainActor
final class PullRequestStore {
    private struct Entry {
        let identity: CachedRepositoryIdentity
        /// By number.
        var records: [Int: CachedPullRequest] = [:]
        var lastUpdated: String?
        /// The models, newest (highest number) first.
        var pullRequests: [PullRequest] = []
    }

    private let environment: AppEnvironment
    private weak var app: AppModel?

    private var entries: [Int: Entry] = [:]
    private var loads: [Int: Task<Void, Never>] = [:]
    private var refreshes: [Int: Task<Void, Never>] = [:]
    private var writes: [Int: Task<Void, Never>] = [:]
    private var lastRefreshed: [Int: Date] = [:]

    init(environment: AppEnvironment, app: AppModel?) {
        self.environment = environment
        self.app = app
    }

    // MARK: Reading

    /// The open pull requests of `gitHubRepository` (a non-fork repository,
    /// or the parent a fork contributes to), newest first, without asking
    /// GitHub: what's in memory, else the cache file.
    func pullRequests(for gitHubRepository: GitHubRepository) async -> [PullRequest] {
        await ensureLoaded(gitHubRepository)
        return entries[gitHubRepository.dbID]?.pullRequests ?? []
    }

    /// When the repository's pull requests were last refreshed from GitHub
    /// in this session (in memory only).
    func lastRefresh(of gitHubRepository: GitHubRepository) -> Date? {
        lastRefreshed[gitHubRepository.dbID]
    }

    /// Whether a refresh of the repository's pull requests is running.
    func isRefreshing(_ gitHubRepository: GitHubRepository) -> Bool {
        refreshes[gitHubRepository.dbID] != nil
    }

    // MARK: Refreshing

    /// Loads the repository's pull requests from GitHub. A refresh already
    /// running for it is joined. Failures are logged; the pull requests stay as
    /// they were.
    func refresh(_ gitHubRepository: GitHubRepository, account: Account) async {
        let key = gitHubRepository.dbID
        if let running = refreshes[key] {
            await running.value
            return
        }

        lastRefreshed[key] = environment.scheduler.now
        let task = Task { @MainActor in
            self.setLoading(true, for: key)
            do {
                try await self.fetchAndStorePullRequests(gitHubRepository, account: account)
            } catch {
                logger.error("Error refreshing pull requests for '\(gitHubRepository.fullName, privacy: .private)': \(String(describing: error), privacy: .public)")
            }
            // The cache is written before the refresh counts as done.
            await self.writes[key]?.value
            self.refreshes[key] = nil
            self.setLoading(false, for: key)
        }
        refreshes[key] = task
        await task.value
    }

    /// Fetches pull requests from the API: all open pull requests if it's
    /// the first time fetching for this repository, or all updated pull
    /// requests if not.
    private func fetchAndStorePullRequests(_ repository: GitHubRepository, account: Account) async throws {
        await ensureLoaded(repository)
        let api = API.fromAccount(account, runtime: environment.gitHub)
        let owner = repository.owner.login
        let name = repository.name

        // If we don't have a lastUpdatedAt that mean we haven't fetched any
        // PRs for the repository yet which in turn means we only have to
        // fetch the currently open PRs. If we have fetched before we get all
        // PRs that have been modified since the last time we fetched so that
        // we can prune closed issues from our database. Note that since
        // `api.fetchUpdatedPullRequests` returns all issues modified _at_ or
        // after the timestamp we give it we will always get at least one
        // issue back. See `store` for details on how that's handled.
        guard let lastUpdatedAt = entries[repository.dbID]?.lastUpdated.flatMap(parseGitHubTimestamp) else {
            let open = try await api.fetchAllOpenPullRequests(owner: owner, name: name)
            store(open, for: repository, replacingAll: true)
            return
        }

        let updated: [APIPullRequest]
        do {
            updated = try await api.fetchUpdatedPullRequests(owner: owner, name: name, since: lastUpdatedAt)
        } catch let error where error is MaxResultsError || error is APIError {
            // If we fail to load updated pull requests either because
            // there's too many updated PRs since the last time we
            // fetched (and it's likely that it'll be much more
            // efficient to just load the open PRs) or it's because the
            // API told us we couldn't load PRs (rate limit or permissions
            // problems), we load just the open ones and replace what we
            // have with them.
            //
            // This scenario can happen for repositories that are
            // very active while simultaneously infrequently used
            // by the user. Think of a very active open source repository
            // where the user only visits once a year to make a contribution.
            // It's likely that there's at most a few hundred PRs open but
            // the number of merged PRs since the last time we fetched could
            // number in the thousands.
            //
            // They're replaced only once the open ones load, so a failure
            // leaves what we had.
            logger.info("Loading the open pull requests of '\(repository.fullName, privacy: .private)' again: \(String(describing: error), privacy: .public)")
            let open = try await api.fetchAllOpenPullRequests(owner: owner, name: name)
            store(open, for: repository, replacingAll: true)
            return
        }
        store(updated, for: repository, replacingAll: false)
    }

    /// Stores the open pull requests and drops the merged or closed ones. With
    /// `replacingAll`, the open pull requests replace everything stored.
    ///
    /// An empty list of open pull requests replaces what's stored too, so pull
    /// requests that are gone don't stay listed.
    private func store(_ pullRequestsFromAPI: [APIPullRequest], for repository: GitHubRepository, replacingAll: Bool) {
        let key = repository.dbID
        var entry = entries[key] ?? Entry(identity: identity(of: repository))

        guard let first = pullRequestsFromAPI.first else {
            guard replacingAll else {
                return
            }
            let changed = !entry.records.isEmpty || entry.lastUpdated != nil
            entry.records = [:]
            entry.lastUpdated = nil
            apply(entry, for: key, changed: changed)
            return
        }

        var mostRecentlyUpdated = first.updatedAt
        var toDelete: [Int] = []
        var toUpsert: [CachedPullRequest] = []

        for pr in pullRequestsFromAPI {
            // We can do this string comparison here rather than convert to date
            // because ISO8601 is lexicographically sortable
            if JSCompat.compare(pr.updatedAt, mostRecentlyUpdated) > 0 {
                mostRecentlyUpdated = pr.updatedAt
            }

            // We know the base repo isn't null since that's where we got the
            // PR from in the first place.
            guard let baseRepository = pr.base.repo else {
                logger.error("Pull request #\(pr.number, privacy: .public) has no base repository")
                continue
            }

            if pr.state == .closed {
                toDelete.append(pr.number)
                continue
            }

            // `pr.head.repo` represents the source of the pull request. It
            // might be a branch associated with the current repository, or a
            // fork of the current repository.
            //
            // In cases where the user has removed the fork of the repository
            // after opening a pull request, this can be `null`, and the app
            // will not store this pull request.
            guard let headRepository = pr.head.repo else {
                logger.debug("Unable to store pull request #\(pr.number, privacy: .public) as it has no head repository associated with it")
                toDelete.append(pr.number)
                continue
            }

            toUpsert.append(CachedPullRequest(
                number: pr.number,
                title: pr.title,
                createdAt: pr.createdAt,
                updatedAt: pr.updatedAt,
                head: CachedPullRequest.Ref(ref: pr.head.ref, sha: pr.head.sha, repository: headRepository),
                base: CachedPullRequest.Ref(ref: pr.base.ref, sha: pr.base.sha, repository: baseRepository),
                body: pr.body ?? "",
                author: pr.user?.login ?? "",
                authorAvatarURL: pr.user.flatMap { $0.avatarURL.isEmpty ? nil : $0.avatarURL },
                draft: pr.draft ?? false
            ))
        }

        // When loading only PRs that has changed since the last fetch
        // we get back all PRs modified _at_ or after the timestamp we give it
        // meaning we will always get at least one issue back but. This
        // check detect this particular condition and lets us avoid expensive
        // branch pruning and updates for a single PR that hasn't actually
        // been updated.
        if !replacingAll, toDelete.isEmpty, toUpsert.count == 1, entry.records[toUpsert[0].number] == toUpsert[0] {
            return
        }

        let previous = entry.records
        var records = replacingAll ? [:] : entry.records
        for number in toDelete {
            records[number] = nil
        }
        for pullRequest in toUpsert {
            records[pullRequest.number] = pullRequest
        }
        let changed = records != previous || entry.lastUpdated != mostRecentlyUpdated
        entry.records = records
        entry.lastUpdated = mostRecentlyUpdated
        apply(entry, for: key, changed: changed, updatingRows: true)
    }

    /// Takes the entry: rebuilds its models, writes the cache, and tells the
    /// repositories that use it, when it changed.
    private func apply(_ entry: Entry, for key: Int, changed: Bool, updatingRows: Bool = false) {
        var entry = entry
        guard changed || entries[key] == nil else {
            entries[key] = entry
            return
        }
        entry.pullRequests = models(entry.records, endpoint: entry.identity.endpoint, accountLogin: accountScope(of: key), updatingRows: updatingRows)
        entries[key] = entry
        write(entry, for: key)
        notifyRepositories(key, entry.pullRequests, fromGitHub: true)
    }

    // MARK: The cache file

    private func ensureLoaded(_ repository: GitHubRepository) async {
        let key = repository.dbID
        if entries[key] != nil {
            return
        }
        if let load = loads[key] {
            await load.value
            return
        }
        let url = GitHubCacheKind.pullRequests.url(in: environment.directories, gitHubRepositoryID: key)
        let identity = identity(of: repository)
        let load = Task { @MainActor in
            let file = await GitHubCacheFiles.shared.read(url, as: PullRequestCacheFile.self)
            self.loads[key] = nil
            // A refresh may have stored the pull requests meanwhile.
            guard self.entries[key] == nil else {
                return
            }
            var entry = Entry(identity: identity)
            if let file, file.version == PullRequestCacheFile.currentVersion,
               file.repository.matches(endpoint: identity.endpoint, owner: identity.owner, name: identity.name) {
                for pullRequest in file.pullRequests {
                    entry.records[pullRequest.number] = pullRequest
                }
                entry.lastUpdated = file.lastUpdated
                entry.pullRequests = self.models(entry.records, endpoint: identity.endpoint, accountLogin: self.accountScope(of: key), updatingRows: false)
            }
            self.entries[key] = entry
            if !entry.pullRequests.isEmpty {
                self.notifyRepositories(key, entry.pullRequests, fromGitHub: false)
            }
        }
        loads[key] = load
        await load.value
    }

    private func write(_ entry: Entry, for key: Int) {
        let url = GitHubCacheKind.pullRequests.url(in: environment.directories, gitHubRepositoryID: key)
        let file = PullRequestCacheFile(
            version: PullRequestCacheFile.currentVersion,
            repository: entry.identity,
            lastUpdated: entry.lastUpdated,
            pullRequests: entry.records.values.sorted { $0.number < $1.number }
        )
        let revision = GitHubCacheFiles.nextRevision()
        let previous = writes[key]
        let task = Task {
            await previous?.value
            await GitHubCacheFiles.shared.write(file, to: url, revision: revision)
        }
        writes[key] = task
    }

    private func identity(of repository: GitHubRepository) -> CachedRepositoryIdentity {
        CachedRepositoryIdentity(endpoint: repository.endpoint, owner: repository.owner.login, name: repository.name)
    }

    // MARK: Models

    /// The account a GitHub repository row's data belongs to: the pull
    /// requests' repositories are that account's rows.
    private func accountScope(of key: Int) -> String {
        app?.gitHubRepositories[key]?.accountLogin ?? ""
    }

    /// A pull request GitHub returned on its own (a link's, a
    /// notification's), as a model; nil without a base or head repository.
    /// Its repositories are the rows of the account of `context`, the
    /// repository it was asked about.
    func model(for apiPullRequest: APIPullRequest, in context: GitHubRepository) -> PullRequest? {
        let endpoint = context.endpoint
        guard let base = apiPullRequest.base.repo, let head = apiPullRequest.head.repo else {
            return nil
        }
        let record = CachedPullRequest(
            number: apiPullRequest.number,
            title: apiPullRequest.title,
            createdAt: apiPullRequest.createdAt,
            updatedAt: apiPullRequest.updatedAt,
            head: CachedPullRequest.Ref(ref: apiPullRequest.head.ref, sha: apiPullRequest.head.sha, repository: head),
            base: CachedPullRequest.Ref(ref: apiPullRequest.base.ref, sha: apiPullRequest.base.sha, repository: base),
            body: apiPullRequest.body ?? "",
            author: apiPullRequest.user?.login ?? "",
            authorAvatarURL: apiPullRequest.user.flatMap { $0.avatarURL.isEmpty ? nil : $0.avatarURL },
            draft: apiPullRequest.draft ?? false
        )
        return models([record.number: record], endpoint: endpoint, accountLogin: accountScope(of: context.dbID), updatingRows: false).first
    }

    /// The pull requests as models, newest first. Their repositories are
    /// the list's rows when it has them (updated from the API's data when
    /// `updatingRows`), else built from the API's data without a row: forks
    /// nobody added aren't put in the list's table (its document would drop
    /// them on save).
    private func models(_ records: [Int: CachedPullRequest], endpoint: String, accountLogin: String, updatingRows: Bool) -> [PullRequest] {
        var repositories: [String: GitHubRepository] = [:]
        func repository(_ apiRepository: APIRepository) -> GitHubRepository {
            if let known = repositories[apiRepository.cloneURL] {
                return known
            }
            let resolved = gitHubRepository(apiRepository, endpoint: endpoint, accountLogin: accountLogin, updatingRows: updatingRows)
            repositories[apiRepository.cloneURL] = resolved
            return resolved
        }

        return records.values.sorted { $0.number > $1.number }.map { record in
            PullRequest(
                created: parseGitHubTimestamp(record.createdAt) ?? Date(timeIntervalSince1970: 0),
                title: record.title,
                pullRequestNumber: record.number,
                head: PullRequestRef(ref: record.head.ref, sha: record.head.sha, gitHubRepository: repository(record.head.repository)),
                base: PullRequestRef(ref: record.base.ref, sha: record.base.sha, gitHubRepository: repository(record.base.repository)),
                author: record.author,
                authorAvatarURL: record.authorAvatarURL,
                draft: record.draft,
                body: record.body
            )
        }
    }

    /// The row of `accountLogin` for a pull request's repository, when the
    /// list has one (a fork's and its parent's are the same account's).
    private func gitHubRepository(_ apiRepository: APIRepository, endpoint: String, accountLogin: String, updatingRows: Bool) -> GitHubRepository {
        if let app, let row = app.gitHubRepositories.row(
            endpoint: endpoint,
            ownerLogin: apiRepository.owner.login,
            name: apiRepository.name,
            accountLogin: accountLogin
        ) {
            if updatingRows {
                return app.upsertGitHubRepositoryLight(endpoint, apiRepository, accountLogin: accountLogin)
            }
            if let repository = app.gitHubRepositories.gitHubRepository(withID: row.id) {
                return repository
            }
        }
        let owner = apiRepository.owner
        return GitHubRepository(
            name: apiRepository.name,
            owner: Owner(login: owner.login, endpoint: endpoint, id: owner.id, type: owner.type),
            dbID: 0,
            isPrivate: apiRepository.private,
            htmlURL: apiRepository.htmlURL,
            cloneURL: apiRepository.cloneURL,
            issuesEnabled: apiRepository.hasIssues,
            isArchived: apiRepository.archived
        )
    }

    // MARK: The repositories that use it

    /// Tells every repository whose pull requests come from GitHub
    /// repository `key`.
    private func notifyRepositories(_ key: Int, _ pullRequests: [PullRequest], fromGitHub: Bool) {
        for model in repositoriesUsing(key) {
            model.gitHub.pullRequestsDidChange(pullRequests, fromGitHub: fromGitHub)
        }
    }

    private func setLoading(_ loading: Bool, for key: Int) {
        for model in repositoriesUsing(key) {
            model.gitHub.setLoadingPullRequests(loading)
        }
    }

    private func repositoriesUsing(_ key: Int) -> [RepositoryModel] {
        guard let app else {
            return []
        }
        return app.models.values.filter { model in
            getNonForkGitHubRepository(model.record)?.dbID == key
        }
    }
}
