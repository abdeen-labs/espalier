// Ported from desktop/app/src/lib/group-accounts-by-host.ts

import EspalierSupport

/// The accounts signed in to one host.
public struct AccountHostGroup: Sendable, Equatable, Identifiable {
    /// The host of the accounts' web site, with its port when it isn't the
    /// default: `github.com`, `ghe.example.com:8443`.
    public let host: String
    /// The accounts, in the order they were given.
    public let accounts: [Account]

    public init(host: String, accounts: [Account]) {
        self.host = host
        self.accounts = accounts
    }

    public var id: String {
        host
    }

    /// The group's heading: GitHub.com for GitHub.com's accounts, else the
    /// host.
    public var title: String {
        accounts.first.map(isDotComAccount) == true ? "GitHub.com" : host
    }
}

/// The host an account's web site is on, as `groupAccountsByHost` groups
/// them: lowercased, with a port that isn't the default.
public func accountHost(_ account: Account) -> String {
    ParsedURL(getHTMLURL(account.endpoint)).host ?? account.endpoint
}

/// Groups accounts by the host of their web site. Hosts are sorted
/// alphabetically, and the accounts in each keep their order.
public func groupAccountsByHost(_ accounts: [Account]) -> [AccountHostGroup] {
    var hosts: [String] = []
    var groups: [String: [Account]] = [:]
    for account in accounts {
        let host = accountHost(account)
        if groups[host] == nil {
            hosts.append(host)
        }
        groups[host, default: []].append(account)
    }
    return hosts
        .sorted { JSCompat.compare($0, $1) < 0 }
        .map { AccountHostGroup(host: $0, accounts: groups[$0] ?? []) }
}

/// The accounts as pickers and Settings ▸ Accounts list them: GitHub.com's
/// first, then each GitHub Enterprise host's, alphabetically.
public func groupAccountsForPicker(_ accounts: [Account]) -> [AccountHostGroup] {
    let dotCom = accounts.filter(isDotComAccount)
    let enterprise = groupAccountsByHost(accounts.filter(isEnterpriseAccount))
    return (dotCom.isEmpty ? [] : [AccountHostGroup(host: "github.com", accounts: dotCom)]) + enterprise
}
