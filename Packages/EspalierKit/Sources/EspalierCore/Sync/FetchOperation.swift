import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "fetch")

/// Background and indicator fetches skip a repository fetched more
/// recently than this.
let backgroundFetchMinimumInterval: TimeInterval = 30 * 60

/// The title of the progress after a network operation's git work.
let refreshingRepositoryTitle = "Refreshing Repository"

/// Fetches again.
public struct FetchRetry: RetryableOperation {
    public let repositoryID: RepositoryID

    public init(repositoryID: RepositoryID) {
        self.repositoryID = repositoryID
    }

    public var kind: OperationKind {
        .fetch
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await app.requireRepository(repositoryID, for: kind).sync.fetch()
        return .nothing
    }
}

extension SyncModel {
    // MARK: Intents

    /// Fetches the current remote, the default remote, and a fork's upstream
    /// remote, fast-forwards other branches to their upstreams, and returns
    /// after the repository's refresh.
    ///
    /// A remote that fails doesn't stop the others; the first failure is
    /// thrown after the rest ran, with a Retry that fetches again.
    public func fetch() async throws(OperationError) {
        try await fetch(remotes: nil, kind: .fetch)
    }

    /// Fetches one remote as the user (to find a pull request's branch).
    func fetchRemote(_ remote: Remote) async throws(OperationError) {
        try await fetch(remotes: [remote], kind: .fetch)
    }

    /// Fetches `refspec` from every remote, then refreshes (for pull requests
    /// from forks). It holds the network lane.
    func fetchRefspec(_ refspec: String) async throws(OperationError) {
        guard let repository else {
            throw notInList(.fetchRefspec)
        }
        await refreshGitHubRepositoryIfNeeded()
        let descriptor = OperationDescriptor(kind: .fetchRefspec, lanes: [.network], refreshAfter: .full)
        try await repository.perform(descriptor) { ctx in
            // TODO: we should favour origin here
            let remotes = try await getRemotes(ctx.repository)
            var firstError: (any Error)?
            for remote in remotes {
                do {
                    try await GitKit.fetchRefspec(ctx.repository, remote, refspec)
                } catch {
                    Self.logFailure("Fetching \(refspec) from \(remote.name) failed", error)
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                throw firstError
            }
        }
        await repository.awaitOperationRefresh(covering: .full)
    }

    private func fetch(remotes explicitRemotes: [Remote]?, kind: OperationKind) async throws(OperationError) {
        guard let repository else {
            throw notInList(kind)
        }
        // The issues refresh after a user fetch, whatever its outcome.
        defer { repository.gitHub.userFetchDidComplete() }
        await refreshGitHubRepositoryIfNeeded()
        let tip = repository.gitState.tip
        let record = repository.record
        let descriptor = OperationDescriptor(
            kind: kind,
            lanes: [.network],
            retry: FetchRetry(repositoryID: repository.id),
            refreshAfter: .full,
            showsProgressUntilRefreshed: true
        )
        try await repository.perform(descriptor) { ctx in
            let remotes: [Remote]
            if let explicitRemotes {
                remotes = explicitRemotes
            } else {
                remotes = try await remotesToFetch(ctx.repository, tip: tip, record: record)
            }
            try await fetchAndFastForward(remotes, in: ctx)
        }
        // Branch protection refreshes after fetching, so a new branch reports
        // as protected at once.
        await repository.gitHub.refreshBranchProtection()
        await repository.awaitOperationRefresh(covering: .full)
    }

    // MARK: Background

    /// A background fetch, skipped when a lane it needs is taken: git never
    /// prompts, and failures become the repository's `lastBackgroundFailure`.
    /// The background fetcher decides when
    /// (`shouldBackgroundFetch(lastPush:)`).
    ///
    /// - Returns: Whether it ran.
    func backgroundFetch() async throws(OperationError) -> Bool {
        guard let repository else {
            return false
        }
        await refreshGitHubRepositoryIfNeeded()
        let tip = repository.gitState.tip
        let record = repository.record
        let descriptor = OperationDescriptor(kind: .fetch, lanes: [.network], policy: .background, refreshAfter: .full)
        let ran: Void? = try await repository.performIfIdle(descriptor) { ctx in
            let remotes = try await remotesToFetch(ctx.repository, tip: tip, record: record)
            try await fetchAndFastForward(remotes, in: ctx)
        }
        guard ran != nil else {
            return false
        }
        await repository.gitHub.refreshBranchProtection()
        return true
    }

    /// The fetch the repository indicator updater makes for a repository
    /// that isn't selected, when `shouldBackgroundFetch(lastPush:)` says so:
    /// the bare minimum to know the current branch's ahead/behind. No
    /// fast-forwarding, no refresh, and the repository's
    /// `lastBackgroundFailure` stays as it is.
    ///
    /// Call it after a status pass, which loads the tip it uses.
    func fetchForIndicator(lastPush: Date?) async -> IndicatorFetchResult {
        guard let repository else {
            return .skipped
        }
        guard await shouldBackgroundFetch(lastPush: lastPush) else {
            return .skipped
        }
        await refreshGitHubRepositoryIfNeeded()
        let tip = repository.gitState.tip
        let record = repository.record
        let descriptor = OperationDescriptor(
            kind: .fetch,
            lanes: [.network],
            policy: .background,
            refreshAfter: [],
            updatesBackgroundFailure: false
        )
        do {
            let result = try await repository.performIfIdle(descriptor) { ctx -> AheadBehind? in
                let remotes = try await remotesToFetch(ctx.repository, tip: tip, record: record)
                _ = await fetchRemotes(remotes, repository: ctx.repository, isBackgroundTask: true, progress: ctx.progress)
                return await aheadBehindOfCurrentBranch(ctx.repository, tip: tip)
            }
            guard let result else {
                return .skipped
            }
            return .fetched(result)
        } catch {
            return .skipped
        }
    }

    /// Whether a background fetch should run: always for a repository never
    /// fetched; never within 30 minutes of the last fetch (`FETCH_HEAD`'s
    /// date); otherwise when `lastPush` is unknown or later than the last
    /// fetch.
    func shouldBackgroundFetch(lastPush: Date?) async -> Bool {
        guard let repository else {
            return false
        }
        let lastFetched = await updateLastFetched(repository.record.resolvedGitDir)
        guard let lastFetched else {
            return true
        }

        let timeSinceFetch = repository.environment.scheduler.now.timeIntervalSince(lastFetched)
        let repoName = nameOf(repository.record)
        if timeSinceFetch < backgroundFetchMinimumInterval {
            let timeInSeconds = Int(floor(timeSinceFetch))
            logger.debug("Skipping background fetch as '\(repoName, privacy: .public)' was fetched \(timeInSeconds)s ago")
            return false
        }

        guard let lastPush else {
            return true
        }

        // we should fetch if the last push happened after the last fetch
        if lastFetched < lastPush {
            return true
        }

        logger.debug("Skipping background fetch since nothing has been pushed to '\(repoName, privacy: .public)' since the last fetch at \(lastFetched, privacy: .public)")
        return false
    }

    /// When the repository was last fetched: `FETCH_HEAD`'s date; an empty
    /// `FETCH_HEAD` probably means the fetch failed, so the date known before
    /// stands; no `FETCH_HEAD` means never.
    private func updateLastFetched(_ gitDir: String) async -> Date? {
        switch await fetchHeadState(gitDir) {
        case .fetched(let date):
            lastKnownFetch = date
        case .empty:
            break
        case .missing:
            lastKnownFetch = nil
        }
        return lastKnownFetch
    }
}

// MARK: - Primitives (the network lane is held)

/// The remotes a fetch fetches, in order: the current branch's remote,
/// then the default remote, then a fork's upstream remote, each once.
/// Loaded fresh, so a repository that wasn't refreshed in full (one the
/// indicator updater fetches) fetches the right ones.
func remotesToFetch(_ repository: Repository, tip: Tip, record: RepositoryRecord) async throws -> [Remote] {
    let remotes = try await getRemotes(repository)
    let defaultRemote = findDefaultRemote(remotes)
    let currentRemote = tip.branch?.resolvingRemotes(remotes.map(\.name)).upstreamRemoteName.flatMap { name in
        remotes.first { JSCompat.strictEquals($0.name, name) }
    } ?? defaultRemote
    let upstreamRemote = record.gitHubRepository?.parent.flatMap { findUpstreamRemote($0, remotes) }

    var unique: [Remote] = []
    for remote in [currentRemote, defaultRemote, upstreamRemote].compactMap({ $0 })
        where !unique.contains(where: { JSCompat.strictEquals($0.name, remote.name) }) {
        unique.append(remote)
    }
    return unique
}

/// Fetches `remotes` (0-0.9 of the progress), fast-forwards other branches
/// ("Refreshing Repository", 0.9-0.95), and throws the first remote's
/// failure afterwards.
@MainActor
func fetchAndFastForward(_ remotes: [Remote], in ctx: OperationContext) async throws {
    let fetchWeight = 0.9
    let refreshWeight = 0.1
    let failure = await fetchRemotes(
        remotes,
        repository: ctx.repository,
        isBackgroundTask: ctx.isBackgroundTask,
        progress: ctx.progress.scaled(from: 0, to: fetchWeight)
    )

    ctx.progress.send(.generic(GenericProgress(
        value: fetchWeight,
        title: refreshingRepositoryTitle,
        description: "Fast-forwarding branches"
    )))
    await fastForwardOtherBranches(ctx.repository)
    ctx.progress.send(.generic(GenericProgress(value: fetchWeight + refreshWeight * 0.5, title: refreshingRepositoryTitle)))

    if let failure {
        throw failure
    }
}

/// Fetches `remotes` one after another, each with an equal share of
/// `progress`. A remote that fails doesn't stop the others; after each
/// successful fetch the remote's HEAD is updated, and a failure there is
/// only logged.
///
/// - Returns: The first remote's failure, if any.
func fetchRemotes(
    _ remotes: [Remote],
    repository: Repository,
    isBackgroundTask: Bool,
    progress: ProgressSink
) async -> (any Error)? {
    guard !remotes.isEmpty else {
        return nil
    }
    let weight = 1 / Double(remotes.count)
    var firstFailure: (any Error)?
    for (index, remote) in remotes.enumerated() {
        let sink = progress.scaled(from: Double(index) * weight, to: Double(index + 1) * weight)
        do {
            try await GitKit.fetch(
                repository,
                remote,
                progressCallback: { sink.send(.fetch($0)) },
                isBackgroundTask: isBackgroundTask
            )
        } catch {
            SyncModel.logFailure("Fetching \(remote.name) failed", error)
            if firstFailure == nil {
                firstFailure = error
            }
            // If the fetch failed we shouldn't try to update the remote HEAD
            // because there's a decent chance that it failed either because
            // we didn't have the correct credentials (which we won't this
            // time either) or because there's a network error which likely
            // will persist for the next operation as well.
            continue
        }
        await updateRemoteHEADLoggingFailures(repository, remote, isBackgroundTask: isBackgroundTask)
    }
    return firstFailure
}

/// Updates the remote's HEAD (its default branch). Updating the local HEAD
/// symref isn't critical, so a failure is only logged rather than failing
/// the whole operation.
func updateRemoteHEADLoggingFailures(_ repository: Repository, _ remote: Remote, isBackgroundTask: Bool) async {
    do {
        try await updateRemoteHEAD(repository, remote, isBackgroundTask)
    } catch {
        SyncModel.logFailure("Failed updating remote HEAD", error)
    }
}

/// Fast-forwards every local branch but the current one to its upstream,
/// where it can be. Failures are only logged ("Branch fast-forwarding
/// failed").
///
/// Branches checked out in other worktrees are left out: git refuses to
/// fetch into them, and its refusal ends the whole command (exit 128), so
/// no branch would be fast-forwarded.
func fastForwardOtherBranches(_ repository: Repository) async {
    do {
        let eligible = try await getBranchesDifferingFromUpstream(repository)
        guard !eligible.isEmpty else {
            return
        }
        let checkedOut = ((try? await listWorktrees(repository)) ?? []).compactMap(\.branch).exactSet
        let branches = eligible.filter { !checkedOut.contains(ExactString($0.ref)) }
        try await fastForwardBranches(repository, branches)
    } catch {
        SyncModel.logFailure("Branch fast-forwarding failed", error)
    }
}

/// The current branch's ahead/behind against its upstream after a fetch,
/// nil without an upstream or when the upstream is gone.
func aheadBehindOfCurrentBranch(_ repository: Repository, tip: Tip) async -> AheadBehind? {
    guard case .valid(let branch) = tip, branch.upstreamRemoteName != nil, let upstream = branch.upstream else {
        return nil
    }
    return try? await getAheadBehind(repository, revSymmetricDifference(branch.name, upstream))
}

/// What `FETCH_HEAD` says about the last fetch.
enum FetchHeadState: Sendable, Equatable {
    /// A fetch wrote it at this date.
    case fetched(Date)
    /// It's empty: probably a fetch that failed.
    case empty
    /// There's none: never fetched.
    case missing
}

/// Reads `FETCH_HEAD` in `gitDir`.
@concurrent
func fetchHeadState(_ gitDir: String) async -> FetchHeadState {
    let path = POSIXPath.join(gitDir, "FETCH_HEAD")
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
        return .missing
    }
    guard let size = attributes[.size] as? NSNumber, size.intValue > 0,
          let date = attributes[.modificationDate] as? Date
    else {
        return .empty
    }
    return .fetched(date)
}
