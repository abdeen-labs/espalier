import Darwin
import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "refresh")

/// How many recent branches the branch list shows.
let recentBranchesLimit = 5

/// The most local commits a refresh pass loads.
let commitBatchSize = 100

/// Runs a repository's refresh passes.
///
/// | Step | Loads | Scope |
/// |---|---|---|
/// | 1 | A missing record stops; a vanished path tries worktree recovery, else marks the record missing | all |
/// | 2 | The git directory, when the record lacks it; the directories to watch | all |
/// | 3 | Status: tip, ahead/behind, the operation in progress, changed files, the indicator; the features hear about it at once, and waiters needing only the status go on. A tip SHA change adds `.refs` | status |
/// | 4 | Remotes: all, default, current, upstream | remotes |
/// | 5 | Branches and recent branches, default and upstream default branches, `pull.rebase` | refs |
/// | 6 | `FETCH_HEAD`'s date and the author (metadata); stashes, worktrees, local commits (refs) | refs, metadata |
/// | 7 | Tags; queued tags that no longer exist are dropped | refs |
/// | 8 | `repositoryDidRefresh` to every feature for the steps after the status | all |
///
/// Each step checks that the pass is still current before applying.
@MainActor
final class RepositoryRefresher {
    weak var model: RepositoryModel?

    init() {}

    func run(_ requested: RefreshScope, options: RefreshOptions, token: RefreshPassToken) async {
        guard let model, let app = model.app else {
            return
        }
        let environment = model.environment
        var scope = requested
        var applied: RefreshScope = []

        // 1. Missing records stop; a vanished path is recovered or missing.
        if model.record.isMissing {
            return
        }
        guard await pathExists(model.record.path) else {
            guard token.isCurrent else { return }
            if await app.recoverMissingWorktree(model.id) {
                return
            }
            guard token.isCurrent else { return }
            app.setMissing(true, for: model.id)
            return
        }
        guard token.isCurrent else { return }

        // 2. The git directory, and the directories to watch.
        if model.record.gitDir == nil {
            let path = model.record.path
            if case .regular(_, let gitDir)? = try? await environment.withRuntimes({ try await getRepositoryType(path) }) {
                guard token.isCurrent else { return }
                app.updateRecord(model.id) { $0.gitDir = gitDir }
            }
        }
        if model.watchedPaths == nil {
            let path = model.record.path
            if let paths = await environment.withRuntimes({ await resolveWatchedPaths(path) }) {
                guard token.isCurrent else { return }
                model.watchedPathsDidResolve(paths)
            }
        }

        let repository = model.record.gitRepository
        let state = model.gitState
        let previousTip = state.tip

        // 3. Status.
        if scope.contains(.status) {
            let loaded: StatusResult?
            do {
                loaded = try await environment.withRuntimes { try await getStatus(repository) }
            } catch {
                guard token.isCurrent else { return }
                await handleFailure(error, step: "status", model: model)
                return
            }
            guard token.isCurrent else { return }
            guard let loaded else {
                // git exited with 128: most likely no repository any more.
                app.setIndicator(nil, for: model.id)
                app.setMissing(true, for: model.id)
                return
            }
            // A rebase git was interrupted in leaves no REBASE_HEAD for the
            // status to see: between commits, with HEAD detached, or while
            // finishing, after it moved the branch and put HEAD back on it.
            var interruptedRebase: RebaseInternalState?
            if loaded.rebaseInternalState == nil {
                interruptedRebase = await getInterruptedRebaseState(repository)
                guard token.isCurrent else { return }
            }
            // A `git am` or a bisect, which status doesn't show and
            // Espalier can't continue (only looked for when status shows
            // no other operation).
            var unsupported: GitOperationInProgress?
            if inProgress(loaded, interruptedRebase: interruptedRebase, unsupported: nil) == nil {
                unsupported = await unsupportedOperationInProgress(repository)
                guard token.isCurrent else { return }
            }
            // Which commit a rebase or a cherry-pick of several commits
            // stopped at for the user, from git's own files (only read).
            var stoppedStep: OperationStep?
            if loaded.rebaseInternalState != nil {
                stoppedStep = await environment.withRuntimes { await getRebaseStep(repository) }
                guard token.isCurrent else { return }
            } else if loaded.isCherryPickingHeadFound {
                stoppedStep = await environment.withRuntimes { await getCherryPickStep(repository) }
                guard token.isCurrent else { return }
            }
            applyStatus(loaded, interruptedRebase: interruptedRebase, unsupported: unsupported, to: state)
            model.setAvailability(.available)
            model.changes.reconcile(loaded, options: options)
            model.operations.reconcile(loaded, interruptedRebase: interruptedRebase, stoppedStep: stoppedStep)
            app.setIndicator(RepositoryIndicator(loaded), for: model.id)
            applied.insert(.status)
            // The status lands at once (the changes list updates before the
            // slower steps), and waiters that need only it go on.
            notifyFeatures(model, applied: .status, options: options, status: loaded, previousTip: previousTip)
            token.didApply(.status)
            // A new tip loads the refs again, and so does a tip the refs
            // weren't loaded for: a pass that applied this tip's status may
            // have been superseded before its refs loaded (the local
            // commits stayed the previous branch's after a cherry-pick's
            // undo checked the first branch out again).
            if previousTip.sha != state.tip.sha || previousTip.branch?.name != state.tip.branch?.name
                || state.refsTip != RefsTip(state.tip) {
                scope.insert(.refs)
            }
        }

        // 4. Remotes.
        if scope.contains(.remotes) {
            do {
                let (remotes, forkRemoteNames) = try await environment.withRuntimes {
                    (try await getRemotes(repository), await loadForkRemoteNames(repository))
                }
                guard token.isCurrent else { return }
                // The current branch's upstream remote, with these remotes.
                if case .valid(let branch) = state.tip {
                    assign(\.tip, .valid(branch: branch.resolvingRemotes(remotes.map(\.name))), in: state)
                }
                let snapshot = remotesSnapshot(remotes, forkRemoteNames: forkRemoteNames, tip: state.tip, record: model.record)
                assign(\.remotes, snapshot, in: state)
                applied.insert(.remotes)
            } catch {
                guard token.isCurrent else { return }
                logger.error("Could not load the remotes: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 5. Branches.
        if scope.contains(.refs) {
            let record = model.record
            let defaultRemoteName = state.remotes.defaultRemote?.name
            let loaded = await environment.withRuntimes {
                await loadBranches(repository, record: record, defaultRemoteName: defaultRemoteName)
            }
            guard token.isCurrent else { return }
            if let loaded {
                assign(\.branches, loaded, in: state)
                applied.insert(.refs)
            }
        }

        // 6. FETCH_HEAD, author, stashes, worktrees, local commits.
        if !scope.isDisjoint(with: [.refs, .metadata]) {
            let loadsRefs = scope.contains(.refs)
            let loadsMetadata = scope.contains(.metadata)
            let tip = state.tip
            let loaded = await environment.withRuntimes {
                await loadRefsAndMetadata(repository, tip: tip, refs: loadsRefs, metadata: loadsMetadata)
            }
            guard token.isCurrent else { return }
            if case .some(let date) = loaded.lastFetched {
                assign(\.lastFetched, date, in: state)
            }
            if case .some(let identity) = loaded.author {
                assign(\.commitAuthor, identity, in: state)
            }
            if let stashes = loaded.stashes {
                assign(\.stashes, stashes, in: state)
            }
            if let worktrees = loaded.worktrees {
                assign(\.worktrees, worktrees, in: state)
            }
            if let localCommits = loaded.localCommitSHAs {
                assign(\.localCommitSHAs, localCommits, in: state)
                state.refsTip = RefsTip(tip)
            }
            if loadsMetadata {
                applied.insert(.metadata)
            }
        }

        // 7. Tags.
        if scope.contains(.refs) {
            do {
                let tags = try await environment.withRuntimes { try await getAllTags(repository) }
                guard token.isCurrent else { return }
                assign(\.tags, tags, in: state)
                // Remove any unpushed tag that cannot be found in the list
                // of local tags. This can happen when the user deletes an
                // unpushed tag from outside of Espalier.
                let queued = model.record.tagsToPush
                let remaining = queued.filter { tags[$0] != nil }
                if remaining != queued {
                    app.updateRecord(model.id) { $0.tagsToPush = remaining }
                }
                applied.insert(.refs)
            } catch {
                guard token.isCurrent else { return }
                logger.error("Could not load the tags: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 8. Tell the features about the rest (they heard about the status
        // when it landed).
        let rest = applied.subtracting(.status)
        guard token.isCurrent, !rest.isEmpty else { return }
        notifyFeatures(model, applied: rest, options: options, status: nil, previousTip: previousTip)
    }

    /// Bumps the snapshot's generation and tells every feature what changed,
    /// in the same main-actor turn as the change.
    private func notifyFeatures(
        _ model: RepositoryModel,
        applied: RefreshScope,
        options: RefreshOptions,
        status: StatusResult?,
        previousTip: Tip
    ) {
        model.gitState.generation &+= 1
        assign(\.loaded, model.gitState.loaded.union(applied), in: model.gitState)
        let update = RefreshUpdate(
            applied: applied,
            options: options,
            status: status,
            previousTip: previousTip,
            generation: model.gitState.generation
        )
        for feature in model.features {
            feature.repositoryDidRefresh(update)
        }
    }

    // MARK: Status

    /// Applies a status: a branch with a tip is valid, a tip alone is
    /// detached, a branch alone is unborn, and neither is unknown. The tip is
    /// the status's SHA; nothing is looked up.
    private func applyStatus(
        _ status: StatusResult,
        interruptedRebase: RebaseInternalState?,
        unsupported: GitOperationInProgress?,
        to state: RepositoryGitState
    ) {
        let tip: Tip
        let currentBranch = status.currentBranch.flatMap { $0.isEmpty ? nil : $0 }
        let currentTip = status.currentTip.flatMap { $0.isEmpty ? nil : $0 }
        if let currentBranch, let currentTip {
            // The remotes as last loaded tell where the upstream's remote
            // name ends; loading the remotes resolves it again.
            tip = .valid(branch: Branch(
                name: currentBranch,
                upstream: status.currentUpstreamBranch.flatMap { $0.isEmpty ? nil : $0 },
                tip: BranchTip(sha: currentTip),
                type: .local,
                ref: "refs/heads/\(currentBranch)",
                remoteNames: state.remotes.all.map(\.name)
            ))
        } else if let currentTip {
            tip = .detached(currentSha: currentTip)
        } else if let currentBranch {
            tip = .unborn(ref: currentBranch)
        } else {
            tip = .unknown
        }
        assign(\.tip, tip, in: state)
        assign(\.aheadBehind, status.branchAheadBehind, in: state)
        assign(\.inProgress, inProgress(status, interruptedRebase: interruptedRebase, unsupported: unsupported), in: state)
    }

    /// The operation in progress. A squash merge writes no `MERGE_HEAD`, so a
    /// `SQUASH_MSG` counts only while conflicted files exist. A rebase git was
    /// interrupted in between commits is a rebase too, and `REVERT_HEAD` a
    /// revert. Otherwise `unsupported`: a `git am` or a bisect.
    private func inProgress(
        _ status: StatusResult,
        interruptedRebase: RebaseInternalState?,
        unsupported: GitOperationInProgress?
    ) -> GitOperationInProgress? {
        if let rebase = status.rebaseInternalState ?? interruptedRebase {
            return .rebase(rebase)
        }
        if status.isCherryPickingHeadFound {
            return .cherryPick
        }
        if status.isRevertHeadFound {
            return .revert
        }
        if status.mergeHeadFound {
            return .merge(squash: false)
        }
        if status.squashMsgFound, status.doConflictedFilesExist {
            return .merge(squash: true)
        }
        return unsupported
    }

    // MARK: Remotes

    /// The remotes: all, default, current, upstream, and Espalier's fork
    /// remotes.
    private func remotesSnapshot(
        _ remotes: [Remote],
        forkRemoteNames: Set<ExactString>,
        tip: Tip,
        record: RepositoryRecord
    ) -> RemotesSnapshot {
        let defaultRemote = findDefaultRemote(remotes)

        // Load the remote that the current branch is tracking. If the branch
        // is not tracking any remote or the remote which it's tracking has
        // been removed we'll default to the default branch.
        let currentRemoteName = tip.branch?.upstreamRemoteName
        let currentRemote = currentRemoteName.flatMap { name in
            remotes.first { JSCompat.strictEquals($0.name, name) }
        } ?? defaultRemote

        let upstreamRemote = record.gitHubRepository?.parent.flatMap { findUpstreamRemote($0, remotes) }
        return RemotesSnapshot(
            all: remotes,
            defaultRemote: defaultRemote,
            currentRemote: currentRemote,
            upstreamRemote: upstreamRemote,
            forkRemoteNames: forkRemoteNames
        )
    }

    // MARK: Failures

    private func handleFailure(_ error: any Error, step: String, model: RepositoryModel) async {
        logger.error("Could not load the \(step, privacy: .public): \(error.localizedDescription, privacy: .public)")
        let classified = await ErrorClassifier.classify(
            error,
            descriptor: OperationDescriptor(kind: .fetch, lanes: [], policy: .background),
            record: model.record,
            context: ClassificationContext(isBackgroundTask: true)
        )
        if case .missingRepository = classified.reason {
            model.app?.setIndicator(nil, for: model.id)
            model.app?.setMissing(true, for: model.id)
        }
    }
}

/// Assigns `value` only when it differs, because observable setters always
/// notify.
@MainActor
func assign<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<RepositoryGitState, Value>,
    _ value: Value,
    in state: RepositoryGitState
) {
    if state[keyPath: keyPath] != value {
        state[keyPath: keyPath] = value
    }
}

// MARK: - Loaders (off the main actor)

/// The working directory, git directory, and common directory as real paths
/// (`git rev-parse --path-format=absolute --git-dir --git-common-dir`).
@concurrent
func resolveWatchedPaths(_ path: String) async -> WatchedPaths? {
    guard let result = try? await git(
        ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
        path,
        "resolveWatchedPaths",
        options: GitExecutionOptions(successExitCodes: [0, 128])
    ), result.exitCode == 0 else {
        return nil
    }
    let lines = JSCompat.split(JSCompat.trim(result.stdout), "\n")
    guard lines.count >= 2 else {
        return nil
    }
    return WatchedPaths(
        workingDirectory: realPath(path),
        gitDirectory: realPath(lines[0]),
        commonDirectory: realPath(lines[1])
    )
}

/// `realpath(3)`: symbolic links resolved (FSEvents reports `/private/var`
/// for `/var`). The path itself when it can't be resolved.
func realPath(_ path: String) -> String {
    guard let resolved = Darwin.realpath(path, nil) else {
        return path
    }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A `git am` stopped on a patch (`rebase-apply/applying`) or a bisect
/// (`BISECT_START`), from the files git keeps in the (worktree's) git
/// directory; nil when neither is in progress.
@concurrent
func unsupportedOperationInProgress(_ repository: Repository) async -> GitOperationInProgress? {
    let gitDir = repository.resolvedGitDir
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: POSIXPath.join(gitDir, "rebase-apply/applying")) {
        return .applyingPatches
    }
    if fileManager.fileExists(atPath: POSIXPath.join(gitDir, "BISECT_START")) {
        return .bisect
    }
    return nil
}

/// The branches (`mergeRemoteAndLocalBranches`), the default and recent
/// branches, and `pull.rebase`. Nil when the branches couldn't be read.
@concurrent
func loadBranches(_ repository: Repository, record: RepositoryRecord, defaultRemoteName: String?) async -> BranchesSnapshot? {
    async let branchList = loadBranchList(repository)
    // Chances are that the recent branches list will contain the default
    // branch which we filter out below. So grab one more than we need to
    // account for that.
    async let recentNames = loadRecentBranchNames(repository)

    guard let branches = await branchList else {
        _ = await recentNames
        return nil
    }
    let allBranches = mergeRemoteAndLocalBranches(branches)
    // From every branch: the remote's default branch is the default even
    // when a local branch of another name tracks it, which leaves it out of
    // `allBranches`.
    let defaultBranch = try? await findDefaultBranch(record, branches, defaultRemoteName)
    let upstreamDefaultBranch = await findUpstreamDefaultBranch(repository, record: record, branches: allBranches)
    let recent = recentBranches(await recentNames, allBranches: allBranches, defaultBranch: defaultBranch)
    let pullWithRebase = parsePullRebase(try? await getConfigValue(repository, "pull.rebase"))

    return BranchesSnapshot(
        all: allBranches,
        defaultBranch: defaultBranch,
        upstreamDefaultBranch: upstreamDefaultBranch,
        recent: recent,
        pullWithRebase: pullWithRebase,
        upstreams: trackedUpstreams(branches)
    )
}

/// Each local branch's upstream among `branches`, by the local branch's
/// ref: the branch whose short name is the upstream's (both are git's
/// unambiguous short names from one listing, as
/// `mergeRemoteAndLocalBranches` matches them). Upstreams that aren't
/// listed (gone, or outside `refs/heads` and `refs/remotes`) are left out.
func trackedUpstreams(_ branches: [Branch]) -> [ExactString: Branch] {
    var byName: [ExactString: Branch] = [:]
    byName.reserveCapacity(branches.count)
    for branch in branches where byName[ExactString(branch.name)] == nil {
        byName[ExactString(branch.name)] = branch
    }
    var upstreams: [ExactString: Branch] = [:]
    for branch in branches where branch.type == .local {
        if let name = branch.upstream, !name.isEmpty, let upstream = byName[ExactString(name)] {
            upstreams[ExactString(branch.ref)] = upstream
        }
    }
    return upstreams
}

/// The fork remotes Espalier marked; none when the marks can't be read, so
/// nothing is hidden.
@concurrent
private func loadForkRemoteNames(_ repository: Repository) async -> Set<ExactString> {
    do {
        return try await getForkRemoteNames(repository)
    } catch {
        logger.error("Could not read the fork remotes' marks: \(error.localizedDescription, privacy: .public)")
        return []
    }
}

@concurrent
private func loadBranchList(_ repository: Repository) async -> [Branch]? {
    do {
        return try await getBranches(repository)
    } catch {
        logger.error("Could not load the branches: \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

@concurrent
private func loadRecentBranchNames(_ repository: Repository) async -> [String] {
    (try? await getRecentBranches(repository, recentBranchesLimit + 1)) ?? []
}

/// What step 6 of a refresh pass loads. A nil field wasn't loaded; for the
/// double optionals, `.some(nil)` means loaded and absent.
struct RefsAndMetadata: Sendable {
    var lastFetched: Date??
    var author: CommitIdentity??
    var stashes: StashSnapshot?
    var worktrees: [WorktreeEntry]?
    var localCommitSHAs: [String]?
}

/// Step 6 of a refresh pass, in parallel: `FETCH_HEAD`'s date and the
/// author identity (metadata); stashes, worktrees, and local commits
/// (refs).
@concurrent
func loadRefsAndMetadata(_ repository: Repository, tip: Tip, refs: Bool, metadata: Bool) async -> RefsAndMetadata {
    async let lastFetched: Date?? = metadata ? fetchHeadDate(repository.resolvedGitDir) : nil
    async let author: CommitIdentity?? = metadata ? loadAuthor(repository) : nil
    async let stashes: StashSnapshot? = refs ? (try? stashSnapshot(repository)) : nil
    async let worktrees: [WorktreeEntry]? = refs ? (try? listWorktrees(repository.path)) : nil
    async let localCommits: [String]? = refs ? loadLocalCommitSHAs(repository, tip: tip) : nil
    return await RefsAndMetadata(
        lastFetched: lastFetched,
        author: author,
        stashes: stashes,
        worktrees: worktrees,
        localCommitSHAs: localCommits
    )
}

/// `git var GIT_AUTHOR_IDENT`; nil when git has no identity (or fails).
@concurrent
private func loadAuthor(_ repository: Repository) async -> CommitIdentity? {
    do {
        return try await getAuthorIdentity(repository)
    } catch {
        logger.error("Could not load the author identity: \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

/// Takes a list of local and remote branches and filters out "duplicate"
/// remote branches, i.e. remote branches that we already have a local
/// branch tracking.
func mergeRemoteAndLocalBranches(_ branches: [Branch]) -> [Branch] {
    let localBranches = branches.filter { $0.type == .local }
    let remoteBranches = branches.filter { $0.type == .remote }

    var upstreamBranchesAdded: Set<ExactString> = []
    var allBranchesWithUpstream: [Branch] = []
    for branch in localBranches {
        allBranchesWithUpstream.append(branch)
        if let upstream = branch.upstream, !upstream.isEmpty {
            upstreamBranchesAdded.insert(ExactString(upstream))
        }
    }
    for branch in remoteBranches {
        // This means we already added the local branch of this remote
        // branch, so we don't need to add it again.
        if upstreamBranchesAdded.contains(ExactString(branch.name)) {
            continue
        }
        allBranchesWithUpstream.append(branch)
    }
    return allBranchesWithUpstream
}

/// The upstream default branch is only relevant for forked GitHub repos when
/// the fork behavior is contributing to the parent.
private func findUpstreamDefaultBranch(_ repository: Repository, record: RepositoryRecord, branches: [Branch]) async -> Branch? {
    guard isForkedRepositoryContributingToParent(record) else {
        return nil
    }
    var name = try? await getRemoteHEAD(repository, upstreamRemoteName)
    if name == nil {
        name = try? await getDefaultBranch()
    }
    guard let name else {
        return nil
    }
    return branches.first { branch in
        branch.type == .remote
            && (try? branch.remoteName) == upstreamRemoteName
            && JSCompat.strictEquals(branch.nameWithoutRemote, name)
    }
}

/// Maps reflog-derived names to existing local branches, without the
/// default branch, at most `recentBranchesLimit`.
func recentBranches(_ names: [String], allBranches: [Branch], defaultBranch: Branch?) -> [Branch] {
    var branchesByName: [ExactString: Branch] = [:]
    for branch in allBranches where branch.type == .local {
        branchesByName[ExactString(branch.name)] = branch
    }

    var recent: [Branch] = []
    for name in names {
        // The default branch already has its own section in the branch list
        // so we exclude it here.
        if let defaultBranch, JSCompat.strictEquals(name, defaultBranch.name) {
            continue
        }
        // A missing branch has been deleted. That's fine.
        guard let branch = branchesByName[ExactString(name)] else {
            continue
        }
        recent.append(branch)
        if recent.count >= recentBranchesLimit {
            break
        }
    }
    return recent
}

/// `pull.rebase` as a pull with or without rebase. Git's boolean spellings
/// are accepted, and `merges` and `interactive` are kinds of rebase.
/// Unset, empty, or unknown values are nil.
func parsePullRebase(_ value: String?) -> Bool? {
    guard let value else {
        return nil
    }
    switch JSCompat.toLowerCase(JSCompat.trim(value)) {
    case "true", "yes", "on", "1", "merges", "m", "interactive", "i":
        return true
    case "false", "no", "off", "0":
        return false
    case "":
        return nil
    default:
        logger.warning("Unexpected value found for pull.rebase in config: '\(value, privacy: .public)'")
        return nil
    }
}

/// When the repository was last fetched: `FETCH_HEAD`'s modification
/// date, or `.some(nil)` when there's none (never fetched). An empty
/// `FETCH_HEAD` probably means the fetch failed, so it returns `.none` and
/// the previous date stays.
@concurrent
func fetchHeadDate(_ gitDir: String) async -> Date?? {
    let path = POSIXPath.join(gitDir, "FETCH_HEAD")
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
        return .some(nil)
    }
    guard let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
        return .none
    }
    return .some(attributes[.modificationDate] as? Date)
}

/// The newest automatic stash entry per branch (`desktopEntries`), and the
/// total.
@concurrent
func stashSnapshot(_ repository: Repository) async throws -> StashSnapshot {
    let result = try await getStashes(repository)
    var entries: [String: StashEntry] = [:]
    // Stash entries come newest first; the first per branch is its newest.
    for entry in result.desktopEntries where entries[entry.branchName] == nil {
        entries[entry.branchName] = entry
    }
    return StashSnapshot(entriesByBranch: entries, totalCount: result.stashEntryCount)
}

/// The current branch's commits that aren't on its upstream, newest first.
/// Without an upstream (or with one that's gone), and on a detached HEAD,
/// the commits on no remote.
@concurrent
func loadLocalCommitSHAs(_ repository: Repository, tip: Tip) async -> [String] {
    switch tip {
    case .valid(let branch):
        if let upstream = branch.upstream, !upstream.isEmpty,
           let commits = try? await getCommits(repository, revRange(upstream, branch.name), limit: commitBatchSize) {
            return commits.map(\.sha)
        }
        return (try? await getCommits(repository, "HEAD", limit: commitBatchSize, additionalArgs: ["--not", "--remotes"]))?.map(\.sha) ?? []
    case .detached:
        return (try? await getCommits(repository, "HEAD", limit: commitBatchSize, additionalArgs: ["--not", "--remotes"]))?.map(\.sha) ?? []
    case .unborn, .unknown:
        return []
    }
}
