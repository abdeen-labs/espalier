// Ported from desktop/app/src/lib/get-account-for-repository.ts

/// Get the authenticated account for the repository.
///
/// The app's repository model lives above GitHubKit, so callers pass the
/// GitHub repository.
public func getAccountForRepository(_ accounts: [Account], _ gitHubRepository: GitHubRepository?) -> Account? {
    guard let gitHubRepository else {
        return nil
    }

    return getAccountForEndpoint(accounts, gitHubRepository.endpoint)
}
