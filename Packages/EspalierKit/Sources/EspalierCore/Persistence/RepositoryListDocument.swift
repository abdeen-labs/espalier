import EspalierSupport
import Foundation
import GitHubKit

/// The repository list as it is saved: `repositories.json`.
///
/// ```json
/// {
///   "version": 1,
///   "selectedRepositoryID": "0F4C…",
///   "recentRepositoryIDs": ["…"],
///   "nextGitHubRepositoryID": 3,
///   "repositories": [{ "id": "0F4C…", "path": "/Users/me/src/app", … }],
///   "gitHubRepositories": [{ "id": 2, "name": "app", "owner": { … }, … }]
/// }
/// ```
///
/// Repositories are listed in the order they were added. GitHub
/// repositories are a table the repositories refer to by ID, so a fork and
/// its parent share one row.
public struct RepositoryListDocument: Codable, Sendable, Equatable {
    /// The schema version this build reads and writes. A file with a larger
    /// one comes from a newer Espalier and is never overwritten.
    public static let currentVersion = 1

    public var version: Int

    /// The repository selected when the app quit.
    public var selectedRepositoryID: RepositoryID?

    /// The recently selected repositories, most recent first.
    public var recentRepositoryIDs: [RepositoryID]

    /// The ID the next GitHub repository row gets. IDs are never reused,
    /// even after their rows are dropped.
    public var nextGitHubRepositoryID: Int

    public var repositories: [StoredRepository]
    public var gitHubRepositories: [StoredGitHubRepository]

    public init(
        version: Int = currentVersion,
        selectedRepositoryID: RepositoryID? = nil,
        recentRepositoryIDs: [RepositoryID] = [],
        nextGitHubRepositoryID: Int = 1,
        repositories: [StoredRepository] = [],
        gitHubRepositories: [StoredGitHubRepository] = []
    ) {
        self.version = version
        self.selectedRepositoryID = selectedRepositoryID
        self.recentRepositoryIDs = recentRepositoryIDs
        self.nextGitHubRepositoryID = nextGitHubRepositoryID
        self.repositories = repositories
        self.gitHubRepositories = gitHubRepositories
    }

    private enum CodingKeys: String, CodingKey {
        case version, selectedRepositoryID, recentRepositoryIDs, nextGitHubRepositoryID, repositories, gitHubRepositories
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        selectedRepositoryID = try container.decodeIfPresent(RepositoryID.self, forKey: .selectedRepositoryID)
        recentRepositoryIDs = try container.decodeIfPresent([RepositoryID].self, forKey: .recentRepositoryIDs) ?? []
        nextGitHubRepositoryID = try container.decodeIfPresent(Int.self, forKey: .nextGitHubRepositoryID) ?? 1
        repositories = try container.decodeIfPresent([StoredRepository].self, forKey: .repositories) ?? []
        gitHubRepositories = try container.decodeIfPresent([StoredGitHubRepository].self, forKey: .gitHubRepositories) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(selectedRepositoryID, forKey: .selectedRepositoryID)
        try container.encode(recentRepositoryIDs, forKey: .recentRepositoryIDs)
        try container.encode(nextGitHubRepositoryID, forKey: .nextGitHubRepositoryID)
        try container.encode(repositories, forKey: .repositories)
        try container.encode(gitHubRepositories, forKey: .gitHubRepositories)
    }
}

// MARK: - Rows

/// A repository as the document stores it. In memory it is a
/// `RepositoryRecord`.
public struct StoredRepository: Codable, Sendable, Hashable {
    public var id: RepositoryID
    public var path: String
    public var gitDir: String?
    public var mainWorktreePath: String?
    public var alias: String?
    public var missing: Bool
    /// The `StoredGitHubRepository.id` of the associated GitHub repository.
    public var gitHubRepositoryID: Int?
    public var workflowPreferences: WorkflowPreferences
    public var isTutorialRepository: Bool
    public var tagsToPush: [String]
    public var ignoreExistingUpstreamRemote: Bool
    /// The branches Espalier rewrote, by name, to their upstream's tip then
    /// (`RepositoryRecord.rewrittenBranches`).
    public var rewrittenBranches: [String: String]
    /// When the repository was added; nil only in documents not written by
    /// Espalier.
    public var addedAt: Date?
    /// The history's scope, once the user chose one. An unknown value (from
    /// a newer Espalier) reads as nil.
    public var historyScope: HistoryScope?

    public init(
        id: RepositoryID,
        path: String,
        gitDir: String? = nil,
        mainWorktreePath: String? = nil,
        alias: String? = nil,
        missing: Bool = false,
        gitHubRepositoryID: Int? = nil,
        workflowPreferences: WorkflowPreferences = WorkflowPreferences(),
        isTutorialRepository: Bool = false,
        tagsToPush: [String] = [],
        ignoreExistingUpstreamRemote: Bool = false,
        rewrittenBranches: [String: String] = [:],
        addedAt: Date? = nil,
        historyScope: HistoryScope? = nil
    ) {
        self.id = id
        self.path = path
        self.gitDir = gitDir
        self.mainWorktreePath = mainWorktreePath
        self.alias = alias
        self.missing = missing
        self.gitHubRepositoryID = gitHubRepositoryID
        self.workflowPreferences = workflowPreferences
        self.isTutorialRepository = isTutorialRepository
        self.tagsToPush = tagsToPush
        self.ignoreExistingUpstreamRemote = ignoreExistingUpstreamRemote
        self.rewrittenBranches = rewrittenBranches
        self.addedAt = addedAt
        self.historyScope = historyScope
    }

    /// The row for `record`.
    public init(_ record: RepositoryRecord) {
        self.init(
            id: record.id,
            path: record.path,
            gitDir: record.gitDir,
            mainWorktreePath: record.mainWorktreePath,
            alias: record.alias,
            missing: record.isMissing,
            gitHubRepositoryID: record.gitHubRepository?.dbID,
            workflowPreferences: record.workflowPreferences,
            isTutorialRepository: record.isTutorialRepository,
            tagsToPush: record.tagsToPush,
            ignoreExistingUpstreamRemote: record.ignoresExistingUpstreamRemote,
            rewrittenBranches: record.rewrittenBranches,
            addedAt: record.addedAt,
            historyScope: record.historyScope
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, gitDir, mainWorktreePath, alias, missing, gitHubRepositoryID, workflowPreferences
        case isTutorialRepository, tagsToPush, ignoreExistingUpstreamRemote, rewrittenBranches, addedAt, historyScope
    }

    /// Requires `id` and `path`; anything else missing or null takes its
    /// default. A value of the wrong type fails the row.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RepositoryID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        gitDir = try container.decodeIfPresent(String.self, forKey: .gitDir)
        mainWorktreePath = try container.decodeIfPresent(String.self, forKey: .mainWorktreePath)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        missing = try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false
        gitHubRepositoryID = try container.decodeIfPresent(Int.self, forKey: .gitHubRepositoryID)
        workflowPreferences = try container.decodeIfPresent(WorkflowPreferences.self, forKey: .workflowPreferences)
            ?? WorkflowPreferences()
        isTutorialRepository = try container.decodeIfPresent(Bool.self, forKey: .isTutorialRepository) ?? false
        tagsToPush = try container.decodeIfPresent([String].self, forKey: .tagsToPush) ?? []
        ignoreExistingUpstreamRemote = try container.decodeIfPresent(Bool.self, forKey: .ignoreExistingUpstreamRemote) ?? false
        rewrittenBranches = try container.decodeIfPresent([String: String].self, forKey: .rewrittenBranches) ?? [:]
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt)
        // A string this version doesn't know (a newer scope) isn't an error.
        historyScope = try container.decodeIfPresent(String.self, forKey: .historyScope).flatMap(HistoryScope.init(rawValue:))
    }

    /// Writes every key, with `null` for an absent value, so the file shows
    /// its whole shape.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(gitDir, forKey: .gitDir)
        try container.encode(mainWorktreePath, forKey: .mainWorktreePath)
        try container.encode(alias, forKey: .alias)
        try container.encode(missing, forKey: .missing)
        try container.encode(gitHubRepositoryID, forKey: .gitHubRepositoryID)
        try container.encode(workflowPreferences, forKey: .workflowPreferences)
        try container.encode(isTutorialRepository, forKey: .isTutorialRepository)
        try container.encode(tagsToPush, forKey: .tagsToPush)
        try container.encode(ignoreExistingUpstreamRemote, forKey: .ignoreExistingUpstreamRemote)
        try container.encode(rewrittenBranches, forKey: .rewrittenBranches)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(historyScope, forKey: .historyScope)
    }
}

/// A GitHub repository as the document stores it, with its owner inline.
/// In memory it is a `GitHubRepository`, rebuilt with its parent chain by
/// `GitHubRepositoryTable`.
public struct StoredGitHubRepository: Codable, Sendable, Hashable {
    /// Espalier's ID for the row: `GitHubRepository.dbID`.
    public var id: Int
    public var name: String
    public var owner: StoredOwner
    public var isPrivate: Bool?
    public var htmlURL: String?
    public var cloneURL: String?
    /// The row ID of the repository this one is a fork of.
    public var parentID: Int?
    public var issuesEnabled: Bool?
    public var isArchived: Bool?
    public var permissions: GitHubRepositoryPermission?
    /// The last time a prune was attempted on the repository.
    public var lastPruneDate: Date?

    public init(
        id: Int,
        name: String,
        owner: StoredOwner,
        isPrivate: Bool? = nil,
        htmlURL: String? = nil,
        cloneURL: String? = nil,
        parentID: Int? = nil,
        issuesEnabled: Bool? = nil,
        isArchived: Bool? = nil,
        permissions: GitHubRepositoryPermission? = nil,
        lastPruneDate: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.owner = owner
        self.isPrivate = isPrivate
        self.htmlURL = htmlURL
        self.cloneURL = cloneURL
        self.parentID = parentID
        self.issuesEnabled = issuesEnabled
        self.isArchived = isArchived
        self.permissions = permissions
        self.lastPruneDate = lastPruneDate
    }

    /// The row for `repository` (its `dbID` and its parent's), without its
    /// parent's own row.
    public init(_ repository: GitHubRepository, lastPruneDate: Date? = nil) {
        self.init(
            id: repository.dbID,
            name: repository.name,
            owner: StoredOwner(repository.owner),
            isPrivate: repository.isPrivate,
            htmlURL: repository.htmlURL,
            cloneURL: repository.cloneURL,
            parentID: repository.parent?.dbID,
            issuesEnabled: repository.issuesEnabled,
            isArchived: repository.isArchived,
            permissions: repository.permissions,
            lastPruneDate: lastPruneDate
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, owner, isPrivate, htmlURL, cloneURL, parentID, issuesEnabled, isArchived, permissions, lastPruneDate
    }

    /// Requires `id`, `name`, and `owner`; anything else missing or null is
    /// unknown. Permissions this version doesn't know are unknown too. A
    /// value of the wrong type fails the row.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        owner = try container.decode(StoredOwner.self, forKey: .owner)
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate)
        htmlURL = try container.decodeIfPresent(String.self, forKey: .htmlURL)
        cloneURL = try container.decodeIfPresent(String.self, forKey: .cloneURL)
        parentID = try container.decodeIfPresent(Int.self, forKey: .parentID)
        issuesEnabled = try container.decodeIfPresent(Bool.self, forKey: .issuesEnabled)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived)
        permissions = try container.decodeIfPresent(String.self, forKey: .permissions)
            .flatMap(GitHubRepositoryPermission.init(rawValue:))
        lastPruneDate = try container.decodeIfPresent(Date.self, forKey: .lastPruneDate)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(owner, forKey: .owner)
        try container.encode(isPrivate, forKey: .isPrivate)
        try container.encode(htmlURL, forKey: .htmlURL)
        try container.encode(cloneURL, forKey: .cloneURL)
        try container.encode(parentID, forKey: .parentID)
        try container.encode(issuesEnabled, forKey: .issuesEnabled)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(lastPruneDate, forKey: .lastPruneDate)
    }
}

/// A GitHub repository's owner as the document stores it, inline in each
/// row.
public struct StoredOwner: Codable, Sendable, Hashable {
    public var login: String
    /// The API endpoint, such as `https://api.github.com`.
    public var endpoint: String
    /// `Owner.id`, kept as given.
    public var id: Int?
    public var type: GitHubAccountType?

    public init(login: String, endpoint: String, id: Int? = nil, type: GitHubAccountType? = nil) {
        self.login = login
        self.endpoint = endpoint
        self.id = id
        self.type = type
    }

    public init(_ owner: Owner) {
        self.init(login: owner.login, endpoint: owner.endpoint, id: owner.id, type: owner.type)
    }

    /// The owner as GitHubKit models it.
    public var model: Owner {
        Owner(login: login, endpoint: endpoint, id: id, type: type)
    }

    private enum CodingKeys: String, CodingKey {
        case login, endpoint, id, type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        login = try container.decode(String.self, forKey: .login)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        type = try container.decodeIfPresent(GitHubAccountType.self, forKey: .type)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(login, forKey: .login)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
    }
}

// MARK: - GitHub repositories in memory

/// The GitHub repositories the repository list refers to, keyed by the IDs
/// Espalier assigns (`GitHubRepository.dbID`).
///
/// Rows are matched by owner and name: an owner is the same on an
/// endpoint whatever the case of its login (`getOwnerKey`), and the name
/// matches case-insensitively too, as GitHub does.
public struct GitHubRepositoryTable: Sendable, Equatable {
    /// The rows, by ID.
    public private(set) var rows: [Int: StoredGitHubRepository]

    /// The ID `insert(_:)` assigns next.
    public private(set) var nextID: Int

    /// A table of `rows`. `nextID` is raised above every row's ID if needed.
    public init(rows: [StoredGitHubRepository] = [], nextID: Int = 1) {
        var byID: [Int: StoredGitHubRepository] = [:]
        for row in rows where byID[row.id] == nil {
            byID[row.id] = row
        }
        self.rows = byID
        self.nextID = max(nextID, (byID.keys.max() ?? 0) + 1)
    }

    public subscript(id: Int) -> StoredGitHubRepository? {
        rows[id]
    }

    /// The row for the repository named `name` that `ownerLogin` owns on
    /// `endpoint`, ignoring case; the oldest row when several match.
    public func row(endpoint: String, ownerLogin: String, name: String) -> StoredGitHubRepository? {
        let ownerKey = getOwnerKey(endpoint, ownerLogin)
        return rows.values
            .filter { JSCompat.strictEquals(getOwnerKey($0.owner.endpoint, $0.owner.login), ownerKey) }
            .filter { JSCompat.caseInsensitiveEquals($0.name, name) }
            .min { $0.id < $1.id }
    }

    /// Adds `row` under a new ID (whatever `row.id` says) and returns the ID.
    @discardableResult
    public mutating func insert(_ row: StoredGitHubRepository) -> Int {
        var row = row
        row.id = nextID
        rows[row.id] = row
        nextID += 1
        return row.id
    }

    /// Replaces the row with `row.id`, or adds it under that ID.
    public mutating func update(_ row: StoredGitHubRepository) {
        rows[row.id] = row
        nextID = max(nextID, row.id + 1)
    }

    /// Removes the row with `id`. Rows that name it as their parent keep the
    /// ID and rebuild without the parent.
    public mutating func remove(id: Int) {
        rows[id] = nil
    }

    /// The repository with row `id`, with its parent chain. A parent chain
    /// that loops ends where it would repeat a row.
    public func gitHubRepository(withID id: Int) -> GitHubRepository? {
        var chain: [StoredGitHubRepository] = []
        var visited: Set<Int> = []
        var next: Int? = id
        while let current = next, visited.insert(current).inserted, let row = rows[current] {
            chain.append(row)
            next = row.parentID
        }

        var repository: GitHubRepository?
        for row in chain.reversed() {
            repository = GitHubRepository(
                name: row.name,
                owner: row.owner.model,
                dbID: row.id,
                isPrivate: row.isPrivate,
                htmlURL: row.htmlURL,
                cloneURL: row.cloneURL,
                issuesEnabled: row.issuesEnabled,
                isArchived: row.isArchived,
                permissions: row.permissions,
                parent: repository
            )
        }
        return repository
    }

    /// The rows `ids` name and their parents, transitively.
    public func reachableIDs(from ids: some Sequence<Int>) -> Set<Int> {
        var reachable: Set<Int> = []
        for id in ids {
            var next: Int? = id
            while let current = next, rows[current] != nil, reachable.insert(current).inserted {
                next = rows[current]?.parentID
            }
        }
        return reachable
    }

    /// Drops every row that `ids` don't reach, directly or as a parent.
    public mutating func removeRows(unreachableFrom ids: some Sequence<Int>) {
        let reachable = reachableIDs(from: ids)
        rows = rows.filter { reachable.contains($0.key) }
    }
}

/// Creates a case-insensitive key used to uniquely identify an owner based
/// on the endpoint and login. Note that the key happens to match the
/// canonical API url for the user.
func getOwnerKey(_ endpoint: String, _ login: String) -> String {
    JSCompat.toLowerCase("\(endpoint)/users/\(login)")
}

// MARK: - Between the document and the list

extension RepositoryListDocument {
    /// The document for a repository list.
    ///
    /// Keeps the GitHub repository rows the records refer to, directly or as
    /// a parent, and drops the rest; a record's GitHub repository that the
    /// table lacks is stored from the record. The selection and recent
    /// repositories keep only IDs in `records`.
    public init(
        records: [RepositoryRecord],
        gitHubRepositories: GitHubRepositoryTable,
        selectedRepositoryID: RepositoryID?,
        recentRepositoryIDs: [RepositoryID]
    ) {
        var table = gitHubRepositories
        for record in records {
            var next = record.gitHubRepository
            while let repository = next, table[repository.dbID] == nil {
                table.update(StoredGitHubRepository(repository))
                next = repository.parent
            }
        }
        table.removeRows(unreachableFrom: records.compactMap(\.gitHubRepository?.dbID))

        let ids = Set(records.map(\.id))
        var recents: [RepositoryID] = []
        for id in recentRepositoryIDs where ids.contains(id) && !recents.contains(id) {
            recents.append(id)
        }

        self.init(
            version: Self.currentVersion,
            selectedRepositoryID: selectedRepositoryID.flatMap { ids.contains($0) ? $0 : nil },
            recentRepositoryIDs: recents,
            nextGitHubRepositoryID: table.nextID,
            repositories: records.map(StoredRepository.init),
            gitHubRepositories: table.rows.values.sorted { $0.id < $1.id }
        )
    }

    /// The GitHub repository rows as a table.
    public var gitHubRepositoryTable: GitHubRepositoryTable {
        GitHubRepositoryTable(rows: gitHubRepositories, nextID: nextGitHubRepositoryID)
    }

    /// The repositories as records, in order, with their GitHub repositories
    /// resolved from the table.
    ///
    /// - Parameter fallbackAddedAt: The date for a repository the document
    ///   doesn't date.
    public func records(fallbackAddedAt: Date = Date()) -> [RepositoryRecord] {
        let table = gitHubRepositoryTable
        return repositories.map { stored in
            RepositoryRecord(
                id: stored.id,
                path: stored.path,
                gitDir: stored.gitDir,
                mainWorktreePath: stored.mainWorktreePath,
                alias: stored.alias,
                isMissing: stored.missing,
                gitHubRepository: stored.gitHubRepositoryID.flatMap(table.gitHubRepository(withID:)),
                workflowPreferences: stored.workflowPreferences,
                isTutorialRepository: stored.isTutorialRepository,
                tagsToPush: stored.tagsToPush,
                ignoresExistingUpstreamRemote: stored.ignoreExistingUpstreamRemote,
                rewrittenBranches: stored.rewrittenBranches,
                addedAt: stored.addedAt ?? fallbackAddedAt,
                historyScope: stored.historyScope
            )
        }
    }
}
