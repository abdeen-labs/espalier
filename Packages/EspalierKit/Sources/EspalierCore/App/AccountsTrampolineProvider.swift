import GitHubKit

/// The signed-in GitHub accounts, for the credential helper.
public final class AccountsTrampolineProvider: TrampolineAccountsProvider {
    private let store: AccountsStore
    private let runtime: GitHubRuntime

    /// - Parameters:
    ///   - store: The app's accounts.
    ///   - runtime: The GitHub runtime `isGitHubHost` asks with.
    public init(_ store: AccountsStore, runtime: GitHubRuntime) {
        self.store = store
        self.runtime = runtime
    }

    public func getAll() async -> [TrampolineAccount] {
        await store.getAll().map { account in
            TrampolineAccount(endpoint: account.endpoint, login: account.login, token: account.token)
        }
    }

    public func isGitHubHost(_ url: String) async -> Bool? {
        await GitHubKit.isGitHubHost(url, runtime: runtime)
    }

    public func unreadableAccountMessage(endpoint: String) async -> String? {
        await store.getAllWithUnreadable().unreadable
            .first { $0.endpoint == endpoint }
            .flatMap { UnreadableTokenError($0).errorDescription }
    }
}
