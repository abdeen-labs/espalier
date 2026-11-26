// The intents behind Home's buttons, for any repository in the list and any
// of its worktrees, selected or not: pushing a worktree's branch, Push All,
// and Fetch All. Cleaning up a merged branch is in WorkCleanUp.swift.

import EspalierSupport
import Foundation
import GitKit
import os
import Synchronization

private let logger = Log.logger(category: "work")

/// How many repositories a batch works in at once.
let batchConcurrency = 3

// MARK: - Values

/// One branch Push All pushes, as its confirmation lists it.
public struct BranchPush: Sendable, Equatable {
    public let worktree: WorktreeKey
    /// The repository's name, as the list shows it.
    public let repository: String
    /// The branch's name.
    public let branch: String
    /// The commits the branch has that its upstream doesn't; nil when its
    /// remote-tracking branch is gone.
    public let commits: Int?

    public init(worktree: WorktreeKey, repository: String, branch: String, commits: Int?) {
        self.worktree = worktree
        self.repository = repository
        self.branch = branch
        self.commits = commits
    }

    /// The line the confirmation's list shows: "espalier: feature (3
    /// commits)".
    public var listLine: String {
        switch commits {
        case nil: "\(repository): \(branch)"
        case 1?: "\(repository): \(branch) (1 commit)"
        case let count?: "\(repository): \(branch) (\(count) commits)"
        }
    }
}

/// Why Push All didn't push a worktree's branch, without its push failing.
public enum PushSkipReason: Sendable, Equatable {
    /// The branch tracks no remote branch: it's published, not pushed.
    case notPublished
    /// The branch has nothing its upstream doesn't.
    case upToDate
    /// The upstream has commits the branch doesn't: pull first.
    case needsPull
    /// Another operation the user started runs in the repository.
    case busy(OperationKind)
    /// The push needs the user partway: signing in, a failed hook, push
    /// protection, a fork. The error says what, with its recoveries; it
    /// wasn't answered for the user.
    case needsUser(OperationError)
    /// Push All was cancelled before this push ran.
    case cancelled
}

/// What Push All did, one item per worktree, in the order given.
public struct PushAllResult: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let worktree: WorktreeKey
        /// The worktree's branch, when it's on one.
        public let branch: String?
        public let outcome: Outcome

        public init(worktree: WorktreeKey, branch: String?, outcome: Outcome) {
            self.worktree = worktree
            self.branch = branch
            self.outcome = outcome
        }
    }

    public enum Outcome: Sendable, Equatable {
        case pushed(PushOutcome)
        case skipped(PushSkipReason)
        case failed(OperationError)
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}

/// Where Fetch All is: how many of its repositories are done.
public struct FetchAllProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}

/// What Fetch All did, one item per repository it fetched, in the list's
/// order.
public struct FetchAllResult: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let repositoryID: RepositoryID
        public let outcome: Outcome

        public init(repositoryID: RepositoryID, outcome: Outcome) {
            self.repositoryID = repositoryID
            self.outcome = outcome
        }
    }

    public enum Outcome: Sendable, Equatable {
        case fetched
        /// The fetch failed, without asking the user anything (offline,
        /// signed out).
        case failed(OperationError)
        /// Fetch All was cancelled before this fetch finished.
        case cancelled
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// The fetches that failed.
    public var failures: [(repositoryID: RepositoryID, error: OperationError)] {
        items.compactMap { item in
            if case .failed(let error) = item.outcome {
                return (item.repositoryID, error)
            }
            return nil
        }
    }
}

/// Pushes a worktree's branch again (`AppModel.pushWork(_:)`).
public struct PushWorkRetry: RetryableOperation {
    public let worktree: WorktreeKey

    public init(worktree: WorktreeKey) {
        self.worktree = worktree
    }

    public var kind: OperationKind {
        .push
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        .push(try await app.pushWork(worktree), repositoryID: worktree.repositoryID)
    }
}

extension Confirmation {
    /// Push All: the branches it pushes, listed in `details`
    /// (`BranchPush.listLine`) after the message.
    public static func pushAll(_ pushes: [BranchPush]) -> Confirmation {
        let one = pushes.count == 1
        return Confirmation(
            kind: .pushAll,
            details: .pushes(pushes),
            title: one ? "Push 1 Branch?" : "Push \(pushes.count) Branches?",
            message: one
                ? "This branch will be pushed to its upstream branch:"
                : "These branches will be pushed to their upstream branches:",
            confirmButton: one ? "Push Branch" : "Push \(pushes.count) Branches"
        )
    }
}

// MARK: - Intents

extension AppModel {
    /// Pushes the branch checked out in `worktree` to its upstream, in any
    /// repository in the list, selected or not, from any of its worktrees.
    /// The record keeps pointing where it does, and no working tree changes.
    ///
    /// Everything `SyncModel.push` honors applies: the `pre-push` hook (a
    /// failure asks), credentials through the usual prompts, the queued
    /// tags, the remotes a push also goes to, the fetch and fast-forwards
    /// afterwards, and the classified errors (a rejected push offers Fetch,
    /// push protection offers Bypass). Git runs in the worktree's folder.
    /// Returns after the repository's refresh.
    ///
    /// - Throws: A precondition for a repository that's missing, a folder
    ///   that isn't one of the repository's worktrees or is gone, a detached
    ///   HEAD, a branch without commits, and a branch that tracks no remote
    ///   branch (publishing isn't done here); the push's errors, with a
    ///   Retry that pushes the worktree again.
    @discardableResult
    public func pushWork(_ worktree: WorktreeKey) async throws(OperationError) -> PushOutcome {
        let model = try usableRepository(worktree.repositoryID, for: .push)
        switch try await model.sync.pushWorktree(worktree, inBatch: false) {
        case .pushed(let outcome):
            return outcome
        case .refused(let refusal):
            throw OperationError(.precondition(refusal.message), operation: .push, repositoryID: model.id)
        case .behind, .upToDate:
            // Only a batch checks these first.
            throw OperationError(.precondition("Nothing was pushed."), operation: .push, repositoryID: model.id)
        }
    }

    /// Pushes the branch of each of `worktrees` as `pushWork(_:)` does,
    /// after one confirmation.
    ///
    /// 1. Each worktree's branch is looked at first: one that tracks no
    ///    remote branch, has nothing to push, or is behind its upstream is
    ///    skipped (`notPublished`, `upToDate`, `needsPull`), and one that
    ///    can't be pushed (a detached HEAD, a missing folder) fails, without
    ///    asking.
    /// 2. Unless `confirmed` has `.pushAll`, asks:
    ///    `confirmationRequired(.pushAll)` naming the rest, with their
    ///    commit counts. Nothing to push asks nothing.
    /// 3. Pushes them, `batchConcurrency` repositories at a time, never two
    ///    at once in one repository (worktrees of one repository share it),
    ///    each looked at again in its lane first. One failing doesn't stop
    ///    the others. Git asks nothing: a push that needs the user partway
    ///    (signing in, a failed hook, which aborts, push protection) is
    ///    skipped as `needsUser` with its error, and one a remote rejected
    ///    for commits it has as `needsPull`. Cancelling the task skips the
    ///    pushes that haven't started.
    ///
    /// Each repository refreshes after its push.
    ///
    /// - Returns: Each worktree's outcome, in the order given (a worktree
    ///   given twice, once).
    /// - Throws: Only the confirmation.
    public func pushAll(_ worktrees: [WorktreeKey], confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> PushAllResult {
        var keys: [WorktreeKey] = []
        for key in worktrees where !keys.contains(key) {
            keys.append(key)
        }

        // 1. What each would push.
        var outcomes: [WorktreeKey: PushAllResult.Outcome] = [:]
        var branches: [WorktreeKey: String] = [:]
        var pushes: [BranchPush] = []
        for key in keys {
            let model: RepositoryModel
            do {
                model = try usableRepository(key.repositoryID, for: .push)
            } catch {
                outcomes[key] = .failed(error)
                continue
            }
            let listing = model.gitRepository
            let loaded: Result<WorkPushTarget, WorkPushRefusal>
            do {
                loaded = try await environment.withRuntimes {
                    try await loadWorkPushTarget(path: key.path, listedFrom: listing)
                }
            } catch {
                outcomes[key] = .failed(await classify(error, kind: .push, in: model))
                continue
            }
            switch loaded {
            case .failure(.noUpstream(let branch)):
                branches[key] = branch
                outcomes[key] = .skipped(.notPublished)
            case .failure(let refusal):
                branches[key] = refusal.branch
                outcomes[key] = .failed(OperationError(.precondition(refusal.message), operation: .push, repositoryID: model.id))
            case .success(let target):
                branches[key] = target.branch.name
                if let skip = target.batchSkip {
                    outcomes[key] = .skipped(skip)
                } else {
                    pushes.append(BranchPush(
                        worktree: key,
                        repository: model.record.displayName,
                        branch: target.branch.name,
                        commits: target.aheadBehind?.ahead
                    ))
                }
            }
        }

        // 2. The confirmation.
        if !pushes.isEmpty, !confirmed.contains(.pushAll) {
            throw OperationError(.confirmationRequired(.pushAll(pushes)), operation: .push)
        }

        // 3. The pushes, by repository.
        let groups = await batchGroups(pushes.map(\.worktree.repositoryID))
        let results = await runBatch(groups.map { group in group.map { pushes[$0] } }) { push -> PushAllResult.Outcome in
            await self.pushInBatch(push.worktree)
        }
        for (push, outcome) in results {
            outcomes[push.worktree] = outcome
        }

        return PushAllResult(items: keys.map { key in
            PushAllResult.Item(worktree: key, branch: branches[key], outcome: outcomes[key] ?? .skipped(.cancelled))
        })
    }

    /// Fetches every repository in the list that's usable (not missing or
    /// untrusted), `batchConcurrency` at a time, never two at once that are
    /// worktrees of one repository. Each runs the repository's own fetch
    /// (`SyncModel.fetch()`: its remotes, fast-forwarding, the last-fetched
    /// time, its refresh), except that git asks nothing: a repository that's
    /// offline or needs signing in fails quietly into the result.
    ///
    /// `onProgress` hears "N of M" before the first starts and after each
    /// finishes. Cancelling the task stops the fetches running (as their
    /// Stop does) and starts no more; those are `cancelled`.
    public func fetchAll(onProgress: (@MainActor @Sendable (FetchAllProgress) -> Void)? = nil) async -> FetchAllResult {
        let ids = repositories.map(\.id).filter { id in
            (try? usableRepository(id, for: .fetch)) != nil
        }
        let total = ids.count
        let counter = BatchCounter()
        onProgress?(FetchAllProgress(completed: 0, total: total))
        let stops = BatchStops()
        let groups = await batchGroups(ids)
        let results = await withTaskCancellationHandler {
            await runBatch(groups.map { group in group.map { ids[$0] } }) { id -> FetchAllResult.Outcome in
                let outcome = await self.fetchInBatch(id, stops: stops)
                counter.count += 1
                onProgress?(FetchAllProgress(completed: counter.count, total: total))
                return outcome
            }
        } onCancel: {
            stops.stopAll()
        }
        var outcomes: [RepositoryID: FetchAllResult.Outcome] = [:]
        for (id, outcome) in results {
            outcomes[id] = outcome
        }
        return FetchAllResult(items: ids.map { id in
            FetchAllResult.Item(repositoryID: id, outcome: outcomes[id] ?? .cancelled)
        })
    }

    // MARK: Helpers

    /// The model of a repository in the list that git can work in.
    ///
    /// - Throws: A precondition when it's no longer in the list or its
    ///   folder is gone; `unsafeRepository` when another user owns it.
    func usableRepository(_ id: RepositoryID, for kind: OperationKind) throws(OperationError) -> RepositoryModel {
        let model = try requireRepository(id, for: kind)
        if case .unsafe(let path) = model.availability {
            throw OperationError(.unsafeRepository(path: path), operation: kind, repositoryID: id)
        }
        if model.record.isMissing || model.availability == .missing {
            throw OperationError(
                .precondition("Espalier can't find \(model.record.displayName) on this Mac."),
                operation: kind,
                repositoryID: id
            )
        }
        return model
    }

    /// `error`, from git work outside an operation, as an operation's.
    private func classify(_ error: any Error, kind: OperationKind, in model: RepositoryModel) async -> OperationError {
        if let error = error as? OperationError {
            return error
        }
        return await ErrorClassifier.classify(
            error,
            descriptor: OperationDescriptor(kind: kind, lanes: []),
            record: model.record,
            context: ClassificationContext()
        )
    }

    /// One push of Push All, as its item's outcome.
    private func pushInBatch(_ key: WorktreeKey) async -> PushAllResult.Outcome {
        if Task.isCancelled {
            return .skipped(.cancelled)
        }
        do {
            let model = try usableRepository(key.repositoryID, for: .push)
            switch try await model.sync.pushWorktree(key, inBatch: true) {
            case .pushed(let outcome):
                return .pushed(outcome)
            case .refused(.noUpstream):
                return .skipped(.notPublished)
            case .refused(let refusal):
                return .failed(OperationError(.precondition(refusal.message), operation: .push, repositoryID: model.id))
            case .behind:
                return .skipped(.needsPull)
            case .upToDate:
                return .skipped(.upToDate)
            }
        } catch {
            return Self.batchOutcome(of: error)
        }
    }

    /// A push of Push All that failed, as its item's outcome: what needs the
    /// user is skipped, not failed.
    nonisolated static func batchOutcome(of error: OperationError) -> PushAllResult.Outcome {
        switch error.reason {
        case .busy(let kind):
            return .skipped(.busy(kind))
        case .cancelled(.hookAborted):
            return .skipped(.needsUser(error))
        case .cancelled:
            return .skipped(.cancelled)
        case .pushRejectedNonFastForward:
            return .skipped(.needsPull)
        case .authenticationFailed, .confirmationRequired, .decisionRequired, .pushProtectionBlocked,
             .workflowScopeRequired, .samlReauthorizationRequired, .insufficientPermissions:
            return .skipped(.needsUser(error))
        default:
            return .failed(error)
        }
    }

    /// One fetch of Fetch All, as its item's outcome.
    private func fetchInBatch(_ id: RepositoryID, stops: BatchStops) async -> FetchAllResult.Outcome {
        if Task.isCancelled || stops.isStopped {
            return .cancelled
        }
        do {
            let model = try usableRepository(id, for: .fetch)
            try await model.sync.fetchWithoutPrompts { stop in
                stops.add(stop)
            }
            return .fetched
        } catch {
            if error.isCancellation {
                return .cancelled
            }
            logger.info("A repository's fetch failed in Fetch All")
            return .failed(error)
        }
    }

    /// The indices of `ids` grouped by the repository they're worktrees of
    /// (their common git directory), in order: a batch runs one group's
    /// items one after another.
    func batchGroups(_ ids: [RepositoryID]) async -> [[Int]] {
        var keys: [String: Int] = [:]
        var groups: [[Int]] = []
        for (index, id) in ids.enumerated() {
            let key = await batchKey(id)
            if let group = keys[key] {
                groups[group].append(index)
            } else {
                keys[key] = groups.count
                groups.append([index])
            }
        }
        return groups
    }

    /// The common git directory of repository `id`: the one its last
    /// refresh resolved, or else resolved now; its ID when git can't tell.
    private func batchKey(_ id: RepositoryID) async -> String {
        guard let model = repository(id) else {
            return id.description
        }
        if let paths = model.watchedPaths {
            return paths.commonDirectory
        }
        let path = model.record.path
        return await environment.withRuntimes { await resolveWatchedPaths(path) }?.commonDirectory ?? id.description
    }

    /// Runs `work` on each item of `groups`: at most `batchConcurrency`
    /// groups at once, each group's items one after another, in order.
    ///
    /// - Returns: Each item with what `work` returned, in no order.
    func runBatch<Item: Sendable, Output: Sendable>(
        _ groups: [[Item]],
        _ work: @escaping @MainActor @Sendable (Item) async -> Output
    ) async -> [(Item, Output)] {
        let results = BatchResults<Item, Output>()
        await withTaskGroup(of: Void.self) { taskGroup in
            var pending = groups[...]
            for _ in 0..<min(batchConcurrency, groups.count) {
                let group = pending.removeFirst()
                taskGroup.addTask { await results.run(group, work) }
            }
            while await taskGroup.next() != nil {
                if let group = pending.popFirst() {
                    taskGroup.addTask { await results.run(group, work) }
                }
            }
        }
        return results.items
    }
}

/// What a batch's work returned, collected on the main actor.
@MainActor
private final class BatchResults<Item: Sendable, Output: Sendable>: Sendable {
    var items: [(Item, Output)] = []

    nonisolated init() {}

    /// Runs `work` on each of `group`, one after another.
    func run(_ group: [Item], _ work: @MainActor @Sendable (Item) async -> Output) async {
        for item in group {
            items.append((item, await work(item)))
        }
    }
}

/// How many of a batch's items are done.
@MainActor
private final class BatchCounter: Sendable {
    var count = 0

    nonisolated init() {}
}

/// The Stops of a batch's running operations, to stop them all when the
/// batch is cancelled; one that starts after that is stopped at once.
final class BatchStops: Sendable {
    private struct State {
        var stops: [OperationStop] = []
        var isStopped = false
    }

    private let state = Mutex(State())

    var isStopped: Bool {
        state.withLock { $0.isStopped }
    }

    func add(_ stop: OperationStop) {
        let stopNow = state.withLock { state -> Bool in
            state.stops.append(stop)
            return state.isStopped
        }
        if stopNow {
            stop.stop()
        }
    }

    func stopAll() {
        let stops = state.withLock { state -> [OperationStop] in
            state.isStopped = true
            return state.stops
        }
        for stop in stops {
            stop.stop()
        }
    }
}

// MARK: - Pushing a worktree

/// What `SyncModel.pushWorktree(_:inBatch:)` did.
enum WorktreePushResult: Sendable {
    case pushed(PushOutcome)
    /// Nothing was pushed: the worktree's branch can't be.
    case refused(WorkPushRefusal)
    /// Only in a batch: the branch is behind its upstream, so it wasn't
    /// pushed.
    case behind
    /// Only in a batch: the branch has nothing to push.
    case upToDate
}

/// A worktree's branch, ready to push, as git has it now.
struct WorkPushTarget: Sendable {
    let worktree: WorktreeEntry
    /// The branch, its remotes found among the repository's.
    let branch: Branch
    /// The branch's upstream remote.
    let remote: Remote
    /// The remotes a push also goes to (`RemotesSnapshot.additionalPushRemotes`).
    let additional: [Remote]
    /// Against the upstream; nil when its remote-tracking branch is gone.
    let aheadBehind: AheadBehind?

    /// Why a batch skips the push, if it does: the branch is behind its
    /// upstream, or has nothing to push.
    var batchSkip: PushSkipReason? {
        guard let aheadBehind else {
            return nil
        }
        if aheadBehind.behind > 0 {
            return .needsPull
        }
        return aheadBehind.ahead == 0 ? .upToDate : nil
    }
}

/// Why a worktree's branch can't be pushed.
enum WorkPushRefusal: Error, Sendable, Equatable {
    case notAWorktree(path: String)
    case folderMissing(worktree: String)
    case detached(worktree: String)
    case unborn(branch: String)
    case noUpstream(branch: String)
    case remoteGone(branch: String, remote: String)

    var message: String {
        switch self {
        case .notAWorktree(let path):
            "\(path) isn't a worktree of this repository."
        case .folderMissing(let worktree):
            "The folder for the worktree \(worktree) no longer exists."
        case .detached(let worktree):
            "The worktree \(worktree) is on a detached HEAD, not a branch."
        case .unborn(let branch):
            "\(branch) has no commits yet."
        case .noUpstream(let branch):
            "\(branch) isn't published yet, so there's nowhere to push it. Publish it first."
        case .remoteGone(let branch, let remote):
            "The remote \(remote) that \(branch) tracks is no longer in this repository."
        }
    }

    /// The branch, when the worktree is on one.
    var branch: String? {
        switch self {
        case .unborn(let branch), .noUpstream(let branch), .remoteGone(let branch, _): branch
        case .notAWorktree, .folderMissing, .detached: nil
        }
    }
}

/// The branch checked out in the worktree at `path`, one of those
/// `repository` lists, as git has it now: its upstream's remote, the
/// remotes a push also goes to, and how far it is from its upstream.
///
/// - Throws: Git's errors listing the worktrees, the branches, or the
///   remotes.
@concurrent
func loadWorkPushTarget(path: String, listedFrom repository: Repository) async throws -> Result<WorkPushTarget, WorkPushRefusal> {
    let worktrees = try await listWorktrees(repository)
    guard let entry = worktrees.first(where: { sameWorktreePath($0.path, path) }) else {
        return .failure(.notAWorktree(path: path))
    }
    let name = getWorktreeDisplayName(entry)
    guard itemExists(atPath: entry.path) else {
        return .failure(.folderMissing(worktree: name))
    }
    guard let ref = entry.branch, !ref.isEmpty else {
        return .failure(.detached(worktree: name))
    }
    let worktree = Repository(path: entry.path)
    let remotes = try await getRemotes(worktree)
    guard let local = try await getBranches(worktree, "refs/heads").first(where: { JSCompat.strictEquals($0.ref, ref) }) else {
        return .failure(.unborn(branch: getWorktreeDescription(entry)))
    }
    let branch = local.resolvingRemotes(remotes.map(\.name))
    guard let remoteName = branch.upstreamRemoteName, !remoteName.isEmpty,
          let upstream = branch.upstreamWithoutRemote, !upstream.isEmpty
    else {
        return .failure(.noUpstream(branch: branch.name))
    }
    guard let remote = remotes.first(where: { JSCompat.strictEquals($0.name, remoteName) }) else {
        return .failure(.remoteGone(branch: branch.name, remote: remoteName))
    }
    // Marks that can't be read mark nothing, as a refresh reads them.
    let snapshot = RemotesSnapshot(
        all: remotes,
        forkRemoteNames: (try? await getForkRemoteNames(worktree)) ?? [],
        pushDestinationNames: (try? await getPushDestinationNames(worktree)) ?? []
    )
    let aheadBehind = (try? await getBranchAheadBehind(worktree, branch)) ?? nil
    return .success(WorkPushTarget(
        worktree: entry,
        branch: branch,
        remote: remote,
        additional: snapshot.additionalPushRemotes(besides: remote.name),
        aheadBehind: aheadBehind
    ))
}

extension SyncModel {
    /// Pushes the branch of `key`'s worktree, one of the repository's, with
    /// `pushPrimitive` run in the worktree's folder; the branch and its
    /// remotes are read in the lane, just before. With `inBatch`, git asks
    /// nothing (`allowsPrompts`), and a branch behind its upstream or with
    /// nothing to push isn't pushed. Returns after the repository's
    /// refresh; its other worktrees in the list refresh their refs.
    func pushWorktree(_ key: WorktreeKey, inBatch: Bool) async throws(OperationError) -> WorktreePushResult {
        guard let repository else {
            throw notInList(.push)
        }
        await refreshGitHubRepositoryIfNeeded()
        let siblings = WorktreeSiblings(of: repository)
        let retry = PushWorkRetry(worktree: key)
        let descriptor = OperationDescriptor(
            kind: .push,
            lanes: [.network],
            retry: retry,
            refreshAfter: .full,
            showsProgressUntilRefreshed: true,
            allowsPrompts: !inBatch
        )
        enum Step: Sendable {
            case pushed(WorkPushTarget, PushResult)
            case notPushed(WorktreePushResult)
        }
        let step = try await repository.perform(descriptor) { ctx -> Step in
            let target: WorkPushTarget
            switch try await loadWorkPushTarget(path: key.path, listedFrom: ctx.repository) {
            case .failure(let refusal):
                return .notPushed(.refused(refusal))
            case .success(let loaded):
                target = loaded
            }
            if inBatch, let skip = target.batchSkip {
                return .notPushed(skip == .needsPull ? .behind : .upToDate)
            }
            let result = try await self.pushPrimitive(
                target.branch,
                to: target.remote,
                additional: target.additional,
                forceWithLease: false,
                workingIn: Repository(path: target.worktree.path),
                in: ctx,
                progress: ctx.progress
            )
            return .pushed(target, result)
        }
        let target: WorkPushTarget
        let result: PushResult
        switch step {
        case .notPushed(let notPushed):
            return notPushed
        case .pushed(let pushedTarget, let pushResult):
            target = pushedTarget
            result = pushResult
        }

        let fetchFailure = await classifyFetchFailure(result.fetchFailure)
        var additionalPushes: [AdditionalPush] = []
        for push in result.additional {
            let failure = await classifyAdditionalFailure(
                push.failure,
                remote: push.remote,
                branch: target.branch,
                request: PushRequest(),
                tags: result.tags,
                confirmed: [],
                retry: retry
            )
            additionalPushes.append(AdditionalPush(remote: push.remote, failure: failure))
        }
        // Branch protection is the current branch's, as after a push.
        if sameWorktreePath(repository.record.path, target.worktree.path) {
            await repository.gitHub.refreshBranchProtection()
        }
        repository.worktrees.refreshOtherWorktrees(siblings, after: .push)
        await repository.awaitOperationRefresh(covering: .full)
        return .pushed(.pushed(
            branch: target.branch.name,
            remote: result.remoteName,
            tags: result.tags,
            fetchFailure: fetchFailure,
            additional: additionalPushes
        ))
    }
}
