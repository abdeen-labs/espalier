// Ported from desktop/app/src/lib/find-account.ts

import Foundation

/// Checks whether an account can access the repository `owner/name`.
public typealias RepositoryLookupFunc = @Sendable (_ account: Account, _ owner: String, _ name: String) async -> Bool

/// Check if the repository designated by the owner and name exists and can be
/// accessed by the given account.
private func canAccessRepositoryUsingAPI(
    _ account: Account,
    _ owner: String,
    _ name: String,
    _ runtime: GitHubRuntime
) async -> Bool {
    let api = API.fromAccount(account, runtime: runtime)
    return await api.fetchRepository(owner: owner, name: name) != nil
}

/// Find the GitHub account associated with a given remote URL.
///
/// - Parameters:
///   - urlOrRepositoryAlias: the URL or repository alias whose account
///     should be found
///   - accounts: the list of active GitHub and GitHub Enterprise
///     Server accounts
///   - canAccessRepository: checks whether an account can access a
///     repository; `nil` asks the API.
public func findAccountForRemoteURL(
    _ urlOrRepositoryAlias: String,
    _ accounts: [Account],
    canAccessRepository: RepositoryLookupFunc? = nil,
    runtime: GitHubRuntime = .current
) async -> Account? {
    let canAccessRepository = canAccessRepository ?? { account, owner, name in
        await canAccessRepositoryUsingAPI(account, owner, name, runtime)
    }
    let allAccounts = accounts + [Account.anonymous()]

    // We have a couple of strategies to try to figure out what account we
    // should use to authenticate the URL:
    //
    //  1. Try to parse a remote out of the URL.
    //    1. If that works, try to find an account for that host.
    //    2. If we don't find an account move on to our next strategy.
    //  2. Try to parse an owner/name.
    //    1. If that works, find the first account that can access it.
    //  3. And if all that fails then throw our hands in the air because we
    //     truly don't care.
    if let parsedURL = parseRemote(urlOrRepositoryAlias) {
        let account = allAccounts.first { account in
            let htmlURL = getHTMLURL(account.endpoint)
            return parsedURL.hostname == hostname(of: htmlURL)
        }

        // If we find an account whose hostname matches the URL to be cloned, it's
        // always gonna be our best bet for success. We're not gonna do better.
        if let account {
            return account
        }
    }

    if let repositoryIdentifier = parseRepositoryIdentifier(urlOrRepositoryAlias) {
        let owner = repositoryIdentifier.owner
        let name = repositoryIdentifier.name
        let hostname = repositoryIdentifier.hostname

        // This chunk of code is designed to sort the user's accounts in this order:
        //  - authenticated GitHub account
        //  - GitHub Enterprise accounts
        //  - unauthenticated GitHub account (access public repositories)
        //
        // As this needs to be done efficiently, we consider endpoints not matching
        // `getDotComAPIEndpoint()` to be GitHub Enterprise accounts, and accounts
        // without a token to be unauthenticated.
        //
        // Ranking each account and sorting stably gives this order.
        func rank(_ account: Account) -> Int {
            if isDotComAccount(account) {
                return account.token.isEmpty ? 2 : 0
            }
            return 1
        }
        let sortedAccounts = allAccounts.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)

        for account in sortedAccounts {
            if let hostname {
                let accountHost = GitHubKit.hostname(of: getHTMLURL(account.endpoint))
                if accountHost != hostname {
                    continue
                }
            }

            let canAccess = await canAccessRepository(account, owner, name)
            if canAccess {
                return account
            }
        }
    }

    return nil
}
