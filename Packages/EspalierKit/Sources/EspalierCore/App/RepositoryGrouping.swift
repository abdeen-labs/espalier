// Ported from desktop/app/src/ui/{repositories-list,clone-repository}/group-repositories.ts

import EspalierSupport
import Foundation
import GitHubKit
import GitKit

// MARK: - The repository list

/// A group of the repository list.
public enum RepositoryListGroup: Hashable, Sendable {
    /// The recently selected repositories, when there are more than seven.
    case recent
    /// GitHub.com repositories of one owner.
    case dotcom(owner: Owner)
    /// GitHub Enterprise repositories of one host (`host` includes a
    /// non-default port).
    case enterprise(host: String)
    /// Every other repository, and the clones in progress.
    case other
}

/// Returns a unique grouping key (string) for a repository group. Doubles as
/// a case sensitive sorting key (i.e the case sensitive sort order of the
/// keys is the order in which the groups will be displayed in the repository
/// list).
public func getGroupKey(_ group: RepositoryListGroup) -> String {
    switch group {
    case .recent: "0:recent"
    case .dotcom(let owner): "1:dotcom:\(owner.login)"
    case .enterprise(let host): "2:enterprise:\(host)"
    case .other: "3:other"
    }
}

/// A repository in the list, or a clone in progress.
public enum RepositoryListEntry: Equatable, Sendable, Identifiable {
    case repository(RepositoryRecord)
    case clone(CloneTask)

    public var id: RepositoryListEntryID {
        switch self {
        case .repository(let record): .repository(record.id)
        case .clone(let clone): .clone(clone.id)
        }
    }

    /// The name: a repository's GitHub name or folder name, a clone's URL
    /// without `.git`.
    public var name: String {
        switch self {
        case .repository(let record): record.name
        case .clone(let clone): POSIXPath.basename(clone.url, ".git")
        }
    }

    /// The display title: the alias (if available) or the name.
    public var displayTitle: String {
        switch self {
        case .repository(let record): record.alias ?? record.name
        case .clone: name
        }
    }
}

/// What a repository list item stands for.
public enum RepositoryListEntryID: Hashable, Sendable {
    case repository(RepositoryID)
    case clone(CloneID)
}

/// An item of the repository list.
public struct RepositoryListItem: Equatable, Sendable, Identifiable {
    /// What the filter matches: the display title, and for a repository its
    /// owner and name (`nameOf`).
    public let text: [String]
    public let id: RepositoryListEntryID
    public let repository: RepositoryListEntry
    /// Whether the title repeats where it would be ambiguous: within an
    /// Enterprise group, or, in the recent group, anywhere in the list. The
    /// UI shows the owner then.
    public let needsDisambiguation: Bool
    public let aheadBehind: AheadBehind?
    public let changedFilesCount: Int
}

/// One group of the repository list, its items sorted by title.
public struct RepositoryListGroupItems: Equatable, Sendable, Identifiable {
    public let identifier: RepositoryListGroup
    public let items: [RepositoryListItem]

    /// The group's key (`getGroupKey`).
    public var id: String {
        getGroupKey(identifier)
    }
}

/// The recent group shows only with more repositories than this.
let recentRepositoriesThreshold = 7

/// Groups the repository list: the recent group (with more than seven
/// entries; its repositories stay in their own groups too), then
/// GitHub.com repositories by owner, Enterprise repositories by host, and
/// the rest. Groups are in their keys' case-sensitive order; items in each
/// group sort by title, ignoring case.
///
/// - Parameters:
///   - repositories: The repositories, then the clones in progress.
///   - localRepositoryStateLookup: The indicators, for the badges.
///   - recentRepositories: The recently selected repositories.
public func groupRepositories(
    _ repositories: [RepositoryListEntry],
    _ localRepositoryStateLookup: [RepositoryID: RepositoryIndicator],
    _ recentRepositories: [RepositoryID]
) -> [RepositoryListGroupItems] {
    let includeRecentGroup = repositories.count > recentRepositoriesThreshold
    let recentSet = includeRecentGroup ? Set(recentRepositories) : nil

    var keys: [String] = []
    var groups: [String: (group: RepositoryListGroup, repositories: [RepositoryListEntry])] = [:]
    func addToGroup(_ group: RepositoryListGroup, _ repository: RepositoryListEntry) {
        let key = getGroupKey(group)
        if groups[key] == nil {
            keys.append(key)
            groups[key] = (group, [])
        }
        groups[key]?.repositories.append(repository)
    }

    for repository in repositories {
        if case .repository(let record) = repository, recentSet?.contains(record.id) == true {
            addToGroup(.recent, repository)
        }
        addToGroup(groupForRepository(repository), repository)
    }

    // Titles in every group but the recent one, whose repositories are by
    // definition in another group too.
    var allNames: [ExactString: Int] = [:]
    for key in keys {
        guard let group = groups[key], group.group != .recent else {
            continue
        }
        for repository in group.repositories {
            allNames[ExactString(repository.displayTitle), default: 0] += 1
        }
    }

    return keys
        .sorted { JSCompat.compare($0, $1) < 0 }
        .compactMap { key in
            groups[key].map { group in
                RepositoryListGroupItems(
                    identifier: group.group,
                    items: toSortedListItems(group.group, group.repositories, localRepositoryStateLookup, allNames: allNames)
                )
            }
        }
}

private func groupForRepository(_ repository: RepositoryListEntry) -> RepositoryListGroup {
    if case .repository(let record) = repository, let gitHubRepository = record.gitHubRepository {
        return isDotCom(gitHubRepository.endpoint)
            ? .dotcom(owner: gitHubRepository.owner)
            : .enterprise(host: hostForEndpoint(gitHubRepository.endpoint))
    }
    return .other
}

/// `new URL(getHTMLURL(endpoint)).host`: the host name, lowercased, with a
/// port that isn't the scheme's default.
private func hostForEndpoint(_ endpoint: String) -> String {
    let htmlURL = getHTMLURL(endpoint)
    guard let components = URLComponents(string: htmlURL), let host = components.host, !host.isEmpty else {
        return htmlURL
    }
    let hostname = host.lowercased()
    guard let port = components.port else {
        return hostname
    }
    let scheme = components.scheme?.lowercased()
    if scheme == "https" && port == 443 || scheme == "http" && port == 80 {
        return hostname
    }
    return "\(hostname):\(port)"
}

private func toSortedListItems(
    _ group: RepositoryListGroup,
    _ repositories: [RepositoryListEntry],
    _ localRepositoryStateLookup: [RepositoryID: RepositoryIndicator],
    allNames: [ExactString: Int]
) -> [RepositoryListItem] {
    var groupNames: [ExactString: Int] = [:]
    if group != .recent {
        for repository in repositories {
            groupNames[ExactString(repository.displayTitle), default: 0] += 1
        }
    }

    let isEnterprise = if case .enterprise = group { true } else { false }
    let items = repositories.map { repository in
        let title = repository.displayTitle
        // If the repository is in the enterprise group and has a duplicate
        // name in the group, we need to disambiguate it. We don't have to
        // disambiguate repositories in the 'dotcom' group because they are
        // already grouped by owner. If the repository is in the 'recent'
        // group and has a duplicate name in any group, we need to
        // disambiguate it.
        return listItem(
            repository,
            title: title,
            localRepositoryStateLookup,
            needsDisambiguation: (groupNames[ExactString(title)] ?? 0) > 1 && isEnterprise
                || (allNames[ExactString(title)] ?? 0) > 1 && group == .recent
        )
    }
    return sortedByTitle(items)
}

/// A list item for a repository or a clone, with its badges.
private func listItem(
    _ repository: RepositoryListEntry,
    title: String,
    _ localRepositoryStateLookup: [RepositoryID: RepositoryIndicator],
    needsDisambiguation: Bool
) -> RepositoryListItem {
    let repositoryState: RepositoryIndicator?
    let text: [String]
    switch repository {
    case .repository(let record):
        repositoryState = localRepositoryStateLookup[record.id]
        text = [title, nameOf(record)]
    case .clone:
        repositoryState = nil
        text = [title]
    }
    return RepositoryListItem(
        text: text,
        id: repository.id,
        repository: repository,
        needsDisambiguation: needsDisambiguation,
        aheadBehind: repositoryState?.aheadBehind,
        changedFilesCount: repositoryState?.changedFilesCount ?? 0
    )
}

/// Items by title, ignoring case, stably (as
/// `JSCompat.caseInsensitiveCompare` sorts): each title lowercased once,
/// then compared by its UTF-16 code units as `JSCompat.compare` does,
/// without decoding the strings again for every comparison.
private func sortedByTitle(_ items: [RepositoryListItem]) -> [RepositoryListItem] {
    // An item's first text is its title.
    let keyed = items.enumerated().map { offset, item in
        (offset: offset, key: Array(JSCompat.toLowerCase(item.text[0]).utf16), item: item)
    }
    return keyed
        .sorted { x, y in
            switch compareCodeUnits(x.key, y.key) {
            case 0: x.offset < y.offset
            case let result: result < 0
            }
        }
        .map(\.item)
}

/// -1, 0, or 1, as JavaScript compares strings: code unit by code unit,
/// then by length.
private func compareCodeUnits(_ x: [UInt16], _ y: [UInt16]) -> Int {
    for (a, b) in zip(x, y) where a != b {
        return a < b ? -1 : 1
    }
    return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
}

/// Sorts as JavaScript's `Array.prototype.sort` does with `compare`:
/// stably, keeping the order of items that compare equal.
func stableSorted<Element>(_ elements: [Element], by compare: (Element, Element) -> Int) -> [Element] {
    elements.enumerated()
        .sorted { x, y in
            let result = compare(x.element, y.element)
            return result != 0 ? result < 0 : x.offset < y.offset
        }
        .map(\.element)
}

extension AppModel {
    /// The repository list as the repository popover groups it: the
    /// repositories, then the clones in progress, with their badges and the
    /// recent group (`groupRepositories`).
    public var repositoryListGroups: [RepositoryListGroupItems] {
        groupRepositories(
            repositories.map(RepositoryListEntry.repository) + clones.clones.map(RepositoryListEntry.clone),
            indicators,
            recentRepositoryIDs
        )
    }

    /// A repository's availability if its model exists (it's been selected,
    /// added, or refreshed), without making one: nil otherwise. The list's
    /// rows read it for every repository.
    public func availability(of id: RepositoryID) -> RepositoryAvailability? {
        models[id]?.availability
    }
}

// MARK: - Repositories to clone

/// The identifier for the "Your Repositories" grouping.
public let yourRepositoriesIdentifier = "your-repositories"

/// What a repository to clone is, for its icon: private, a fork, or neither.
public enum CloneableRepositoryKind: Hashable, Sendable {
    case `private`
    case fork
    case repository
}

/// A repository in the clone list.
public struct CloneableRepositoryListItem: Hashable, Sendable, Identifiable {
    /// The identifier for the item: the repository's web page.
    public let id: String

    /// The search text: `owner/name`.
    public let text: [String]

    /// The name of the repository.
    public let name: String

    /// The icon for the repo.
    public let kind: CloneableRepositoryKind

    /// The clone URL.
    public let url: String

    /// Whether or not the repository is archived
    public let archived: Bool
}

/// One owner's repositories in the clone list.
public struct CloneableRepositoryGroup: Hashable, Sendable, Identifiable {
    /// `yourRepositoriesIdentifier`, or the owner's login.
    public let identifier: String
    public let items: [CloneableRepositoryListItem]

    public var id: String {
        identifier
    }
}

private func getKind(_ gitHubRepo: APIRepository) -> CloneableRepositoryKind {
    if gitHubRepo.private {
        return .private
    }
    if gitHubRepo.fork {
        return .fork
    }

    return .repository
}

private func toListItems(_ repositories: [APIRepository]) -> [CloneableRepositoryListItem] {
    let items = repositories.map { repo in
        CloneableRepositoryListItem(
            id: repo.htmlURL,
            text: ["\(repo.owner.login)/\(repo.name)"],
            name: repo.name,
            kind: getKind(repo),
            url: repo.cloneURL,
            archived: repo.archived
        )
    }
    return stableSorted(items) { JSCompat.compare($0.name, $1.name) }
}

/// Groups an account's repositories to clone by owner: the account's own
/// first ("Your Repositories", matching `login` ignoring case), then each
/// other owner in case-sensitive order; repositories sort by name.
public func groupRepositories(_ repositories: [APIRepository], login: String) -> [CloneableRepositoryGroup] {
    var identifiers: [String] = []
    var groups: [ExactString: [APIRepository]] = [:]
    for repository in repositories {
        let identifier = JSCompat.caseInsensitiveEquals(repository.owner.login, login)
            ? yourRepositoriesIdentifier
            : repository.owner.login
        if groups[ExactString(identifier)] == nil {
            identifiers.append(identifier)
        }
        groups[ExactString(identifier), default: []].append(repository)
    }

    return identifiers
        .map { CloneableRepositoryGroup(identifier: $0, items: toListItems(groups[ExactString($0)] ?? [])) }
        .sorted { x, y in
            if JSCompat.strictEquals(x.identifier, yourRepositoriesIdentifier) {
                return !JSCompat.strictEquals(y.identifier, yourRepositoriesIdentifier)
            } else if JSCompat.strictEquals(y.identifier, yourRepositoriesIdentifier) {
                return false
            } else {
                return JSCompat.compare(x.identifier, y.identifier) < 0
            }
        }
}
