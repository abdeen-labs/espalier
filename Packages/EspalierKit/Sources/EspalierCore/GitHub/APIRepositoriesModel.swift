// Ported from desktop/app/src/lib/stores/api-repositories-store.ts

import EspalierSupport
import Foundation
import GitHubKit
import Observation
import os
import Synchronization

private let logger = Log.logger(category: "api-repositories")

/// Identifies an account across refreshes of its details: its endpoint and
/// user ID.
public struct AccountKey: Hashable, Sendable {
    public let endpoint: String
    public let id: Int

    public init(_ account: Account) {
        endpoint = account.endpoint
        id = account.id
    }
}

/// The repositories the signed-in accounts can clone, for the clone flow.
///
/// `load(_:)` streams an account's list page by page: one request for all
/// repositories, and only when that isn't all of them, the account's own,
/// its collaborations, and its organizations' repositories at once. A
/// refresh keeps the list it had and updates it in place, removing what the
/// server no longer lists once the whole list has loaded. A load that stops
/// at a failed request is marked failed.
@MainActor @Observable
public final class APIRepositoriesModel {
    /// One account's repositories.
    public struct AccountRepositories: Sendable, Equatable {
        /// The repositories, in the order they first arrived.
        public var repositories: [APIRepository]
        /// Whether the list is loading or refreshing.
        public var loading: Bool
        /// Whether the last load stopped at a request that failed, before
        /// the end of the list.
        public var failed: Bool

        public init(repositories: [APIRepository] = [], loading: Bool = false, failed: Bool = false) {
            self.repositories = repositories
            self.loading = loading
            self.failed = failed
        }
    }

    /// The lists, by account. Only signed-in accounts have one.
    public private(set) var state: [AccountKey: AccountRepositories] = [:]

    @ObservationIgnored weak var accounts: AccountsModel?
    @ObservationIgnored private var loads: [AccountKey: Load] = [:]

    private struct Load {
        let id = UUID()
        let task: Task<Void, Never>
    }

    init() {}

    /// The account's repositories, or nil if they were never loaded.
    public func repositories(for account: Account) -> AccountRepositories? {
        state[AccountKey(account)]
    }

    /// Loads, or refreshes, the repositories `account` can clone. Does
    /// nothing while they're loading, or for an account that isn't signed in.
    public func load(_ account: Account) {
        let key = AccountKey(account)
        if state[key]?.loading == true {
            return
        }
        // Use the account as it is now: its token may have changed since
        // the caller got it.
        guard let account = accounts?.accounts.first(where: { accountEquals($0, account) }),
              let environment = accounts?.environment
        else {
            return
        }

        var current = state[key] ?? AccountRepositories()
        current.loading = true
        current.failed = false
        state[key] = current

        let api = API.fromAccount(account, runtime: environment.gitHub)
        let existing = current.repositories
        let load = Load(task: Task { [weak self] in
            await self?.stream(api, into: key, startingWith: existing, environment: environment)
        })
        loads[key] = load
        Task { [weak self] in
            await load.task.value
            self?.loadDidEnd(key, load.id)
        }
    }

    /// Stops loading the account's repositories, keeping those loaded so far.
    public func cancel(_ account: Account) {
        let key = AccountKey(account)
        loads.removeValue(forKey: key)?.task.cancel()
        update(key) { $0.loading = false }
    }

    /// Keeps lists only for the signed-in accounts, across refreshes of their
    /// details; a signed-out account's load stops.
    func accountsDidChange(_ accounts: [Account]) {
        let signedIn = Set(accounts.map(AccountKey.init))
        for key in Array(loads.keys) where !signedIn.contains(key) {
            loads.removeValue(forKey: key)?.task.cancel()
        }
        let kept = state.filter { signedIn.contains($0.key) }
        if kept != state {
            state = kept
        }
    }

    /// Waits for the loads in progress to end.
    func idle() async {
        while let (key, load) = loads.first {
            await load.task.value
            loadDidEnd(key, load.id)
        }
    }

    /// Whether no load is in progress.
    var isIdle: Bool {
        loads.isEmpty
    }

    private func loadDidEnd(_ key: AccountKey, _ id: UUID) {
        if loads[key]?.id == id {
            loads[key] = nil
        }
    }

    // MARK: Streaming

    /// Applies pages as they arrive, and at the end removes the repositories
    /// the server no longer lists, if the whole list loaded: after a page that
    /// failed (errors are swallowed, leaving a partial list), removing them
    /// would drop repositories from the list until the next refresh.
    private func stream(
        _ api: API,
        into key: AccountKey,
        startingWith existing: [APIRepository],
        environment: AppEnvironment
    ) async {
        // The repositories by clone URL, in order; the ones not seen yet.
        var order = existing.map(\.cloneURL)
        var repositories = Dictionary(existing.map { ($0.cloneURL, $0) }, uniquingKeysWith: { _, last in last })
        var missing = Set(order)

        let (pages, continuation) = AsyncStream.makeStream(of: [APIRepository].self)
        let completion = StreamCompletion()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await environment.withRuntimes {
                    await Self.streamUserRepositories(api, into: continuation, completion: completion)
                }
                continuation.finish()
            }

            for await page in pages {
                guard !Task.isCancelled else {
                    break
                }
                for repository in page {
                    if repositories.updateValue(repository, forKey: repository.cloneURL) == nil {
                        order.append(repository.cloneURL)
                    }
                    missing.remove(repository.cloneURL)
                }
                update(key) { $0.repositories = order.compactMap { repositories[$0] } }
            }
            group.cancelAll()
        }

        let isComplete = completion.isComplete && !Task.isCancelled
        if isComplete, !missing.isEmpty {
            order.removeAll { missing.contains($0) }
            update(key) { $0.repositories = order.compactMap { repositories[$0] } }
        }
        if !isComplete {
            logger.info("Loading the repositories of an account on \(key.endpoint, privacy: .public) stopped before the end")
        }
        if !Task.isCancelled {
            update(key) { state in
                state.loading = false
                state.failed = !isComplete
            }
        }
    }

    /// Changes the account's list, if it still has one (a signed-out
    /// account's list is gone).
    private func update(_ key: AccountKey, _ change: (inout AccountRepositories) -> Void) {
        guard var current = state[key] else {
            return
        }
        change(&current)
        if current != state[key] {
            state[key] = current
        }
    }

    /// The request pattern: the first page of all repositories; if there are
    /// more, each affiliation's pages at once instead.
    nonisolated private static func streamUserRepositories(
        _ api: API,
        into continuation: AsyncStream<[APIRepository]>.Continuation,
        completion: StreamCompletion
    ) async {
        let addPage: @Sendable ([APIRepository]) -> Void = { continuation.yield($0) }

        // The vast majority of users have few repositories and no org
        // affiliations. We'll start by making one request to load all
        // repositories available to the user regardless of affiliation and
        // only if that request isn't enough to load all repositories will we
        // divvy up the requests and load repositories by owner and
        // collaborator+org affiliation separately.
        await api.streamUserRepositories(addPage, affiliation: nil, options: FetchAllOptions(
            continue: { _ in
                // If the continue callback is called we know that the first
                // request wasn't enough to load all repositories, so stream
                // each of the three affiliation types concurrently.
                completion.startAffiliations()
                await withTaskGroup(of: Void.self) { group in
                    for affiliation in StreamCompletion.affiliations {
                        group.addTask {
                            await api.streamUserRepositories(addPage, affiliation: affiliation, options: FetchAllOptions(
                                getNextPagePath: completion.nextPagePath(for: affiliation)
                            ))
                        }
                    }
                }

                // Don't load more than one page in the initial stream request.
                return false
            },
            getNextPagePath: completion.nextPagePath(for: nil)
        ))
    }
}

/// Whether every stream of a load reached its last page: a stream that
/// failed (GitHubKit logs and swallows the error) or was cancelled didn't.
private final class StreamCompletion: Sendable {
    static let affiliations: [AffiliationFilter] = [.owner, .collaborator, .organizationMember]

    private struct State {
        var startedAffiliations = false
        /// Streams whose last response had no next page, by affiliation
        /// (`""` for the first request).
        var finished: Set<String> = []
    }

    private let state = Mutex(State())

    func startAffiliations() {
        state.withLock { $0.startedAffiliations = true }
    }

    /// The next page's path, recording when a stream reaches its last page.
    func nextPagePath(for affiliation: AffiliationFilter?) -> @Sendable (HTTPResponse) -> String? {
        { response in
            let next = getNextPagePathFromLink(response)
            if next == nil {
                self.state.withLock { _ = $0.finished.insert(affiliation?.rawValue ?? "") }
            }
            return next
        }
    }

    var isComplete: Bool {
        state.withLock { state in
            if state.startedAffiliations {
                return Self.affiliations.allSatisfy { state.finished.contains($0.rawValue) }
            }
            return state.finished.contains("")
        }
    }
}
