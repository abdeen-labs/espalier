// Ported from desktop/app/src/lib/git/environment.ts and
// desktop/app/src/lib/git/authentication.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "git-environment")

/// Get the environment for authenticating remote operations.
public func envForAuthentication() -> [String: String?] {
    [
        // Supported since git 2.3, this is used to ensure we never
        // interactively prompt for credentials, even as a fallback.
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_TRACE": UserDefaults.standard.string(forKey: "git-trace").flatMap { $0.isEmpty ? nil : $0 } ?? "0",
    ]
}

/// The set of errors which fit under the "authentication failed" umbrella.
public let AuthenticationErrors: Set<DugiteError> = [
    .httpsAuthenticationFailed,
    .sshAuthenticationFailed,
    .httpsRepositoryNotFound,
    .sshRepositoryNotFound,
]

/// For many remote operations it's well known what the primary remote
/// url is (clone, push, fetch etc). But in some cases it's not as easy.
///
/// Two examples are checkout, and revert where neither would need to
/// hit the network in vanilla Git usage but do need to when LFS gets
/// involved.
///
/// What's the primary url when using LFS then? Most likely it's gonna
/// be on the same as the default remote but it could theoretically
/// be on a different server as well. That's too advanced for our usage
/// at the moment though so we'll just need to figure out some reasonable
/// url to fall back on.
///
/// - Parameters:
///   - repository: The repository the operation runs in.
///   - currentRemote: The repository's current remote, if any.
///   - gitHubHTMLURL: The web URL of the repository's GitHub endpoint
///     (GitHubKit's `getHTMLURL(gitHubRepository.endpoint)`), when the
///     repository is hosted on GitHub.
public func getFallbackUrlForProxyResolve(
    _ repository: Repository,
    _ currentRemote: Remote?,
    gitHubHTMLURL: String? = nil
) -> String {
    // Accounts are looked up by the repository endpoint, so the repository
    // endpoint is used directly.
    if let gitHubHTMLURL {
        return gitHubHTMLURL
    }

    // Ideally this would look up the remote url based on the currently
    // checked out branch, the upstream tracking branch of the branch being
    // checked out, or the default remote if neither of those are available.
    // Shelling out to Git here for that is too costly, so the current remote
    // stands in.
    if let currentRemote {
        return currentRemote.url
    }

    // If all else fails let's assume that whatever network resource
    // Git is gonna hit it's gonna be using the same proxy as it would
    // if it was a GitHub.com endpoint
    return "https://github.com"
}

/// Create a set of environment variables to use when invoking a git
/// subcommand that needs to communicate with a remote (fetch, clone, push,
/// pull, ls-remote, and so on).
///
/// The environment variables deal with setting up sane defaults, configuring
/// authentication, and resolving proxy URLs if necessary.
///
/// - Parameter remoteUrl: The primary remote URL for this operation. Git might
///   connect to other remotes in order to fulfill the operation (a clone could
///   contain a submodule pointing to another host entirely). Used to resolve
///   which proxy (if any) should be used for the operation.
public func envForRemoteOperation(_ remoteUrl: String) async -> [String: String?] {
    var env = envForAuthentication()
    if let proxy = await envForProxy(remoteUrl) {
        env.merge(proxy) { $1 }
    }
    return env
}

/// Not intended to be used directly. Exported only in order to allow for
/// testing.
///
/// - Parameters:
///   - remoteUrl: The remote URL to resolve a proxy for.
///   - env: The current environment variables, defaulting to the runtime's.
///   - resolve: The method to use when resolving the proxy URL, defaulting to
///     the runtime's resolver.
public func envForProxy(
    _ remoteUrl: String,
    env: [String: String]? = nil,
    resolve: (@Sendable (String) async throws -> String?)? = nil
) async -> [String: String?]? {
    let runtime = GitRuntime.current
    let env = env ?? runtime.processEnvironment

    // We can only resolve and use a proxy for the protocols where cURL would
    // be involved (i.e. http and https). git:// relies on ssh.
    guard let protocolMatch = remoteUrl.firstMatch(of: /^(?i)(https?):\/\//) else {
        return nil
    }

    // Note that HTTPS here doesn't mean that the proxy is HTTPS, only that all
    // requests to HTTPS protocols should be proxied. The proxy protocol is
    // defined by the URL returned by the resolver.
    let proto = protocolMatch.output.1.lowercased()

    // We'll play it safe and say that if the user has configured the
    // ALL_PROXY environment variable they probably know what they're doing
    // and wouldn't want us to override it with a protocol-specific proxy.
    // cURL supports both lower and upper case, see:
    // https://github.com/curl/curl/blob/14916a82e/lib/url.c#L2180-L2185
    if env["ALL_PROXY"] != nil || env["all_proxy"] != nil {
        logger.info("proxy url not resolved, ALL_PROXY already set")
        return nil
    }

    // Lower case environment variables due to
    // https://ec.haxx.se/usingcurl/usingcurl-proxies#http_proxy-in-lower-case-only
    let envKey = "\(proto)_proxy"

    // If the user has already configured a proxy in the environment for the
    // protocol we're not gonna override it.
    if env[envKey] != nil || (proto == "https" && env["HTTPS_PROXY"] != nil) {
        logger.info("proxy url not resolved, \(envKey, privacy: .public) already set")
        return nil
    }

    guard let resolve = resolve ?? runtime.resolveProxy else {
        return nil
    }

    let proxyUrl: String?
    do {
        proxyUrl = try await resolve(remoteUrl)
    } catch {
        logger.error("Failed resolving Git proxy: \(error.localizedDescription, privacy: .public)")
        proxyUrl = nil
    }

    guard let proxyUrl else {
        return nil
    }
    return [envKey: proxyUrl]
}
