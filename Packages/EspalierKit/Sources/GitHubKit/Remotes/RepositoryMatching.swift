// Ported from desktop/app/src/lib/repository-matching.ts

import EspalierSupport
import Foundation

// GitKit owns the remote model and GitHubKit can't depend on GitKit, so these
// functions take a remote's URL.

public struct MatchedGitHubRepository: Sendable, Hashable {
    /// The name of the repository, e.g., for https://github.com/user/repo, the
    /// name is `repo`.
    public let name: String

    /// The login of the owner of the repository, e.g., for
    /// https://github.com/user/repo, the owner is `user`.
    public let owner: String

    /// The account matching the repository remote
    public let account: Account

    public init(name: String, owner: String, account: Account) {
        self.name = name
        self.owner = owner
        self.account = account
    }
}

/// Try to use the list of users and a remote URL to guess a GitHub repository.
public func matchGitHubRepository(_ accounts: [Account], _ remote: String) -> MatchedGitHubRepository? {
    for account in accounts {
        let htmlURL = getHTMLURL(account.endpoint)
        let hostname = hostname(of: htmlURL)
        let parsedRemote = parseRemote(remote)

        if let parsedRemote, let hostname {
            if parsedRemote.hostname.lowercased() == hostname.lowercased() {
                return MatchedGitHubRepository(name: parsedRemote.name, owner: parsedRemote.owner, account: account)
            }
        }
    }

    return nil
}

/// Find an existing repository associated with this path
///
/// - Parameters:
///   - repos: The list of repositories tracked in the app
///   - path: The path on disk which might be a repository
///   - repositoryPath: The path of a tracked repository
public func matchExistingRepository<T>(_ repos: [T], _ path: String, repositoryPath: (T) -> String) -> T? {
    let needle = POSIXPath.normalize(path)
    return repos.first { POSIXPath.normalize(repositoryPath($0)) == needle }
}

/// Check whether or not a GitHub repository matches a given remote.
///
/// - Parameters:
///   - gitHubRepository: the repository containing information from the GitHub API
///   - remoteURL: the URL of the remote found in the Git repository
public func repositoryMatchesRemote(_ gitHubRepository: GitHubRepository, remoteURL: String) -> Bool {
    urlMatchesRemote(gitHubRepository.htmlURL, remoteURL: remoteURL)
        || urlMatchesRemote(gitHubRepository.cloneURL, remoteURL: remoteURL)
}

/// Check whether or not a GitHub repository URL matches a given remote, by
/// parsing and comparing the structure of the each URL.
///
/// - Parameters:
///   - url: a URL associated with the GitHub repository
///   - remoteURL: the URL of the remote found in the Git repository
public func urlMatchesRemote(_ url: String?, remoteURL: String) -> Bool {
    guard let url else {
        return false
    }

    guard let cloneUrl = parseRemote(url), let remoteUrl = parseRemote(remoteURL) else {
        return false
    }

    if !caseInsensitiveEquals(remoteUrl.hostname, cloneUrl.hostname) {
        return false
    }

    return caseInsensitiveEquals(remoteUrl.owner, cloneUrl.owner)
        && caseInsensitiveEquals(remoteUrl.name, cloneUrl.name)
}

/// Match a URL-like string to the Clone URL of a GitHub Repository
///
/// - Parameters:
///   - url: A remote-like URL to verify against the existing information
///   - gitHubRepository: GitHub API details for a repository
public func urlMatchesCloneURL(_ url: String, _ gitHubRepository: GitHubRepository) -> Bool {
    guard let cloneURL = gitHubRepository.cloneURL else {
        return false
    }

    return urlsMatch(cloneURL, url)
}

public func urlsMatch(_ url1: String, _ url2: String) -> Bool {
    guard let firstIdentifier = parseRepositoryIdentifier(url1),
          let secondIdentifier = parseRepositoryIdentifier(url2)
    else { return false }

    return firstIdentifier.hostname == secondIdentifier.hostname
        && firstIdentifier.owner == secondIdentifier.owner
        && firstIdentifier.name == secondIdentifier.name
}

/// Compares the two strings in a case-insensitive manner and returns a value
/// indicating whether these are equal.
func caseInsensitiveEquals(_ x: String, _ y: String) -> Bool {
    x.lowercased() == y.lowercased()
}
