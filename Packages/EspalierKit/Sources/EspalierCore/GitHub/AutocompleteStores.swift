// Ported from desktop/app/src/lib/stores/issues-store.ts and github-user-store.ts
//
// Issues and mentionable users are kept in memory and in rebuildable cache
// files (GitHubCaches.swift).

import EspalierSupport
import Foundation
import GitHubKit
import os

private let logger = Log.logger(category: "autocomplete")

/// How many hits autocompletion shows.
public let defaultMaxHits = 25

/// An autocompletion hit for an issue.
public struct IssueHit: Sendable, Hashable {
    /// The title of the issue.
    public let title: String
    /// The issue's number.
    public let number: Int

    public init(title: String, number: Int) {
        self.title = title
        self.number = number
    }
}

/// A user who can be mentioned in the repository, or a co-author.
public struct MentionableUser: Codable, Sendable, Hashable {
    /// The username or "handle" of the user.
    public let login: String
    /// The user's real name, or nil when they haven't set one.
    public let name: String?
    /// The user's attributable email address: their public one, else
    /// GitHub's stealth address for them.
    public let email: String
    /// A url to an avatar image chosen by the user.
    public let avatarURL: String

    public init(login: String, name: String?, email: String, avatarURL: String) {
        self.login = login
        self.name = name
        self.email = email
        self.avatarURL = avatarURL
    }
}

// MARK: Matching

/// Filter and rank a set of mentionable users by how well they match the
/// given query.
///
/// A user is considered a hit if the query appears as a substring of their
/// login or, when set, their real name. Hits are ordered primarily by how
/// early in the text the match was found and secondarily by login
/// (alphabetically, ignoring case).
///
/// - Parameters:
///   - users: The mentionable users to filter and rank.
///   - query: The text to search for. A user is a hit if this matches any
///     substring of their login or real name.
///   - maxHits: The maximum number of hits to return.
public func matchMentionableUsers(_ users: [MentionableUser], _ query: String, maxHits: Int = defaultMaxHits) -> [MentionableUser] {
    let needle = JSCompat.toLowerCase(query)
    var hits: [(user: MentionableUser, ix: Int, order: Int)] = []

    // Simple substring comparison on login and real name
    for (order, user) in users.enumerated() {
        // Users without a configured real name have a nil name. Coalesce to
        // an empty string, so queries like "@null" (or even "@n") don't match
        // every user that hasn't set a name.
        let haystack = JSCompat.toLowerCase(JSCompat.trim("\(user.login) \(user.name ?? "")"))
        if let ix = utf16IndexOf(haystack, needle) {
            hits.append((user, ix, order))
        }
    }

    // Sort hits primarily based on how early in the text the match
    // was found and then secondarily using alphabetic order.
    return hits
        .sorted { x, y in
            if x.ix != y.ix {
                return x.ix < y.ix
            }
            let byLogin = JSCompat.caseInsensitiveCompare(x.user.login, y.user.login)
            return byLogin != 0 ? byLogin < 0 : x.order < y.order
        }
        .prefix(maxHits)
        .map(\.user)
}

/// Issues whose number or title contains `text`: with no text, the highest
/// numbers first; otherwise by how early the match is in "<number> <title>",
/// then by title.
func matchIssues(_ issues: [IssueHit], _ text: String, maxHits: Int = defaultMaxHits) -> [IssueHit] {
    if text.isEmpty {
        return Array(issues.sorted { $0.number > $1.number }.prefix(maxHits))
    }

    let needle = JSCompat.toLowerCase(text)
    var hits: [(hit: IssueHit, ix: Int, order: Int)] = []
    for (order, issue) in issues.enumerated() {
        let haystack = JSCompat.toLowerCase(JSCompat.trim("\(issue.number) \(issue.title)"))
        if let ix = utf16IndexOf(haystack, needle) {
            hits.append((issue, ix, order))
        }
    }

    // Sort hits primarily based on how early in the text the match
    // was found and then secondarily using alphabetic order.
    return hits
        .sorted { x, y in
            if x.ix != y.ix {
                return x.ix < y.ix
            }
            let byTitle = JSCompat.compare(x.hit.title, y.hit.title)
            return byTitle != 0 ? byTitle < 0 : x.order < y.order
        }
        .prefix(maxHits)
        .map(\.hit)
}

/// JavaScript's `haystack.indexOf(needle)`: the UTF-16 offset of the first
/// occurrence, comparing code units; nil for -1.
func utf16IndexOf(_ haystack: String, _ needle: String) -> Int? {
    let haystack = Array(haystack.utf16)
    let needle = Array(needle.utf16)
    guard !needle.isEmpty else {
        return 0
    }
    guard haystack.count >= needle.count else {
        return nil
    }
    for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
        if haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return start
        }
    }
    return nil
}

// MARK: Issues

/// An open issue as the cache keeps it.
struct CachedIssue: Codable, Sendable, Equatable {
    var number: Int
    var title: String
    var updatedAt: String
}

/// The cache file of a GitHub repository's open issues.
struct IssuesCacheFile: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var repository: CachedRepositoryIdentity
    var issues: [CachedIssue]
}

/// The open issues of the repository's GitHub repository (the parent a fork
/// contributes to), for `#` autocompletion.
///
/// The first refresh loads the open issues; later ones load those updated
/// since the latest one stored, dropping the closed ones.
@MainActor
public final class IssuesStore {
    /// The time a `#` typed waits before refreshing again.
    static let refreshThrottleInterval: TimeInterval = 60

    private weak var model: RepositoryGitHubModel?
    private var repositoryID: Int?
    private var issues: [Int: CachedIssue] = [:]
    private var loading: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?
    private var lastRequestedRefresh: Date?

    init(model: RepositoryGitHubModel) {
        self.model = model
    }

    /// Issues whose number or title contains `text`: with no text, the
    /// highest numbers first; otherwise by how early the match is in
    /// "<number> <title>", then by title.
    public func issues(matching text: String, maxHits: Int = defaultMaxHits) async -> [IssueHit] {
        guard let gitHubRepository = gitHubRepository else {
            return []
        }
        await load(gitHubRepository)
        let hits = issues.values.map { IssueHit(title: $0.title, number: $0.number) }
        return matchIssues(hits, text, maxHits: maxHits)
    }

    /// Refreshes the issues, at most once a minute: for `#` being typed.
    public func requestRefresh() {
        guard let model, let now = model.repository?.environment.scheduler.now else {
            return
        }
        if let last = lastRequestedRefresh, now.timeIntervalSince(last) < Self.refreshThrottleInterval {
            return
        }
        lastRequestedRefresh = now
        model.startTracked { [weak self] in
            await self?.refresh()
        }
    }

    /// Refreshes the open issues from GitHub. Nothing happens without an
    /// account; failures are logged. One refresh runs at a time.
    public func refresh() async {
        if let refreshing {
            await refreshing.value
            return
        }
        let task = Task { @MainActor in
            await self.refreshIssues()
        }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private var gitHubRepository: GitHubRepository? {
        model?.repository.flatMap { getNonForkGitHubRepository($0.record) }
    }

    private func refreshIssues() async {
        guard let model, let repository = model.repository, let app = repository.app,
              let gitHubRepository = getNonForkGitHubRepository(repository.record),
              let account = app.accounts.account(forEndpoint: gitHubRepository.endpoint)
        else {
            return
        }
        await load(gitHubRepository)

        // If we don't have a lastUpdatedAt that mean we haven't fetched any
        // issues for the repository yet which in turn means we only have to
        // fetch the currently open issues. If we have fetched before we get
        // all issues that have been modified since the last time we fetched
        // so that we can prune closed issues from our database. Note that
        // since the GitHub API returns all issues modified _at_ or after the
        // timestamp we give it we will always get at least one issue back.
        let lastUpdatedAt = issues.values
            .compactMap { parseGitHubTimestamp($0.updatedAt) }
            .max()
        let api = API.fromAccount(account, runtime: repository.environment.gitHub)
        let fetched: [APIIssue]
        do {
            fetched = try await api.fetchIssues(
                owner: gitHubRepository.owner.login,
                name: gitHubRepository.name,
                state: lastUpdatedAt == nil ? .open : .all,
                since: lastUpdatedAt
            )
        } catch {
            logger.warning("Unable to fetch issues for \(gitHubRepository.fullName, privacy: .private): \(String(describing: error), privacy: .public)")
            return
        }
        // The repository may have been reassociated meanwhile.
        guard repositoryID == gitHubRepository.dbID else {
            return
        }
        await store(fetched, for: gitHubRepository)
    }

    private func store(_ fetched: [APIIssue], for gitHubRepository: GitHubRepository) async {
        var stored = issues
        for issue in fetched {
            if issue.state == .closed {
                stored[issue.number] = nil
            } else if issue.state == .open {
                stored[issue.number] = CachedIssue(number: issue.number, title: issue.title, updatedAt: issue.updatedAt)
            }
        }
        guard stored != issues else {
            return
        }
        issues = stored

        let file = IssuesCacheFile(
            version: IssuesCacheFile.currentVersion,
            repository: identity(of: gitHubRepository),
            issues: stored.values.sorted { $0.number < $1.number }
        )
        if let directories = model?.repository?.environment.directories {
            await writeCache(file, kind: .issues, for: gitHubRepository, in: directories)
        }
    }

    /// Loads the cache file once per GitHub repository.
    private func load(_ gitHubRepository: GitHubRepository) async {
        if repositoryID == gitHubRepository.dbID {
            await loading?.value
            return
        }
        repositoryID = gitHubRepository.dbID
        issues = [:]
        guard let environment = model?.repository?.environment else {
            return
        }
        let url = GitHubCacheKind.issues.url(in: environment.directories, gitHubRepositoryID: gitHubRepository.dbID)
        let identity = identity(of: gitHubRepository)
        let task = Task { @MainActor in
            let file = await GitHubCacheFiles.shared.read(url, as: IssuesCacheFile.self)
            guard self.repositoryID == gitHubRepository.dbID, self.issues.isEmpty,
                  let file, file.version == IssuesCacheFile.currentVersion,
                  file.repository.matches(endpoint: identity.endpoint, owner: identity.owner, name: identity.name)
            else {
                return
            }
            for issue in file.issues {
                self.issues[issue.number] = issue
            }
        }
        loading = task
        await task.value
    }
}

// MARK: Mentionable users

/// The cache file of a GitHub repository's mentionable users.
struct MentionablesCacheFile: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var repository: CachedRepositoryIdentity
    /// When the users were last asked for.
    var lastUpdated: Date
    var eTag: String?
    var users: [MentionableUser]
}

/// The users who can be mentioned in the repository's GitHub repository
/// (the parent a fork contributes to), for `@` autocompletion and
/// co-authors, and users looked up by login.
@MainActor
public final class GitHubUserStore {
    /// Don't fetch mentionables more often than every 10 minutes.
    static let maxFetchFrequency: TimeInterval = 10 * 60

    private weak var model: RepositoryGitHubModel?
    private var repositoryID: Int?
    private var cache: MentionablesCacheFile?
    private var loading: Task<Void, Never>?
    private var updating: Task<Void, Never>?

    init(model: RepositoryGitHubModel) {
        self.model = model
    }

    /// Retrieve a public user profile from the API based on the user login:
    /// their public email, else GitHub's stealth address for them. Nil for an
    /// unknown login, a login that isn't a user (an organization, a bot), or
    /// without an account.
    public func user(byLogin login: String) async -> MentionableUser? {
        guard let model, let repository = model.repository, let app = repository.app,
              let gitHubRepository = getNonForkGitHubRepository(repository.record),
              let account = app.accounts.account(forEndpoint: gitHubRepository.endpoint)
        else {
            return nil
        }
        let api = API.fromAccount(account, runtime: repository.environment.gitHub)
        guard let apiUser = (try? await api.fetchUser(login: login)) ?? nil, apiUser.type == .user else {
            return nil
        }

        let email: String
        if let publicEmail = apiUser.email, !publicEmail.isEmpty {
            email = publicEmail
        } else {
            email = getStealthEmailForUser(apiUser.id, login, account.endpoint)
        }

        return MentionableUser(
            login: apiUser.login,
            name: apiUser.name.flatMap { $0.isEmpty ? nil : $0 } ?? apiUser.login,
            email: email,
            avatarURL: apiUser.avatarURL
        )
    }

    /// The mentionable users who match `query`, ranked by how early it
    /// matches in "<login> <name>", then by login.
    public func mentionableUsers(matching query: String, maxHits: Int = defaultMaxHits) async -> [MentionableUser] {
        matchMentionableUsers(await mentionableUsers(), query, maxHits: maxHits)
    }

    /// The mentionable users in the repository; on GitHub.com, with the
    /// Copilot coding agent.
    public func mentionableUsers() async -> [MentionableUser] {
        guard let gitHubRepository = gitHubRepository else {
            return []
        }
        await load(gitHubRepository)
        let mentionables = cache?.users ?? []
        if isDotCom(gitHubRepository.endpoint), !mentionables.contains(where: { $0.login == "Copilot" }) {
            let bot = copilotSweAgentBot
            let email = getStealthEmailForUser(bot.userId, bot.login, bot.endpoint)
            return mentionables + [MentionableUser(login: bot.login, name: bot.login, email: email, avatarURL: bot.avatarURL)]
        }
        return mentionables
    }

    /// Updates the mentionable users, at most every 10 minutes, asking
    /// GitHub only for changes since the last answer (its ETag). Nothing
    /// happens without an account.
    public func updateMentionables() async {
        if let updating {
            await updating.value
            return
        }
        let task = Task { @MainActor in
            await self.update()
        }
        updating = task
        await task.value
        updating = nil
    }

    private var gitHubRepository: GitHubRepository? {
        model?.repository.flatMap { getNonForkGitHubRepository($0.record) }
    }

    private func update() async {
        guard let model, let repository = model.repository, let app = repository.app,
              let gitHubRepository = getNonForkGitHubRepository(repository.record),
              let account = app.accounts.account(forEndpoint: gitHubRepository.endpoint)
        else {
            return
        }
        await load(gitHubRepository)
        let now = repository.environment.scheduler.now
        if let cache, now.timeIntervalSince(cache.lastUpdated) < Self.maxFetchFrequency {
            return
        }

        let api = API.fromAccount(account, runtime: repository.environment.gitHub)
        let response = await api.fetchMentionables(owner: gitHubRepository.owner.login, name: gitHubRepository.name, etag: cache?.eTag)
        guard repositoryID == gitHubRepository.dbID else {
            return
        }

        var updated = cache ?? MentionablesCacheFile(
            version: MentionablesCacheFile.currentVersion,
            repository: identity(of: gitHubRepository),
            lastUpdated: now,
            eTag: nil,
            users: []
        )
        updated.lastUpdated = now
        if let response {
            let endpoint = account.endpoint
            updated.users = response.users.map { user in
                let email = user.email.flatMap { $0.isEmpty ? nil : $0 } ?? getLegacyStealthEmailForUser(user.login, endpoint)
                return MentionableUser(login: user.login, name: user.name, email: email, avatarURL: user.avatarURL)
            }
            updated.eTag = response.etag
        }
        // 304, 404, or an error: only the date moves, the ETag stays.
        cache = updated
        await writeCache(updated, kind: .mentionables, for: gitHubRepository, in: repository.environment.directories)
    }

    /// Loads the cache file once per GitHub repository.
    private func load(_ gitHubRepository: GitHubRepository) async {
        if repositoryID == gitHubRepository.dbID {
            await loading?.value
            return
        }
        repositoryID = gitHubRepository.dbID
        cache = nil
        guard let environment = model?.repository?.environment else {
            return
        }
        let url = GitHubCacheKind.mentionables.url(in: environment.directories, gitHubRepositoryID: gitHubRepository.dbID)
        let identity = identity(of: gitHubRepository)
        let task = Task { @MainActor in
            let file = await GitHubCacheFiles.shared.read(url, as: MentionablesCacheFile.self)
            guard self.repositoryID == gitHubRepository.dbID, self.cache == nil,
                  let file, file.version == MentionablesCacheFile.currentVersion,
                  file.repository.matches(endpoint: identity.endpoint, owner: identity.owner, name: identity.name)
            else {
                return
            }
            self.cache = file
        }
        loading = task
        await task.value
    }
}

// MARK: Helpers

private func identity(of repository: GitHubRepository) -> CachedRepositoryIdentity {
    CachedRepositoryIdentity(endpoint: repository.endpoint, owner: repository.owner.login, name: repository.name)
}

/// Writes a cache file, unless a later write got there first.
private func writeCache<File: Encodable & Sendable>(
    _ file: File,
    kind: GitHubCacheKind,
    for repository: GitHubRepository,
    in directories: AppDirectories
) async {
    let url = kind.url(in: directories, gitHubRepositoryID: repository.dbID)
    let revision = GitHubCacheFiles.nextRevision()
    await GitHubCacheFiles.shared.write(file, to: url, revision: revision)
}
