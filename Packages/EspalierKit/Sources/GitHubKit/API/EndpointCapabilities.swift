// Ported from desktop/app/src/lib/endpoint-capabilities.ts

import Foundation
import Synchronization

/// A GitHub Enterprise Server requirement: allowed or not regardless of
/// version, or a SemVer range (ex: `>= 3.1.0`).
public enum EnterpriseServerConstraint: Sendable, Hashable, ExpressibleByBooleanLiteral, ExpressibleByStringLiteral {
    case allowed(Bool)
    case range(String)

    public init(booleanLiteral value: Bool) { self = .allowed(value) }
    public init(stringLiteral value: String) { self = .range(value) }
}

public struct VersionConstraint: Sendable, Hashable {
    /// Whether this constrain will be satisfied when using GitHub.com, defaults
    /// to false
    public var dotcom: Bool?

    /// Whether this constrain will be satisfied when using ghe.com, defaults to
    /// the value of `dotcom` if not specified
    public var ghe: Bool?

    /// Whether this constrain will be satisfied when using GitHub Enterprise
    /// Server. Supports specifying a version constraint as a SemVer Range (ex:
    /// >= 3.1.0), defaults to false
    public var es: EnterpriseServerConstraint?

    public init(dotcom: Bool? = nil, ghe: Bool? = nil, es: EnterpriseServerConstraint? = nil) {
        self.dotcom = dotcom
        self.ghe = ghe
        self.es = es
    }
}

/// If we're connected to a GHES instance but it doesn't report a version
/// number (either because of corporate proxies that strip the version
/// header or because GHES stops sending the version header in the future)
/// we'll assume it's this version.
///
/// This should correspond loosely with the oldest supported GHES series and
/// needs to be updated manually.
let assumedGHESVersion = SemVer(major: 3, minor: 1, patch: 0)

/// Get the cache key for a given endpoint address
func endpointVersionKey(_ ep: String) -> String { "endpoint-version:\(ep)" }

/// The `x-github-enterprise-version` headers seen for each endpoint, raw and
/// parsed. Raw versions persist to an optional `DataStore`.
public final class EndpointVersionCache: Sendable {
    private struct State {
        /// Stores raw x-github-enterprise-version headers keyed on endpoint
        var raw: [String: String] = [:]
        /// Stores parsed x-github-enterprise-version headers keyed on endpoint
        var parsed: [String: SemVer?] = [:]
    }

    private let state = Mutex(State())
    private let dataStore: (any DataStore)?

    public init(dataStore: (any DataStore)? = nil) {
        self.dataStore = dataStore
    }

    public func getEndpointVersion(_ endpoint: String) -> SemVer? {
        let key = endpointVersionKey(endpoint)
        if let cached = state.withLock({ $0.parsed[key] }) {
            return cached
        }

        let raw = dataStore?.getItem(key)
        let parsed = raw.flatMap { SemVer($0) }

        if let parsed {
            state.withLock { $0.parsed[key] = .some(parsed) }
        }

        return parsed
    }

    /// Update the known version number for a given endpoint
    public func updateEndpointVersion(_ endpoint: String, _ version: String) {
        let key = endpointVersionKey(endpoint)

        let changed = state.withLock { state in
            guard state.raw[key] != version else { return false }
            state.raw[key] = version
            state.parsed[key] = .some(SemVer(version))
            return true
        }
        if changed {
            dataStore?.setItem(key, version)
        }
    }
}

/// Whether or not the given endpoint belongs to GitHub.com
public func isDotCom(_ ep: String) -> Bool {
    if ep == getDotComAPIEndpoint() {
        return true
    }

    let hostname = hostname(of: ep)
    return hostname == "api.github.com" || hostname == "github.com"
}

public func isGist(_ ep: String) -> Bool {
    let hostname = hostname(of: ep)
    return hostname == "gist.github.com" || hostname == "gist.ghe.io"
}

/// Whether or not the given endpoint URI is under the ghe.com domain
public func isGHE(_ ep: String) -> Bool {
    hostname(of: ep)?.hasSuffix(".ghe.com") ?? false
}

/// Whether or not the given endpoint URI appears to point to a GitHub Enterprise
/// Server instance
public func isGHES(_ ep: String) -> Bool {
    !isDotCom(ep) && !isGHE(ep)
}

private func checkConstraint(_ epConstraint: Bool?, _ epMatchesType: Bool) -> Bool {
    // Denial of endpoint type regardless of version
    // Approval of endpoint type regardless of version
    epConstraint == true && epMatchesType
}

private func checkConstraint(_ epConstraint: EnterpriseServerConstraint?, _ epMatchesType: Bool, _ epVersion: SemVer) -> Bool {
    switch epConstraint {
    case nil, .allowed(false):
        // Denial of endpoint type regardless of version
        return false
    case .allowed(true):
        // Approval of endpoint type regardless of version
        return epMatchesType
    case .range(let range):
        // Version number constraint
        return epMatchesType && epVersion.satisfies(range)
    }
}

/// Returns a predicate which verifies whether a given endpoint matches the
/// provided constraints.
///
/// Note: NOT meant for direct consumption, only exported for testability reasons.
///       Consumers should use the various `supports*` methods instead.
public func endpointSatisfies(
    _ constraint: VersionConstraint,
    getVersion: @escaping @Sendable (String) -> SemVer? = { GitHubRuntime.current.endpointVersions.getEndpointVersion($0) }
) -> @Sendable (String) -> Bool {
    { ep in
        checkConstraint(constraint.dotcom, isDotCom(ep))
            || checkConstraint(constraint.ghe ?? constraint.dotcom, isGHE(ep))
            || checkConstraint(constraint.es, isGHES(ep), getVersion(ep) ?? assumedGHESVersion)
    }
}

private func satisfies(_ constraint: VersionConstraint, _ ep: String, _ runtime: GitHubRuntime) -> Bool {
    endpointSatisfies(constraint, getVersion: runtime.endpointVersions.getEndpointVersion)(ep)
}

/// Whether or not the endpoint supports the internal GitHub Enterprise Server
/// avatars API
public func supportsAvatarsAPI(_ ep: String, runtime: GitHubRuntime = .current) -> Bool {
    satisfies(VersionConstraint(es: ">= 3.0.0"), ep, runtime)
}

public func supportsRerunningChecks(_ ep: String, runtime: GitHubRuntime = .current) -> Bool {
    satisfies(VersionConstraint(dotcom: true, es: ">= 3.4.0"), ep, runtime)
}

public func supportsRerunningIndividualOrFailedChecks(_ ep: String, runtime: GitHubRuntime = .current) -> Bool {
    satisfies(VersionConstraint(dotcom: true), ep, runtime)
}

/// Whether or not the endpoint supports the retrieval of action workflows by
/// check suite id.
public func supportsRetrieveActionWorkflowByCheckSuiteId(_ ep: String, runtime: GitHubRuntime = .current) -> Bool {
    satisfies(VersionConstraint(dotcom: true), ep, runtime)
}

public func supportsRepoRules(_ ep: String, runtime: GitHubRuntime = .current) -> Bool {
    satisfies(VersionConstraint(dotcom: true), ep, runtime)
}
