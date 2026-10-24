// Ported from desktop/app/src/lib/trampoline/find-account.ts

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "trampoline")

/// An account git can authenticate with.
public struct TrampolineAccount: Sendable, Equatable {
    /// For a GitHub account, its API endpoint (`https://api.github.com`, or
    /// an enterprise server's `https://<host>/api/v3`). For a generic
    /// credential, the remote URL without credentials.
    public let endpoint: String

    /// The username.
    public let login: String

    /// The password or token.
    public let token: String

    public init(endpoint: String, login: String, token: String) {
        self.endpoint = endpoint
        self.login = login
        self.token = token
    }
}

extension TrampolineAccount {
    /// The account's endpoint and login.
    var identity: AccountIdentity {
        AccountIdentity(endpoint: endpoint, login: login)
    }
}

/// A repository in the list, as the credential helper sees it: its GitHub
/// repository's endpoint and its assigned account.
public struct TrampolineRepository: Sendable, Equatable {
    public let id: RepositoryID
    /// The API endpoint of its GitHub repository, nil without one.
    public let endpoint: String?
    /// The login of its assigned account, nil without one.
    public let accountLogin: String?

    public init(id: RepositoryID, endpoint: String?, accountLogin: String?) {
        self.id = id
        self.endpoint = endpoint
        self.accountLogin = accountLogin
    }

    public init(_ record: RepositoryRecord) {
        self.init(id: record.id, endpoint: record.gitHubRepository?.endpoint, accountLogin: record.accountLogin)
    }
}

/// The signed-in GitHub accounts and the repository list, for the
/// credential helper. The app implements this with
/// `AccountsTrampolineProvider`.
@MainActor
public protocol TrampolineAccountsProvider: Sendable {
    /// Every signed-in account.
    func getAll() async -> [TrampolineAccount]

    /// Whether `url` appears to belong to a GitHub host, or `nil` when that
    /// can't be determined: from the host name when it can, otherwise from the
    /// host's `/meta` API.
    func isGitHubHost(_ url: String) async -> Bool?

    /// What to tell the user when git needs a repository's account and the
    /// keychain wouldn't give its token: the account `login` (its assigned
    /// one) on `endpoint`, or with no login, the only accounts on
    /// `endpoint`. Nil when there's no such account.
    func unreadableAccountMessage(endpoint: String, login: String?) async -> String?

    /// The repository in the list whose folder git runs in, if any.
    func repository(atPath path: String) async -> TrampolineRepository?

    /// Associates a repository without a GitHub repository with `endpoint`
    /// (git asks credentials for it) when its default remote is on it, and
    /// returns the repository as it is then.
    func associate(_ repository: TrampolineRepository, withEndpoint endpoint: String) async -> TrampolineRepository

    /// Asks the user for the repository's account: to sign in to its own
    /// again or choose another, to choose one, or to sign in to its server.
    /// Returns the account, assigned to the repository, or nil when the user
    /// cancelled. Only for git commands the user started.
    func promptForRepositoryAccount(_ repository: TrampolineRepository) async -> TrampolineAccount?
}

/// The username in `url`, percent-decoded, as git gives it and Espalier
/// stores it; a URL holds it percent-encoded (`getCredentialUrl`).
func decodedUsername(_ url: JSURL) -> String {
    url.username.removingPercentEncoding ?? url.username
}

func findGitHubTrampolineAccount(_ accountsStore: any TrampolineAccountsProvider, _ remoteUrl: String) async throws(JSURLError) -> TrampolineAccount? {
    let accounts = await accountsStore.getAll()
    let parsedUrl = try JSURL(remoteUrl)
    return accounts.first { account in
        (try? JSURL(getHTMLURL(account.endpoint)))?.origin == parsedUrl.origin
    }
}

func findGenericTrampolineAccount(
    _ invocation: TrampolineInvocation,
    _ remoteUrl: String,
    _ genericGitAuth: GenericGitAuth
) throws -> TrampolineAccount? {
    let parsedUrl = try JSURL(remoteUrl)
    let endpoint = urlWithoutCredentials(parsedUrl)

    let login = parsedUrl.username.isEmpty
        ? genericGitAuth.getGenericUsername(endpoint)
        : decodedUsername(parsedUrl)

    guard let login, !login.isEmpty else {
        return nil
    }

    let token = try invocation.memoizedGetGenericPassword(endpoint, login) {
        try genericGitAuth.getGenericPassword(endpoint, login)
    }

    guard let token, !token.isEmpty else {
        // We have a username but no password, that warrants a warning
        logger.warning("credential: generic password for \(remoteUrl, privacy: .private) missing")
        return nil
    }

    return TrampolineAccount(endpoint: endpoint, login: login, token: token)
}
