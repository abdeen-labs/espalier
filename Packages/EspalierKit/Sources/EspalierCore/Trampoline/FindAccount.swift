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

/// The signed-in GitHub accounts, for the credential helper. The app
/// implements this with `AccountsTrampolineProvider`.
@MainActor
public protocol TrampolineAccountsProvider: Sendable {
    /// Every signed-in account.
    func getAll() async -> [TrampolineAccount]

    /// Whether `url` appears to belong to a GitHub host, or `nil` when that
    /// can't be determined: from the host name when it can, otherwise from the
    /// host's `/meta` API.
    func isGitHubHost(_ url: String) async -> Bool?
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
        : parsedUrl.username

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
