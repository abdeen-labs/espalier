// Sign-in is `SignInModel`, the repositories to clone `APIRepositoriesModel`.

import EspalierSupport
import Foundation
import GitHubKit
import Observation
import os

private let logger = Log.logger(category: "accounts")

/// A problem with the stored accounts: a token that couldn't be read or
/// removed, a keychain failure.
public struct AccountsIssue: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let message: String

    public init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}

/// The signed-in GitHub accounts, one per server.
///
/// Mirrors GitHubKit's `AccountsStore`: it loads the accounts at launch,
/// refreshes their details from GitHub at launch and then at most once a
/// day when Espalier becomes active, and follows the store's events, so an
/// account GitHub rejects (a 401 from GitHub itself), or whose token expired
/// or is missing from the keychain, is signed out and listed in
/// `invalidatedAccounts` for the user to sign in again.
@MainActor @Observable
public final class AccountsModel {
    /// The accounts, GitHub.com first, then the others in the order they
    /// were added; one per endpoint.
    public private(set) var accounts: [Account] = []
    /// Accounts signed out because GitHub rejected their tokens, or the
    /// tokens expired or are missing, without tokens, until the user signs
    /// in to their servers again or dismisses them.
    public internal(set) var invalidatedAccounts: [Account] = []
    /// Accounts whose tokens the keychain refused to read (it's locked, or
    /// access was denied), without tokens. They stay saved but aren't used
    /// until `retryUnreadableAccounts()` reads their tokens.
    public private(set) var unreadableAccounts: [Account] = []
    /// Problems with the stored accounts, to tell the user about.
    public private(set) var issues: [AccountsIssue] = []
    /// When the accounts' details were last refreshed from GitHub.
    public private(set) var lastRefreshed: Date?

    /// Signing in.
    public let signIn: SignInModel
    /// The repositories each account can clone.
    public let apiRepositories: APIRepositoriesModel

    /// How often the accounts' details are refreshed: when Espalier becomes
    /// active and the last refresh is older than this, so the emails that
    /// recognize the user's commits don't go stale in long sessions.
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    @ObservationIgnored let store: AccountsStore
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var isFollowingStore = false
    @ObservationIgnored private var isObservingActivation = false
    @ObservationIgnored private var runningWork = 0
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(store: AccountsStore) {
        self.store = store
        signIn = SignInModel()
        apiRepositories = APIRepositoriesModel()
        signIn.accounts = self
        apiRepositories.accounts = self
    }

    /// Connects the model to the app that owns it.
    func attach(to app: AppModel) {
        self.app = app
    }

    /// The environment of the app that owns the model.
    var environment: AppEnvironment? {
        app?.environment
    }

    /// The account for a repository's GitHub endpoint, if one is signed in.
    public func account(for record: RepositoryRecord) -> Account? {
        getAccountForRepository(accounts, record.gitHubRepository)
    }

    /// The account signed in to `endpoint` (an API endpoint), if any.
    public func account(forEndpoint endpoint: String) -> Account? {
        getAccountForEndpoint(accounts, endpoint)
    }

    /// Signs out `account`: removes it and its token from the keychain. The
    /// token can't be revoked from here (that needs a client secret);
    /// `GitHubWebURLs.applicationSettings(for:)` is the page where the user
    /// can. Cached API responses go too, since they can hold the account's
    /// private data.
    ///
    /// - Throws: When the keychain refuses to remove the token; the account
    ///   stays signed in.
    public func signOut(_ account: Account) async throws(OperationError) {
        logger.info("Signing out \(account.login, privacy: .public) from \(account.endpoint, privacy: .public)")
        do {
            try await store.removeAccount(account)
        } catch {
            throw OperationError(.other(Self.message(for: error)), operation: .signOut, underlying: error)
        }
        _ = await deleteToken(account)
        environment?.gitHub.session.configuration.urlCache?.removeAllCachedResponses()
        await reloadAccounts()
    }

    /// Refreshes every account's details from GitHub
    /// (`AccountsStore.refresh`), signing out accounts whose tokens expired.
    /// An account that can't be refreshed keeps its details.
    public func refresh() async {
        await track {
            await self.store.refresh()
            self.lastRefreshed = self.environment?.scheduler.now
            await self.reloadAccounts()
        }
    }

    /// Reads the tokens of `unreadableAccounts` from the keychain again; an
    /// account whose token reads is signed in again.
    public func retryUnreadableAccounts() async {
        await track {
            await self.store.retryUnreadableAccounts()
            await self.reloadAccounts()
        }
    }

    /// Forgets a signed-out account the user doesn't want to sign in to
    /// again.
    public func dismissInvalidatedAccount(_ account: Account) {
        invalidatedAccounts.removeAll { accountEquals($0, account) }
    }

    /// Forgets an issue once the user has seen it.
    public func dismissIssue(_ id: AccountsIssue.ID) {
        issues.removeAll { $0.id == id }
    }

    // MARK: Launch

    /// Takes the accounts the store loaded at launch, and from then on
    /// follows the store and the app's activation.
    func load(_ accounts: [Account], unreadable: [Account]) {
        if accounts != self.accounts {
            self.accounts = accounts
            apiRepositories.accountsDidChange(accounts)
        }
        if unreadable != unreadableAccounts {
            unreadableAccounts = unreadable
        }
        followStore()
        observeActivation()
    }

    /// Launch work: refreshes the accounts from the API, without waiting for
    /// it.
    func applicationDidLaunch() {
        startTracked {
            await self.refresh()
        }
    }

    /// Waits until no refresh of the accounts or of an association, and no
    /// load of repositories to clone, is running.
    func idle() async {
        while !isIdle {
            if runningWork > 0 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    idleWaiters.append(continuation)
                }
            }
            await apiRepositories.idle()
        }
    }

    /// Whether `idle()` would return at once.
    var isIdle: Bool {
        runningWork == 0 && apiRepositories.isIdle
    }

    // MARK: The store

    /// Reads the accounts from the store and applies them if they changed.
    ///
    /// The list is always read again rather than taken from an event (whose
    /// list may be older than one already applied): each read resumes on the
    /// main actor in the order the store's actor ran it, so the list applied
    /// last is the one read last.
    func reloadAccounts() async {
        let (loaded, unreadable) = await store.getAllWithUnreadable()
        if unreadable != unreadableAccounts {
            unreadableAccounts = unreadable
        }
        guard loaded != accounts else {
            return
        }
        let previous = accounts
        accounts = loaded
        accountsDidChange(from: previous)
    }

    /// Stores a newly signed-in account, replacing the endpoint's account.
    func add(_ account: Account) async throws(SignInError) {
        do {
            try await store.addAccount(account)
        } catch {
            logger.error("Could not store the account for \(account.endpoint, privacy: .public): \(Self.message(for: error), privacy: .public)")
            throw .tokenNotStored(Self.message(for: error))
        }
        await reloadAccounts()
    }

    /// A sign-in succeeded: in the welcome flow, start loading the account's
    /// repositories to clone.
    func signInDidSucceed(_ account: Account) {
        invalidatedAccounts.removeAll { $0.endpoint == account.endpoint }
        if let app, !app.preferences.hasShownWelcomeFlow {
            apiRepositories.load(account)
        }
    }

    private func accountsDidChange(from previous: [Account]) {
        apiRepositories.accountsDidChange(accounts)

        // An account signed in again replaces its signed-out entry.
        invalidatedAccounts.removeAll { invalidated in
            accounts.contains { $0.endpoint == invalidated.endpoint }
        }

        // Signing in or out, or a new token, can change which repositories
        // match an account and what they're allowed to do; new details don't.
        let signedIn = Set(accounts.map(SignedInAccount.init))
        guard signedIn != Set(previous.map(SignedInAccount.init)), let app, app.loadState == .ready else {
            return
        }
        app.background.update()
        startTracked {
            await app.refreshSelectedRepositoryAfterAccountChange()
        }
    }

    /// An account and its token, to tell a sign-in or sign-out from a
    /// refresh of the account's details.
    private struct SignedInAccount: Hashable {
        let endpoint: String
        let id: Int
        let token: String

        init(_ account: Account) {
            endpoint = account.endpoint
            id = account.id
            token = account.token
        }
    }

    /// Follows the store's events: updates, errors, and accounts signed out
    /// because their tokens were rejected, expired, or are missing.
    ///
    /// The store's event stream has one reader for the life of the app;
    /// when the model goes away the stream ends.
    private func followStore() {
        guard !isFollowingStore else {
            return
        }
        isFollowingStore = true
        let events = store.events
        Task { [weak self] in
            for await event in events {
                guard let self else {
                    return
                }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: AccountsStore.Event) async {
        switch event {
        case .didUpdate:
            await reloadAccounts()
        case .didError(let error):
            let message = Self.message(for: error)
            logger.error("Accounts store error: \(message, privacy: .public)")
            issues.append(AccountsIssue(message: message))
        case .tokenInvalidated(let account):
            logger.info("GitHub rejected the token of \(account.login, privacy: .public) on \(account.endpoint, privacy: .public); signed out")
            markInvalidated(account)
            await reloadAccounts()
        case .tokenExpired(let account):
            logger.info("The token of \(account.login, privacy: .public) on \(account.endpoint, privacy: .public) expired; signed out")
            markInvalidated(account)
            await reloadAccounts()
        case .tokenMissing(let account):
            logger.info("The token of \(account.login, privacy: .public) on \(account.endpoint, privacy: .public) is missing; signed out")
            markInvalidated(account)
            await reloadAccounts()
        }
    }

    private func markInvalidated(_ account: Account) {
        invalidatedAccounts.removeAll { $0.endpoint == account.endpoint }
        invalidatedAccounts.append(account.token.isEmpty ? account : account.withToken(""))
    }

    // MARK: Activation

    /// Refreshes when Espalier becomes active: signs out accounts whose
    /// tokens expired meanwhile, and refreshes the details once a day.
    private func observeActivation() {
        guard let app, !isObservingActivation else {
            return
        }
        isObservingActivation = true
        observeActivation(of: app)
    }

    private func observeActivation(of app: AppModel) {
        withObservationTracking {
            _ = app.isActive
        } onChange: { [weak self, weak app] in
            Task { @MainActor [weak self, weak app] in
                guard let self, let app else {
                    return
                }
                if app.isActive {
                    self.applicationDidBecomeActive()
                }
                self.observeActivation(of: app)
            }
        }
    }

    func applicationDidBecomeActive() {
        startTracked {
            if !(await self.store.signOutExpiredAccounts()).isEmpty {
                await self.reloadAccounts()
            }
            guard let now = self.environment?.scheduler.now, let last = self.lastRefreshed,
                  now.timeIntervalSince(last) >= Self.refreshInterval
            else {
                return
            }
            await self.refresh()
        }
    }

    // MARK: Helpers

    /// Runs `work`, counting it for `idle()`.
    func track(_ work: () async -> Void) async {
        runningWork += 1
        await work()
        workDidEnd()
    }

    /// Starts `work` in a task of its own, counted for `idle()` from now.
    private func startTracked(_ work: @escaping @MainActor () async -> Void) {
        runningWork += 1
        Task {
            await work()
            self.workDidEnd()
        }
    }

    private func workDidEnd() {
        runningWork -= 1
        if runningWork == 0, !idleWaiters.isEmpty {
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// The message for an error from the store or the keychain (never a
    /// token: the store's errors don't contain any).
    static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
