// Ported from desktop/app/src/lib/api.ts (module functions)

import EspalierSupport
import Foundation
import os

private let log = Log.logger(category: "github-api")

/// Revoking a token needs the OAuth app's client secret
/// (`DELETE /applications/{client_id}/token` with Basic authentication), and a
/// device-flow app has none, so Espalier can't revoke tokens. Signing out
/// deletes the token from the keychain; the user revokes the authorization on
/// the server's settings page (`getOAuthApplicationSettingsURL`).
///
/// Always returns `false`, as for a failed revocation.
public func deleteToken(_ account: Account) async -> Bool {
    log.info("deleteToken: revoking tokens needs a client secret; skipping for \(account.endpoint, privacy: .public)")
    return false
}

/// The page where the user can review and revoke the access they granted to
/// an OAuth app (see `deleteToken`).
public func getOAuthApplicationSettingsURL(endpoint: String, clientID: String) -> String {
    let base = getHTMLURL(endpoint)
    let separator = base.hasSuffix("/") ? "" : "/"
    return "\(base)\(separator)settings/connections/applications/\(encodeURIComponent(clientID))"
}

/// Fetch the user authenticated by the token.
public func fetchUser(endpoint: String, token: String, runtime: GitHubRuntime = .current) async throws -> Account {
    let api = API(endpoint: endpoint, token: token, runtime: runtime)
    do {
        async let user = api.fetchAccount()
        async let emails = api.fetchEmails()
        let (fetchedUser, fetchedEmails) = try await (user, emails)

        return Account(
            login: fetchedUser.login,
            endpoint: endpoint,
            token: token,
            emails: fetchedEmails,
            avatarURL: fetchedUser.avatarURL,
            id: fetchedUser.id,
            name: fetchedUser.name.flatMap { $0.isEmpty ? nil : $0 } ?? fetchedUser.login,
            plan: fetchedUser.plan?.name
        )
    } catch {
        log.warning("fetchUser: failed with endpoint \(endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
        throw error
    }
}

/// Map a repository's URL to the endpoint associated with it. For example:
///
/// https://github.com/desktop/desktop -> https://api.github.com
/// http://github.mycompany.com/my-team/my-project -> https://github.mycompany.com/api/v3
/// https://octocorp.ghe.com/my-team/my-project -> https://api.octocorp.ghe.com/
///
/// For any other host, this returns the endpoint sign-in stores for that
/// host (`.../api/v3`, or the `api.` subdomain on ghe.com), so
/// `getAccountForEndpoint` finds the account.
public func getEndpointForRepository(_ url: String) -> String {
    let parsed = ParsedURL(url)
    if parsed.hostname == "github.com" {
        return getDotComAPIEndpoint()
    } else {
        return getEnterpriseAPIURL(url)
    }
}

/// Get the URL for the HTML site. For example:
///
/// https://api.github.com -> https://github.com
/// http://github.mycompany.com/api -> http://github.mycompany.com/
public func getHTMLURL(_ endpoint: String) -> String {
    // In the case of GitHub.com, the HTML site lives on the parent domain.
    //  E.g., https://api.github.com -> https://github.com
    //
    // Whereas with Enterprise, it lives on the same domain but without the
    // API path:
    //  E.g., https://github.mycompany.com/api/v3 -> https://github.mycompany.com
    //
    // We need to normalize them.
    if endpoint == getDotComAPIEndpoint() {
        return "https://github.com"
    } else {
        if isGHE(endpoint), var url = URLComponents(string: endpoint) {
            url.path = "/"

            if let host = url.host?.lowercased() {
                url.host = host.hasPrefix("api.") ? String(host.dropFirst(4)) : host
            }

            if let string = url.string {
                return string
            }
        }

        let parsed = ParsedURL(endpoint)
        return "\(parsed.protocol ?? "")//\(parsed.hostname ?? "")"
    }
}

/// Get the API URL for an HTML URL. For example:
///
/// http://github.mycompany.com -> https://github.mycompany.com/api/v3
public func getEnterpriseAPIURL(_ endpoint: String) -> String {
    let host = ParsedURL(endpoint).host ?? ""

    return isGHE(endpoint) ? "https://api.\(host)/" : "https://\(host)/api/v3"
}

public func getAPIEndpoint(_ endpoint: String) -> String {
    isDotCom(endpoint) ? getDotComAPIEndpoint() : getEnterpriseAPIURL(endpoint)
}

/// Get github.com's API endpoint.
public func getDotComAPIEndpoint() -> String {
    "https://api.github.com"
}

/// Get the account for the endpoint.
public func getAccountForEndpoint(_ accounts: [Account], _ endpoint: String) -> Account? {
    accounts.first { $0.endpoint == endpoint }
}

func tryUpdateEndpointVersionFromResponse(_ endpoint: String, _ response: HTTPResponse, runtime: GitHubRuntime) {
    if let gheVersion = response.headers.get("x-github-enterprise-version") {
        runtime.endpointVersions.updateEndpointVersion(endpoint, gheVersion)
    }
}

private let knownThirdPartyHosts: Set<String> = [
    "dev.azure.com",
    "gitlab.com",
    "bitbucket.org",
    "amazonaws.com",
    "visualstudio.com",
]

private func isKnownThirdPartyHost(_ hostname: String) -> Bool {
    if knownThirdPartyHosts.contains(hostname) {
        return true
    }

    for knownHost in knownThirdPartyHosts where hostname.hasSuffix(".\(knownHost)") {
        return true
    }

    return false
}

/// Attempts to determine whether or not the url belongs to a GitHub host.
///
/// This is a best-effort attempt and may return `nil` if encountering
/// an error making the discovery request (or if the URL can't be parsed).
public func isGitHubHost(_ url: String, runtime: GitHubRuntime = .current) async -> Bool? {
    guard let hostname = hostname(of: url) else {
        return nil
    }

    let endpoint = hostname == "github.com" || hostname == "api.github.com"
        ? getDotComAPIEndpoint()
        : getEnterpriseAPIURL(url)

    if isDotCom(endpoint) || isGHE(endpoint) {
        return true
    }

    if isKnownThirdPartyHost(hostname) {
        return false
    }

    // github.example.com,
    if hostname.contains(/(^|\.)(github)\./) {
        return true
    }

    // bitbucket.example.com, etc
    if hostname.contains(/(^|\.)(bitbucket|gitlab)\./) {
        return false
    }

    if runtime.endpointVersions.getEndpointVersion(endpoint) != nil {
        return true
    }

    // URLSession never shows a certificate prompt, so a certificate error
    // simply fails the request.
    guard let metaURL = URL(string: "\(endpoint)/meta?ghd=\(UUID().uuidString.lowercased())") else {
        return nil
    }

    var metaRequest = URLRequest(url: metaURL)
    metaRequest.httpMethod = HTTPMethod.head.rawValue
    metaRequest.setValue(runtime.userAgent, forHTTPHeaderField: "User-Agent")
    metaRequest.httpShouldHandleCookies = false
    let request = metaRequest

    do {
        let response = try await withDeadline(.seconds(2)) {
            try await runtime.perform(request, redirect: .error)
        }

        tryUpdateEndpointVersionFromResponse(endpoint, response, runtime: runtime)

        return response.headers.has("x-github-request-id")
    } catch {
        log.debug("isGitHubHost: failed with endpoint \(endpoint, privacy: .public): \(String(describing: error), privacy: .public)")
        return nil
    }
}

func isRulesetsNotEnabledError(_ error: any Error) -> Bool {
    guard let error = error as? APIError, error.responseStatus == 403 else { return false }
    return (error.apiError?.message ?? "").contains(/(?i)upgrade.*to enable this feature.*/)
}

func isNotFoundApiError(_ error: any Error) -> Bool {
    (error as? APIError)?.responseStatus == 404
}
