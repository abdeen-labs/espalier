// Ported from desktop/app/src/lib/repository-matching.ts

import EspalierSupport
import Foundation
import os

private let log = Log.logger(category: "repository-matching")

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
    guard let parsedRemote = parseRemote(remote),
          let account = accounts.first(where: { remoteMatchesEndpoint(parsedRemote, $0.endpoint) })
    else {
        return nil
    }
    return MatchedGitHubRepository(name: parsedRemote.name, owner: parsedRemote.owner, account: account)
}

/// A match that isn't scoped to any account: for a remote on a GitHub host
/// when no account was chosen, so its GitHub repository isn't tied to an
/// arbitrary signed-in login.
public func toAnonymousMatch(endpoint: String, owner: String, name: String) -> MatchedGitHubRepository {
    let account = Account(login: "", endpoint: endpoint, token: "", emails: [], avatarURL: "", id: -1, name: "")
    return MatchedGitHubRepository(name: name, owner: owner, account: account)
}

/// Whether a remote is hosted on the API endpoint `endpoint`: an HTTPS
/// remote on its web site's host and port, an SSH remote on its host name
/// (`RemoteServer`).
public func remoteMatchesEndpoint(_ remote: GitRemoteURL, _ endpoint: String) -> Bool {
    guard let server = RemoteServer(htmlURL: getHTMLURL(endpoint)) else {
        return false
    }
    return RemoteServer(remote).matches(server)
}

/// The API endpoint a remote is hosted on.
///
/// The first of `candidates` the remote matches (`remoteMatchesEndpoint`),
/// so an SSH remote finds a server whose web site is on another port; else
/// the endpoint of the remote's own host. Nil when the remote has no host.
public func getEndpointForRemote(_ remote: GitRemoteURL, candidates: [String]) -> String? {
    if let known = candidates.first(where: { remoteMatchesEndpoint(remote, $0) }) {
        return known
    }
    let server = RemoteServer(remote)
    guard !server.hostname.isEmpty else {
        return nil
    }
    let host = server.port.map { "\(server.hostname):\($0)" } ?? server.hostname
    return getAPIEndpoint("https://\(host)")
}

// MARK: Accounts with access

/// What to associate a repository with once an account was chosen for its
/// remote: the match, and the repository as the API returned it when the
/// account's access was checked. Without an API repository (the account was
/// picked in the Clone sheet, or the remote is a wiki), it loads on the
/// next refresh.
public struct RemoteRepositoryAssignment: Sendable {
    public let match: MatchedGitHubRepository
    public let apiRepository: APIFullRepository?

    public init(match: MatchedGitHubRepository, apiRepository: APIFullRepository? = nil) {
        self.match = match
        self.apiRepository = apiRepository
    }

    public var account: Account {
        match.account
    }
}

/// Looks a repository up with an account: nil when the account can't see
/// it (a 404); throws when its access can't be checked.
public typealias RepositoryAccessLookup = @Sendable (_ account: Account, _ owner: String, _ name: String) async throws -> APIFullRepository?

/// `API.fetchRepositoryIfAccessible` through `runtime`.
public func lookupRepositoryAccess(runtime: GitHubRuntime) -> RepositoryAccessLookup {
    { account, owner, name in
        try await API.fromAccount(account, runtime: runtime).fetchRepositoryIfAccessible(owner: owner, name: name)
    }
}

/// Checks whether `account` can see the repository at `remote`: nil when
/// the remote isn't on the account's server or the account can't see it.
/// A wiki's access is its repository's, and it gets no API repository.
///
/// - Throws: When the access can't be checked (`RepositoryAccessLookup`).
public func probeRemoteRepositoryAccount(
    _ account: Account,
    _ remote: String,
    lookup: RepositoryAccessLookup
) async throws -> RemoteRepositoryAssignment? {
    guard let match = matchGitHubRepository([account], remote) else {
        return nil
    }
    // The API doesn't know about wikis, so check access to the wiki's
    // repository instead.
    if let wikiOf = wikiRepositoryName(match.name) {
        return try await lookup(account, match.owner, wikiOf) == nil ? nil : RemoteRepositoryAssignment(match: match)
    }
    guard let apiRepository = try await lookup(account, match.owner, match.name) else {
        return nil
    }
    return RemoteRepositoryAssignment(match: match, apiRepository: apiRepository)
}

/// The repository a wiki's name (`name.wiki`, any case) belongs to.
private func wikiRepositoryName(_ name: String) -> String? {
    guard name.count > 5, JSCompat.endsWith(JSCompat.toLowerCase(name), ".wiki") else {
        return nil
    }
    return String(name.dropLast(5))
}

/// What choosing an account for a remote came to.
public enum RemoteAccountChoice: Sendable {
    /// The account to assign, with what its check found.
    case assigned(RemoteRepositoryAssignment)
    /// No signed-in account on the remote's server can see the repository
    /// (each was checked: a 404), or none is signed in to it.
    case noAccess
    /// No account was found to see the repository, and the access of some
    /// couldn't be checked: nothing is known to lack access.
    case undecided
    /// The user cancelled choosing.
    case cancelled
}

/// Asks the user which of several accounts to use for a repository.
///
/// Gets the match (the repository's owner and name, on the server of the
/// first account offered) and the accounts to offer; returns the chosen
/// one (perhaps one signed in meanwhile), or nil when the user cancels.
public typealias RemoteAccountChooser = @Sendable (_ match: MatchedGitHubRepository, _ accounts: [Account]) async -> Account?

/// Checks every account on the remote's server for access, then chooses
/// among them.
///
/// Only a 404 means an account can't see the repository. An account whose
/// access can't be checked (a SAML 403, a rate limit, a network error) is
/// logged and left undecided: not taken to lack access, and never a reason
/// to settle on another account. So the only account with access is
/// assigned on its own only when every other account on the server was
/// checked; otherwise the user picks among the accounts with access and
/// those left undecided. Without an account that can see it and none left
/// undecided, it's `noAccess`; with only undecided ones, `undecided`.
///
/// An account the user picks that wasn't checked (one signed in from the
/// chooser) or was left undecided is checked before it's accepted.
///
/// - Throws: When the account the user picks can't see the repository, or
///   its access can't be checked.
public func chooseAccountForRemoteRepository(
    _ accounts: [Account],
    _ remote: String,
    lookup: @escaping RepositoryAccessLookup,
    choose: RemoteAccountChooser
) async throws -> RemoteAccountChoice {
    enum Probe: Sendable {
        case accessible(RemoteRepositoryAssignment)
        case noAccess
        case undecided(MatchedGitHubRepository)
    }
    let probes = await withTaskGroup(of: (Int, Probe?).self) { group in
        for (index, account) in accounts.enumerated() {
            guard let match = matchGitHubRepository([account], remote) else {
                // Not on the remote's server.
                continue
            }
            group.addTask {
                do {
                    guard let assignment = try await probeRemoteRepositoryAccount(account, remote, lookup: lookup) else {
                        return (index, .noAccess)
                    }
                    return (index, .accessible(assignment))
                } catch {
                    log.warning("Couldn't check repository access for @\(account.login, privacy: .public) (\(account.endpoint, privacy: .public)): \(String(describing: error), privacy: .public)")
                    return (index, .undecided(match))
                }
            }
        }
        var results: [(Int, Probe)] = []
        for await (index, probe) in group {
            if let probe {
                results.append((index, probe))
            }
        }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    let accessible = probes.compactMap { probe -> RemoteRepositoryAssignment? in
        if case .accessible(let assignment) = probe {
            return assignment
        }
        return nil
    }
    let undecided = probes.compactMap { probe -> MatchedGitHubRepository? in
        if case .undecided(let match) = probe {
            return match
        }
        return nil
    }

    if accessible.count == 1, undecided.isEmpty {
        return .assigned(accessible[0])
    }
    guard let first = accessible.first?.match ?? undecided.first else {
        return .noAccess
    }
    if accessible.isEmpty {
        return .undecided
    }

    let offered = accessible.map(\.account) + undecided.map(\.account)
    guard let selected = await choose(first, offered) else {
        return .cancelled
    }
    if let assignment = accessible.first(where: { $0.account.identity == selected.identity }) {
        return .assigned(assignment)
    }
    // An account signed in from the chooser, or one left undecided, is
    // checked before it's used.
    guard let assignment = try await probeRemoteRepositoryAccount(selected, remote, lookup: lookup) else {
        throw GitHubError("The account @\(selected.login) can't access \(first.owner)/\(first.name).")
    }
    return .assigned(assignment)
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
