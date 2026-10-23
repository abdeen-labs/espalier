import EspalierSupport
import GitHubKit

/// The signed-in GitHub accounts and the repository list, for the
/// credential helper.
///
/// The trampoline is made before the app model, so the app attaches itself
/// once it exists (`attach(to:)`); until then no repository is found.
public final class AccountsTrampolineProvider: TrampolineAccountsProvider {
    private let store: AccountsStore
    private let runtime: GitHubRuntime
    private weak var app: AppModel?

    /// - Parameters:
    ///   - store: The app's accounts.
    ///   - runtime: The GitHub runtime `isGitHubHost` asks with.
    public init(_ store: AccountsStore, runtime: GitHubRuntime) {
        self.store = store
        self.runtime = runtime
    }

    /// Connects the app whose repositories git runs in.
    public func attach(to app: AppModel) {
        self.app = app
    }

    public func getAll() async -> [TrampolineAccount] {
        await store.getAll().map { account in
            TrampolineAccount(endpoint: account.endpoint, login: account.login, token: account.token)
        }
    }

    public func isGitHubHost(_ url: String) async -> Bool? {
        await GitHubKit.isGitHubHost(url, runtime: runtime)
    }

    public func unreadableAccountMessage(endpoint: String, login: String?) async -> String? {
        let (usable, unreadable) = await store.getAllWithUnreadable()
        let account: Account?
        if let login {
            let identity = AccountIdentity(endpoint: endpoint, login: login)
            account = unreadable.first { $0.identity == identity }
        } else if !usable.contains(where: { JSCompat.strictEquals($0.endpoint, endpoint) }) {
            account = unreadable.first { JSCompat.strictEquals($0.endpoint, endpoint) }
        } else {
            account = nil
        }
        return account.flatMap { UnreadableTokenError($0).errorDescription }
    }

    /// The repository at `path`, else the one whose main worktree is there
    /// (git can run in a repository's main worktree while another of its
    /// worktrees is the one listed).
    public func repository(atPath path: String) async -> TrampolineRepository? {
        guard let app else {
            return nil
        }
        if let record = app.matchExistingRepository(path) {
            return TrampolineRepository(record)
        }
        let needle = POSIXPath.normalize(path)
        return app.repositories
            .first { $0.mainWorktreePath.map { JSCompat.strictEquals(POSIXPath.normalize($0), needle) } ?? false }
            .map(TrampolineRepository.init)
    }

    public func associate(_ repository: TrampolineRepository, withEndpoint endpoint: String) async -> TrampolineRepository {
        guard let app, let record = await app.associateRepository(repository.id, withEndpoint: endpoint) else {
            return repository
        }
        return TrampolineRepository(record)
    }

    public func promptForRepositoryAccount(_ repository: TrampolineRepository) async -> TrampolineAccount? {
        guard let account = await app?.ensureRepositoryAccount(repository.id) else {
            return nil
        }
        return TrampolineAccount(endpoint: account.endpoint, login: account.login, token: account.token)
    }
}
