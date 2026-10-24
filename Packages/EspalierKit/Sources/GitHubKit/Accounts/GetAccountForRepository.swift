// Ported from desktop/app/src/lib/get-account-for-repository.ts

/// The identity of the account assigned to a repository: its GitHub
/// repository's endpoint and the assigned login. Nil without a GitHub
/// repository or an assigned login.
///
/// The app's repository model lives above GitHubKit, so callers pass the
/// GitHub repository and the login.
public func getRepositoryAccountIdentity(_ gitHubRepository: GitHubRepository?, login: String?) -> AccountIdentity? {
    guard let gitHubRepository, let login else {
        return nil
    }
    return AccountIdentity(endpoint: gitHubRepository.endpoint, login: login)
}

/// The signed-in account assigned to a repository: the one with its GitHub
/// repository's endpoint and the assigned login. Nil when the repository has
/// none, or its account isn't signed in. Another account on the same
/// endpoint is never used in its place.
public func getAccountForRepository(_ accounts: [Account], _ gitHubRepository: GitHubRepository?, login: String?) -> Account? {
    guard let identity = getRepositoryAccountIdentity(gitHubRepository, login: login) else {
        return nil
    }
    return accounts.first { $0.identity == identity }
}
