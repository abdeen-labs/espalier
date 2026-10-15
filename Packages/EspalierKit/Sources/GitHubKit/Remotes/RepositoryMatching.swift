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
        let server = RemoteServer(htmlURL: htmlURL)
        let parsedRemote = parseRemote(remote)

        if let parsedRemote, let server {
            if RemoteServer(parsedRemote).matches(server) {
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

    if !RemoteServer(remoteUrl).matches(RemoteServer(cloneUrl)) {
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

/// Whether two URLs, or `owner/name` shortcuts, name the same repository:
/// on the same server (`RemoteServer`), or both shortcuts, with the same
/// owner and name, ignoring case.
public func urlsMatch(_ url1: String, _ url2: String) -> Bool {
    guard let firstIdentifier = parseRepositoryIdentifier(url1),
          let secondIdentifier = parseRepositoryIdentifier(url2)
    else { return false }

    // An identifier has a host when its URL parses as a remote.
    let serversMatch = switch (parseRemote(url1), parseRemote(url2)) {
    case (nil, nil): true
    case (let first?, let second?): RemoteServer(first).matches(RemoteServer(second))
    default: false
    }

    return serversMatch
        && caseInsensitiveEquals(firstIdentifier.owner, secondIdentifier.owner)
        && caseInsensitiveEquals(firstIdentifier.name, secondIdentifier.name)
}

/// Compares the two strings in a case-insensitive manner and returns a value
/// indicating whether these are equal.
func caseInsensitiveEquals(_ x: String, _ y: String) -> Bool {
    x.lowercased() == y.lowercased()
}

// MARK: Servers

/// Whether `remote` is on the server `account` signed in to.
func isRemote(_ remote: GitRemoteURL, onServerOf account: Account) -> Bool {
    guard let server = RemoteServer(htmlURL: getHTMLURL(account.endpoint)) else {
        return false
    }
    return RemoteServer(remote).matches(server)
}

/// The server a remote, or an account's web site, is on, as remotes and
/// accounts are matched.
///
/// Host names compare ignoring case. An HTTPS remote's port is its web
/// server's, so another port is another server; a remote's scheme isn't
/// compared, so 443 and 80 are both the default. An SSH remote's port is its
/// SSH server's, which says nothing of the web server's, so a server from an
/// SSH remote matches by host name alone, and GitHub's SSH over HTTPS host,
/// `ssh.github.com`, is `github.com`.
struct RemoteServer: Sendable, Hashable {
    /// The host name, lowercased, without the port.
    let hostname: String

    /// The web server's port, unless it's the default. Nil for SSH.
    let port: Int?

    /// From an SSH remote: matches a server on any port.
    let isSSH: Bool

    init(_ remote: GitRemoteURL) {
        let (hostname, port) = splitPort(remote.hostname.lowercased())
        switch remote.protocol {
        case .https:
            self.hostname = hostname
            self.port = port == 443 || port == 80 ? nil : port
            isSSH = false
        case .ssh:
            self.hostname = hostname == "ssh.github.com" ? "github.com" : hostname
            self.port = nil
            isSSH = true
        }
    }

    /// The server of a web site (`getHTMLURL`); nil when the URL has no host.
    init?(htmlURL: String) {
        let parsed = ParsedURL(htmlURL)
        guard let hostname = parsed.hostname else {
            return nil
        }
        self.hostname = hostname
        port = parsed.port
        isSSH = false
    }

    func matches(_ other: RemoteServer) -> Bool {
        hostname == other.hostname && (isSSH || other.isSSH || port == other.port)
    }
}

/// `host:port` split at its port, when it ends in one.
private func splitPort(_ host: String) -> (hostname: String, port: Int?) {
    guard let colon = host.lastIndex(of: ":") else {
        return (host, nil)
    }
    let digits = host[host.index(after: colon)...]
    guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        return (host, nil)
    }
    return (String(host[..<colon]), Int(digits))
}
