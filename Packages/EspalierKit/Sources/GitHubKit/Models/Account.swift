// Ported from desktop/app/src/models/account.ts

import EspalierSupport
import Foundation

/// Returns a value indicating whether two account instances
/// can be considered equal. Equality is determined by comparing
/// the two instances' endpoints and user id. This allows
/// us to keep receiving updated Account details from the API
/// while still maintaining the association between repositories
/// and a particular account.
public func accountEquals(_ x: Account, _ y: Account) -> Bool {
    x.endpoint == y.endpoint && x.id == y.id
}

/// Identifies an account by its endpoint and login, without any of its
/// credentials. Several accounts can be signed in to one endpoint, so the
/// endpoint alone doesn't name one.
///
/// Two identities are equal when `getAccountKey` gives them the same key:
/// logins (and endpoints) compare ignoring case, as GitHub's do. The values
/// keep the case they were given, for showing.
public struct AccountIdentity: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The account's API endpoint.
    public let endpoint: String
    /// The account's login.
    public let login: String

    public init(endpoint: String, login: String) {
        self.endpoint = endpoint
        self.login = login
    }

    /// The key the identity compares and hashes by.
    public var key: String {
        getAccountKey(endpoint, login)
    }

    public static func == (lhs: AccountIdentity, rhs: AccountIdentity) -> Bool {
        lhs.key == rhs.key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }

    public var description: String {
        "@\(login) on \(endpoint)"
    }
}

/// A key naming an account by its endpoint and login, ignoring case: the
/// canonical API URL of the user.
public func getAccountKey(_ endpoint: String, _ login: String) -> String {
    JSCompat.toLowerCase("\(endpoint)/users/\(login)")
}

/// Whether `x` and `y` are the same account, by endpoint and login.
public func isSameAccount(_ x: AccountIdentity, _ y: AccountIdentity?) -> Bool {
    y.map { $0 == x } ?? false
}

/// A GitHub account, representing the user found on GitHub The Website or GitHub Enterprise.
///
/// This contains a token that will be used for operations that require authentication.
public struct Account: Sendable, Hashable {
    /// Create an account which can be used to perform unauthenticated API actions
    public static func anonymous() -> Account {
        Account(login: "", endpoint: getDotComAPIEndpoint(), token: "", emails: [], avatarURL: "", id: -1, name: "", plan: "free")
    }

    /// The login name for this account
    public let login: String

    /// The server for this account - GitHub or a GitHub Enterprise instance
    public let endpoint: String

    /// The access token used to perform operations on behalf of this account
    public let token: String

    /// The current list of email addresses associated with the account
    public let emails: [APIEmail]

    /// The profile URL to render for this account
    public let avatarURL: String

    /// The GitHub.com or GitHub Enterprise database id for this account.
    public let id: Int

    /// The friendly name associated with this account
    public let name: String

    /// The plan associated with this account
    public let plan: String?

    /// The client ID of the OAuth app that issued the token. `nil` for
    /// accounts that weren't created by signing in.
    public let clientID: String?

    /// When the access token expires, or `nil` if it doesn't. An expired
    /// token can't be refreshed, because refreshing needs a client secret
    /// that a device-flow app doesn't have, so the user has to sign in again.
    public let tokenExpiresAt: Date?

    public init(
        login: String,
        endpoint: String,
        token: String,
        emails: [APIEmail],
        avatarURL: String,
        id: Int,
        name: String,
        plan: String? = nil,
        clientID: String? = nil,
        tokenExpiresAt: Date? = nil
    ) {
        self.login = login
        self.endpoint = endpoint
        self.token = token
        self.emails = emails
        self.avatarURL = avatarURL
        self.id = id
        self.name = name
        self.plan = plan
        self.clientID = clientID
        self.tokenExpiresAt = tokenExpiresAt
    }

    public func withToken(_ token: String, expiresAt: Date? = nil) -> Account {
        Account(
            login: login,
            endpoint: endpoint,
            token: token,
            emails: emails,
            avatarURL: avatarURL,
            id: id,
            name: name,
            plan: plan,
            clientID: clientID,
            tokenExpiresAt: expiresAt
        )
    }

    /// The same account with a different OAuth client ID.
    public func withClientID(_ clientID: String?) -> Account {
        Account(
            login: login,
            endpoint: endpoint,
            token: token,
            emails: emails,
            avatarURL: avatarURL,
            id: id,
            name: name,
            plan: plan,
            clientID: clientID,
            tokenExpiresAt: tokenExpiresAt
        )
    }

    /// Whether the access token has expired, which means the user has to sign
    /// in again.
    public func isTokenExpired(at date: Date = Date()) -> Bool {
        tokenExpiresAt.map { $0 <= date } ?? false
    }

    /// The credentials git uses for this account.
    public var gitAccount: GitAccount {
        GitAccount(login: login, endpoint: endpoint, token: token)
    }

    /// The account's endpoint and login.
    public var identity: AccountIdentity {
        AccountIdentity(endpoint: endpoint, login: login)
    }

    /// Get a name to display
    ///
    /// This will by default return the 'name' as it is the friendly name.
    /// However, if not defined, we return the login
    public var friendlyName: String {
        name.isEmpty ? login : name
    }

    /// Get a human-friendly description of the Account endpoint.
    ///
    /// Accounts on GitHub.com will return the string 'GitHub.com'
    /// whereas GitHub Enterprise accounts will return the
    /// hostname without the protocol and/or path.
    public var friendlyEndpoint: String {
        isDotComAccount(self) ? "GitHub.com" : (hostname(of: getHTMLURL(endpoint)) ?? endpoint)
    }
}

/// Whether or not the given account is a GitHub.com account as opposed to
/// a GitHub Enteprise account.
public func isDotComAccount(_ account: Account) -> Bool {
    account.endpoint == getDotComAPIEndpoint()
}

/// Whether or not the given account is a GitHub Enterprise account (as opposed to
/// a GitHub.com account)
public func isEnterpriseAccount(_ account: Account) -> Bool {
    !isDotComAccount(account)
}
