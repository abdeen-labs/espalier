// Ported from desktop/app/src/lib/clone-info.ts

import EspalierSupport
import Foundation
import os

private let log = Log.logger(category: "clone-info")

/// Looks up the clone URL and default branch of `owner/name` with an
/// account, in the protocol given: nil when the account can't see the
/// repository; throws when it can't be asked.
public typealias CloneInfoLookup = @Sendable (_ account: Account, _ owner: String, _ name: String, _ protocol: GitProtocol?) async throws -> APIRepositoryCloneInfo?

/// `API.fetchRepositoryCloneInfo` through `runtime`.
public func lookupCloneInfo(runtime: GitHubRuntime) -> CloneInfoLookup {
    { account, owner, name, gitProtocol in
        try await API.fromAccount(account, runtime: runtime).fetchRepositoryCloneInfo(owner: owner, name: name, protocol: gitProtocol)
    }
}

/// What resolving a URL typed in the Clone sheet came to.
public enum URLCloneInfoResolution: Sendable, Equatable {
    /// Clone this: the API's URL (in the protocol typed) and default branch,
    /// or the URL as typed.
    case clone(APIRepositoryCloneInfo)
    /// No account on the URL's host can see the repository, and the URL is
    /// an HTTPS one.
    case notFound
}

/// Resolves what to clone for a URL typed in the Clone sheet's URL tab.
///
/// Every signed-in account on the URL's host is tried in turn, then
/// GitHub.com without signing in, and the URL's protocol is kept: the first
/// that can see the repository gives what to clone. An account that can't
/// see it (a 404), or can't be asked, never ends the search. When none of
/// them can see the repository, the URL is cloned as typed if any of them
/// couldn't be asked (nothing is known to lack access), and so is an SSH
/// URL, since the user's SSH configuration may still grant access; an
/// HTTPS URL that every account was asked about is `notFound`. A URL on a
/// host without a signed-in account is cloned as typed.
///
/// Which account the clone uses is chosen afterwards, by checking each
/// account's access (`chooseAccountForRemoteRepository`).
///
/// - Parameters:
///   - remote: The URL, parsed (`parseRemote`).
///   - url: The URL as typed.
public func resolveURLCloneInfo(
    _ remote: GitRemoteURL,
    url: String,
    accounts: [Account],
    lookup: CloneInfoLookup
) async -> URLCloneInfoResolution {
    let asTyped = URLCloneInfoResolution.clone(APIRepositoryCloneInfo(url: url))
    let candidates = (accounts + [Account.anonymous()]).filter { remoteMatchesEndpoint(remote, $0.endpoint) }
    guard !candidates.isEmpty else {
        return asTyped
    }

    var lookupFailed = false
    for account in candidates {
        do {
            if let info = try await lookup(account, remote.owner, remote.name, remote.protocol) {
                return .clone(info)
            }
        } catch {
            log.error("Failed to look up repository clone info for '\(url, privacy: .private)' with @\(account.login, privacy: .public): \(String(describing: error), privacy: .public)")
            lookupFailed = true
        }
    }

    return lookupFailed || remote.protocol == .ssh ? asTyped : .notFound
}
