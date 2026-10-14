// Ported from desktop/app/src/lib/email.ts

import Foundation

/// Lookup a suitable email address to display in the application, based on the
/// following rules:
///
///  - the primary email if it's publicly visible
///  - an anonymous (i.e. '@users.noreply.github.com') email address
///  - with a private primary email, an automatically generated stealth
///    email based on the user's login, id, and endpoint
///  - the first verified email address returned from the API
///  - an automatically generated stealth email.
public func lookupPreferredEmail(_ account: Account) -> String {
    let emails = account.emails
    let stealthEmail = getStealthEmailForUser(account.id, account.login, account.endpoint)

    let primary = emails.first(where: \.primary)
    if let primary, isEmailPublic(primary) {
        return primary.email
    }

    let stealthSuffix = "@\(getStealthEmailHostForEndpoint(account.endpoint))"
    if let noReply = emails.first(where: { $0.email.lowercased().hasSuffix(stealthSuffix) }) {
        return noReply.email
    }

    if primary != nil {
        return stealthEmail
    }

    return emails.first(where: \.verified)?.email ?? stealthEmail
}

/// Is the email public?
private func isEmailPublic(_ email: APIEmail) -> Bool {
    // If an email doesn't have a visibility setting it means it's coming from an
    // older Enterprise version which doesn't have the concept of visibility.
    email.visibility == .public || email.visibility == nil
}

/// Returns the stealth email host name for a given endpoint. The stealth
/// email host is hardcoded to the subdomain users.noreply under the
/// endpoint host.
private func getStealthEmailHostForEndpoint(_ endpoint: String) -> String {
    isGHES(endpoint)
        ? "users.noreply.\(hostname(of: endpoint) ?? "")"
        : "users.noreply.github.com"
}

/// Generate a legacy stealth email address for the user
/// on the given server.
///
/// Ex: desktop@users.noreply.github.com
///
/// - Parameters:
///   - login: The user handle or "login"
///   - endpoint: The API endpoint that this login belongs to,
///     either GitHub.com or a GitHub Enterprise instance
public func getLegacyStealthEmailForUser(_ login: String, _ endpoint: String) -> String {
    let stealthEmailHost = getStealthEmailHostForEndpoint(endpoint)
    return "\(login)@\(stealthEmailHost)"
}

/// Generate a stealth email address for the account. Convenience method
/// for getStealthEmailForUser that takes an Account object instead of
/// individual parameters.
///
/// Ex: 123456+desktop@users.noreply.github.com
public func getStealthEmailForAccount(_ account: Account) -> String {
    getStealthEmailForUser(account.id, account.login, account.endpoint)
}

/// Generate a stealth email address for the user on the given
/// server.
///
/// Ex: 123456+desktop@users.noreply.github.com
///
/// - Parameters:
///   - id: The numeric user id as returned by the endpoint
///     API. See getLegacyStealthEmailFor if no user id
///     is available.
///   - login: The user handle or "login"
///   - endpoint: The API endpoint that this login belongs to,
///     either GitHub.com or a GitHub Enterprise instance
public func getStealthEmailForUser(_ id: Int, _ login: String, _ endpoint: String) -> String {
    let stealthEmailHost = getStealthEmailHostForEndpoint(endpoint)
    return "\(id)+\(login)@\(stealthEmailHost)"
}

/// Gets a value indicating whether a commit email matching the given email would
/// get attributed to the account (i.e. user) if pushed to the endpoint that said
/// account belongs to.
///
/// When determining if an email is attributable to an account we consider a list
/// of email addresses consisting of all the email addresses we get from the API
/// (since this is for the currently signed in user we get public as well as
/// private email addresses here) as well as the legacy and modern format of the
/// anonymous email addresses, for example:
///
///  desktop@users.noreply.github.com
///  13171334+desktop@users.noreply.github.com
public func isAttributableEmailFor(_ account: Account, _ email: String) -> Bool {
    let needle = email.lowercased()

    return account.emails.contains { $0.verified && $0.email.lowercased() == needle }
        || getStealthEmailForUser(account.id, account.login, account.endpoint).lowercased() == needle
        || getLegacyStealthEmailForUser(account.login, account.endpoint).lowercased() == needle
}

/// A regular expression meant to match both the legacy format GitHub.com
/// stealth email address and the modern format (login@ vs id+login@).
///
/// Yields two capture groups, the first being an optional capture of the
/// user id and the second being the mandatory login.
nonisolated(unsafe) private let stealthEmailRegexp = /^(?:(\d+)\+)?(.+?)@(users\.noreply\..+)$/.ignoresCase()

/// Parses a stealth email address into the user id (for the modern format) and
/// login, or `nil` if it isn't a stealth address on the endpoint's host.
public func parseStealthEmail(_ email: String, _ endpoint: String) -> (id: Int?, login: String)? {
    let stealthEmailHost = getStealthEmailHostForEndpoint(endpoint)
    guard let match = email.firstMatch(of: stealthEmailRegexp), stealthEmailHost == String(match.output.3) else {
        return nil
    }

    let id = match.output.1.flatMap { parseInt(String($0)) }
    return (id: id, login: String(match.output.2))
}
