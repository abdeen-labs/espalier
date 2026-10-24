// Ported from desktop/app/src/lib/trampoline/trampoline-credential-helper.ts

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "trampoline")

private func info(_ msg: String) {
    logger.info("credential-helper: \(msg, privacy: .private)")
}

private func debug(_ msg: String) {
    logger.debug("credential-helper: \(msg, privacy: .private)")
}

private func error(_ msg: String, _ e: any Error) {
    logger.error("credential-helper: \(msg, privacy: .public): \(e.localizedDescription, privacy: .private)")
}

/// A required credential attribute is missing.
private struct MissingCredentialAttributeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func forceUnwrap(_ message: String, _ value: String?) throws -> String {
    guard let value else {
        throw MissingCredentialAttributeError(message: message)
    }
    return value
}

/// Merges credential info from account into credential
///
/// When looking up a first-party account (GitHub.com et al) we can't use the
/// account's endpoint host in the credential since that's the API url so
/// instead we take all the fields from the credential and set the username
/// and password from the Account on top of those.
private func credWithAccount(_ c: GitCredential, _ a: TrampolineAccount?) -> GitCredential? {
    guard let a else { return nil }
    var cred = c
    cred["username"] = a.login
    cred["password"] = a.token
    return cred
}

private enum EndpointKind {
    case generic
    case dotCom
    case gheDotCom
    case enterprise
}

/// Git's credential helper protocol (espalier-askpass running as
/// `credential.helper`): `get`, `store`, and `erase`.
struct TrampolineCredentialHelper: Sendable {
    let invocation: TrampolineInvocation
    let store: any TrampolineAccountsProvider
    let prompter: any TrampolinePrompter
    let genericGitAuth: GenericGitAuth
    let useExternalCredentialHelper: @Sendable () -> Bool

    /// The credential to print for `get`, or `nil` to print nothing.
    func handle(_ command: TrampolineCommand, stdin: String) async -> String? {
        guard let firstParameter = command.parameters.first, !firstParameter.isEmpty else {
            return nil
        }

        let input = parseCredential(stdin)

        do {
            if firstParameter == "get" {
                let cred = try await getCredential(input)
                if cred == nil {
                    let endpoint = try getCredentialUrl(input).href
                    info("could not find credential for \(endpoint)")
                    invocation.setHasRejectedCredentialsForEndpoint(endpoint)
                }
                return try cred.map(formatCredential)
            } else if firstParameter == "store" {
                try await storeCredential(input)
            } else if firstParameter == "erase" {
                try await eraseCredential(input)
            }
            return nil
        } catch let e {
            error("\(firstParameter) failed", e)
            return nil
        }
    }

    private func promptForCredential(_ cred: GitCredential, _ endpoint: String) async throws -> GitCredential? {
        let parsedUrl = try JSURL(endpoint)
        let username = parsedUrl.username.isEmpty ? nil : decodedUsername(parsedUrl)
        let account = await prompter.promptForGenericGitAuthentication(endpoint: endpoint, username: username)
        info("prompt for \(endpoint): \(account != nil ? "completed" : "cancelled")")
        return credWithAccount(cred, account)
    }

    private func getGenericCredential(_ cred: GitCredential) async throws -> GitCredential? {
        let endpoint = try getCredentialUrl(cred).href
        let account = try findGenericTrampolineAccount(invocation, endpoint, genericGitAuth)

        if account != nil {
            info("found generic credential for \(endpoint)")
            return credWithAccount(cred, account)
        }

        if invocation.isBackgroundTask {
            debug("background task environment, skipping prompt")
            return nil
        } else {
            return try await promptForCredential(cred, endpoint)
        }
    }

    private func getExternalCredential(_ input: GitCredential) async throws -> GitCredential? {
        let cred = try await fillCredential(input, invocation.path, getGcmEnv())
        info("found credential for \((try? getCredentialUrl(cred).href) ?? "") in external helper")
        return cred
    }

    /// Implementation of the 'get' git credential helper command.
    ///
    /// For a repository in the list, a request on its GitHub repository's
    /// exact origin (scheme, host, and port) gets its assigned account's
    /// credentials; when that account isn't signed in, or it has none, a
    /// git command the user started asks for one, and a background task
    /// gets nothing. Where no repository is (a clone), the fallback account
    /// git was given, on its own origin, and only while it's signed in.
    /// Other GitHub hosts get nothing: a repository's credentials are never
    /// lent to another endpoint (a submodule on another server, a remote
    /// over plain HTTP). Hosts that aren't GitHub's use the stored generic
    /// credentials, or the external helper.
    private func getCredential(_ cred: GitCredential) async throws -> GitCredential? {
        let credentialUrl = try getCredentialUrl(cred)
        let endpoint = credentialUrl.href

        var knownKind: EndpointKind?
        func endpointKind() async throws -> EndpointKind {
            if let knownKind {
                return knownKind
            }
            let kind = try await getEndpointKind(cred)
            knownKind = kind
            return kind
        }

        var repository = await store.repository(atPath: invocation.path)
        // A repository whose GitHub remote hasn't been recognized yet (an
        // Enterprise Server without a signed-in account, or a remote added
        // outside Espalier) is associated with the endpoint now, so it's
        // handled like any other repository without an account below.
        if let existing = repository, existing.endpoint == nil, try await endpointKind() != .generic {
            repository = await store.associate(existing, withEndpoint: getAPIEndpoint(endpoint))
        }

        if let repository, let repositoryEndpoint = repository.endpoint, isSameOrigin(credentialUrl, repositoryEndpoint) {
            return await getRepositoryCredential(cred, repository: repository, endpoint: repositoryEndpoint)
        }

        if let fallback = invocation.fallbackAccount, isSameOrigin(credentialUrl, fallback.endpoint) {
            let identity = AccountIdentity(endpoint: fallback.endpoint, login: fallback.login)
            let account = await store.getAll().first { $0.identity == identity }
            info("\(account == nil ? "the account to clone with isn't signed in" : "found the account to clone with") for \(endpoint)")
            return credWithAccount(cred, account)
        }

        // GitHub.com/GHE creds are only stored internally, and never lent to
        // another endpoint.
        if try await endpointKind() != .generic {
            info("no matching account for \(endpoint)")
            return nil
        }

        return useExternalCredentialHelper()
            ? try await getExternalCredential(cred)
            : try await getGenericCredential(cred)
    }

    /// The credentials of the repository's account, a request on its
    /// GitHub repository's origin. Its account isn't signed in, or it has
    /// none: one whose token the keychain wouldn't give fails with a message
    /// that says so, a background task gets nothing, and otherwise the user
    /// is asked.
    private func getRepositoryCredential(_ cred: GitCredential, repository: TrampolineRepository, endpoint: String) async -> GitCredential? {
        if let login = repository.accountLogin {
            let identity = AccountIdentity(endpoint: endpoint, login: login)
            if let account = await store.getAll().first(where: { $0.identity == identity }) {
                info("found the repository's account for \(endpoint)")
                return credWithAccount(cred, account)
            }
        }

        if let message = await store.unreadableAccountMessage(endpoint: endpoint, login: repository.accountLogin) {
            info("the token of the repository's account on \(endpoint) couldn't be read from the keychain")
            invocation.setUnreadableAccountMessage(message)
            return nil
        }

        if invocation.isBackgroundTask {
            debug("background task environment, skipping prompt")
            return nil
        }

        let account = await store.promptForRepositoryAccount(repository)
        info("prompt for the repository's account on \(endpoint): \(account != nil ? "completed" : "cancelled")")
        guard let account, JSCompat.strictEquals(account.endpoint, endpoint) else {
            return nil
        }
        return credWithAccount(cred, account)
    }

    private func getEndpointKind(_ cred: GitCredential) async throws -> EndpointKind {
        let credentialUrl = try getCredentialUrl(cred)
        let endpoint = credentialUrl.href

        if isGist(endpoint) {
            return .generic
        }

        if isDotCom(endpoint) {
            return .dotCom
        }

        if isGHE(endpoint) {
            return .gheDotCom
        }

        // When Git attempts to authenticate with a host it captures any
        // WWW-Authenticate headers and forwards them to the credential
        // helper. We use them as a happy-path to determine if the host is a
        // GitHub host without having to resort to making a request ourselves.
        for entry in cred.entries where JSCompat.startsWith(entry.key, "wwwauth[") {
            if entry.value.range(of: #"realm="GitHub""#, options: .literal) != nil {
                return .enterprise
            } else if JSCompat.match(entry.value, thirdPartyRealmRe) != nil {
                return .generic
            }
        }

        if let existingAccount = try await findGitHubTrampolineAccount(store, endpoint) {
            return isDotCom(existingAccount.endpoint) ? .dotCom : .enterprise
        }

        // All GitHub hosts use HTTPS, so if the protocol is not HTTPS we can
        // assume that this is not a GitHub host.
        if credentialUrl.protocol != "https:" {
            return .generic
        }

        return await store.isGitHubHost(endpoint) == true ? .enterprise : .generic
    }

    /// Whether the request is on the GitHub origin of the repository git
    /// runs in, or of the account a clone uses, as `getCredential` decides:
    /// its credentials are an account's, so they're never stored or erased
    /// as generic ones, whatever kind of host it looks like (an account
    /// chosen when git asked isn't in the list of accounts yet).
    private func isAccountOrigin(_ cred: GitCredential) async throws -> Bool {
        let credentialUrl = try getCredentialUrl(cred)
        if let repository = await store.repository(atPath: invocation.path), let endpoint = repository.endpoint,
           isSameOrigin(credentialUrl, endpoint) {
            return true
        }
        if let fallback = invocation.fallbackAccount, isSameOrigin(credentialUrl, fallback.endpoint) {
            return true
        }
        return false
    }

    /// Implementation of the 'store' git credential helper command
    private func storeCredential(_ cred: GitCredential) async throws {
        if try await isAccountOrigin(cred) {
            return
        }
        if try await getEndpointKind(cred) != .generic {
            return
        }

        if useExternalCredentialHelper() {
            try await storeExternalCredential(cred)
        } else {
            try genericGitAuth.setGenericCredential(
                urlWithoutCredentials(getCredentialUrl(cred)),
                forceUnwrap("credential missing username", cred["username"]),
                forceUnwrap("credential missing password", cred["password"])
            )
        }
    }

    private func storeExternalCredential(_ cred: GitCredential) async throws {
        try await approveCredential(cred, invocation.path, getGcmEnv())
    }

    /// Implementation of the 'erase' git credential helper command
    private func eraseCredential(_ cred: GitCredential) async throws {
        if try await isAccountOrigin(cred) {
            return
        }
        if try await getEndpointKind(cred) != .generic {
            return
        }

        if useExternalCredentialHelper() {
            try await eraseExternalCredential(cred)
        } else {
            try genericGitAuth.deleteGenericCredential(
                urlWithoutCredentials(getCredentialUrl(cred)),
                forceUnwrap("credential missing username", cred["username"])
            )
        }
    }

    private func eraseExternalCredential(_ cred: GitCredential) async throws {
        try await rejectCredential(cred, invocation.path, getGcmEnv())
    }

    private func getGcmEnv() -> [String: String?] {
        ["GCM_INTERACTIVE": invocation.isBackgroundTask ? "0" : "1"]
    }
}

private let thirdPartyRealmRe = JSCompat.regex(#"realm="(GitLab|Gitea|Atlassian Bitbucket)""#)

/// Whether `url` is on the exact origin (scheme, host, and port) of the web
/// site of `endpoint`, an API endpoint, so a token is never sent over plain
/// HTTP, to another port, or to another service on the same host.
func isSameOrigin(_ url: JSURL, _ endpoint: String) -> Bool {
    guard let site = try? JSURL(getHTMLURL(endpoint)) else {
        return false
    }
    return JSCompat.strictEquals(site.origin, url.origin)
}
