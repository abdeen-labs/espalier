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

    private func getGitHubCredential(_ cred: GitCredential) async throws -> GitCredential? {
        let endpoint = try getCredentialUrl(cred).href
        let account = try await findGitHubTrampolineAccount(store, endpoint)
        if account != nil {
            info("found GitHub credential for \(endpoint) in store")
        }
        return credWithAccount(cred, account)
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

    /// Implementation of the 'get' git credential helper command
    private func getCredential(_ cred: GitCredential) async throws -> GitCredential? {
        if let ghCred = try await getGitHubCredential(cred) {
            return ghCred
        }

        let endpointKind = try await getEndpointKind(cred)
        let accounts = await store.getAll()

        let endpoint = try getCredentialUrl(cred).href
        let apiEndpoint = getAPIEndpoint(endpoint)

        // If it appears as if the endpoint is a GitHub host and we don't have
        // an account for that endpoint then we should prompt the user to sign
        // in.
        if endpointKind != .generic, !accounts.contains(where: { $0.endpoint == apiEndpoint }) {
            // An account whose token the keychain wouldn't give: git fails
            // with a message that says so, instead of asking to sign in.
            if let message = await store.unreadableAccountMessage(endpoint: apiEndpoint) {
                info("the token of the account for \(endpoint) couldn't be read from the keychain")
                invocation.setUnreadableAccountMessage(message)
                return nil
            }

            if invocation.isBackgroundTask {
                debug("background task environment, skipping prompt")
                return nil
            }

            let account = await prompter.promptForGitHubSignIn(endpoint: endpoint)

            if account == nil {
                invocation.setHasRejectedCredentialsForEndpoint(endpoint)
            }

            return credWithAccount(cred, account)
        }

        // GitHub.com/GHE creds are only stored internally
        if endpointKind != .generic {
            return nil
        }

        return useExternalCredentialHelper()
            ? try await getExternalCredential(cred)
            : try await getGenericCredential(cred)
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

    /// Implementation of the 'store' git credential helper command
    private func storeCredential(_ cred: GitCredential) async throws {
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
