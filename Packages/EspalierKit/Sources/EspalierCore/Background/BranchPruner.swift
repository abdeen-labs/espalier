// Ported from desktop/app/src/lib/stores/helpers/branch-pruner.ts
//
// A task loop on the environment's scheduler whose deletions run as one
// background local operation.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import os

private let logger = Log.logger(category: "branch-pruner")

/// Deletes merged local branches whose upstream is gone, in the selected
/// GitHub repository: at once, then every 4 hours, doing real work at most
/// once a day per repository.
///
/// Safeguards: GitHub repositories only; never the current branch or a
/// reserved one (`main`, `master`, `gh-pages`, `develop`, `dev`,
/// `development`, `trunk`, `devel`, `release`); never a branch checked out
/// in the last 14 days or in any worktree; only a branch merged into the
/// default branch whose upstream names a remote-tracking branch that no
/// longer exists (a branch tracking a local branch is never pruned for its
/// upstream); never a branch a rebase in progress in any worktree is rebasing
/// (HEAD is detached then, so it isn't the current branch), stopped or
/// interrupted. Each deletion (`git update-ref -d` with the SHA it was found
/// merged at, then its `branch.<name>` configuration) is logged and recorded
/// in `sync.prunedBranches` with its SHA, so it can be restored.
///
/// Stopping ends the loop even during the first prune; the dry run leaves
/// the last prune date alone; a branch whose tip moved since it was found
/// merged is kept; the date is written only once the prune can run (a
/// prune skipped behind another operation tries again 4 hours later);
/// deletions run as background work, never presented.
@MainActor
final class BranchPruner: SelectionScopedService {
    /// Check if a repo needs to be pruned at least every 4 hours.
    static let interval: Duration = .seconds(4 * 60 * 60)

    /// Only prune if it's been at least 24 hours since the last time.
    static let pruneThreshold: TimeInterval = 24 * 60 * 60

    /// Branches checked out within this window are kept (two weeks).
    static let recentCheckoutWindow: TimeInterval = 14 * 24 * 60 * 60

    /// Refs that are never pruned.
    static let reservedRefs = [
        "HEAD",
        "refs/heads/main",
        "refs/heads/master",
        "refs/heads/gh-pages",
        "refs/heads/develop",
        "refs/heads/dev",
        "refs/heads/development",
        "refs/heads/trunk",
        "refs/heads/devel",
        "refs/heads/release",
    ].exactSet

    /// The repository it runs for, while running.
    private(set) var repositoryID: RepositoryID?

    private let environment: AppEnvironment
    private weak var app: AppModel?
    private let loop: PeriodicLoop
    private weak var repository: RepositoryModel?
    /// Bumped by `start` and `stop`, so a prune that outlives its start does
    /// no more than it already began.
    private var generation: UInt64 = 0

    init(environment: AppEnvironment, app: AppModel) {
        self.environment = environment
        self.app = app
        loop = PeriodicLoop(scheduler: environment.scheduler)
    }

    var isRunning: Bool {
        repositoryID != nil
    }

    func start(for repository: RepositoryModel, isFirstSelectionSinceLaunch: Bool) {
        stop()
        repositoryID = repository.id
        self.repository = repository
        let generation = generation
        loop.start(firstDelay: .zero) { [weak self] in
            guard let self, generation == self.generation, let repository = self.repository else {
                return nil
            }
            _ = await self.prune(repository, dryRun: false, generation: generation)
            return generation == self.generation ? Self.interval : nil
        }
    }

    func stop() {
        generation &+= 1
        loop.stop()
        repositoryID = nil
        repository = nil
    }

    /// Prunes the repository the pruner runs for now. A dry run reports what
    /// it would delete and never writes the last prune date.
    func prune(dryRun: Bool) async -> [PrunedBranch] {
        guard let repository else {
            return []
        }
        return await prune(repository, dryRun: dryRun)
    }

    /// Prunes `repository`: the branches deleted, or for a dry run the
    /// branches it would delete.
    func prune(_ repository: RepositoryModel, dryRun: Bool) async -> [PrunedBranch] {
        await prune(repository, dryRun: dryRun, generation: nil)
    }

    private func prune(_ repository: RepositoryModel, dryRun: Bool, generation: UInt64?) async -> [PrunedBranch] {
        func isCurrent() -> Bool {
            generation.map { $0 == self.generation } ?? true
        }

        guard let app, let gitHubRepository = repository.record.gitHubRepository else {
            return []
        }

        // Get the last time this repo was pruned
        let now = environment.scheduler.now
        if !dryRun, let lastPruneDate = app.gitHubRepositories[gitHubRepository.dbID]?.lastPruneDate,
           now.timeIntervalSince(lastPruneDate) < Self.pruneThreshold {
            logger.info("[BranchPruner] Last prune took place \(lastPruneDate, privacy: .public) - skipping")
            return []
        }
        guard isCurrent() else {
            return []
        }

        let record = repository.record
        if dryRun {
            let found = await environment.withRuntimes {
                await Self.findBranchesToPrune(repository.gitRepository, record: record, now: now)
            }
            for branch in found {
                logger.info("[BranchPruner] Branch '\(branch.name, privacy: .private)' marked for deletion")
            }
            return found
        }

        let descriptor = OperationDescriptor(kind: .pruneBranches, lanes: [.local], policy: .background, refreshAfter: [])
        let pruned: [PrunedBranch]?
        do {
            pruned = try await repository.performIfIdle(descriptor) { ctx in
                // update the last prune date first thing after we check it!
                self.recordPruneDate(now, for: gitHubRepository)
                let candidates = await Self.findBranchesToPrune(ctx.repository, record: record, now: now)
                var pruned: [PrunedBranch] = []
                for candidate in candidates {
                    if await self.deleteIfUnchanged(candidate, in: ctx.repository) {
                        pruned.append(candidate)
                    }
                }
                return pruned
            }
        } catch {
            SyncModel.logFailure("[BranchPruner] Pruning failed", error)
            return []
        }

        guard let pruned else {
            logger.info("[BranchPruner] Another operation is running; pruning later")
            return []
        }
        if !pruned.isEmpty {
            repository.sync.prunedBranches.append(contentsOf: pruned)
            repository.requestRefresh(.full, reason: .operation(.pruneBranches))
        }
        return pruned
    }

    /// The branches merged into the default branch whose upstream is gone,
    /// without the safeguarded ones, with the SHA each pointed at. Failures to
    /// read any of it find nothing.
    ///
    /// The branches and the default branch are read here rather than taken
    /// from the last refresh, which at the selection may not have loaded them
    /// yet: the prune would then find no default branch and spend the day's
    /// prune on nothing.
    private static func findBranchesToPrune(_ gitRepository: Repository, record: RepositoryRecord, now: Date) async -> [PrunedBranch] {
        let name = record.name
        let remotes = (try? await getRemotes(gitRepository)) ?? []
        guard let branchesState = await loadBranches(gitRepository, record: record, defaultRemoteName: findDefaultRemote(remotes)?.name),
              let defaultBranch = branchesState.defaultBranch
        else {
            return []
        }

        do {
            // By the default branch's full ref: git reads its short name as a
            // tag of that name first, and the branches merged into the tag
            // aren't necessarily merged into the branch.
            var mergedBranches = try await getMergedBranches(gitRepository, defaultBranch.ref)

            // remove the current branch
            if let currentBranchCanonicalRef = try await getSymbolicRef(gitRepository, "HEAD") {
                mergedBranches[currentBranchCanonicalRef] = nil
            }

            if mergedBranches.isEmpty {
                logger.info("[BranchPruner] No branches to prune.")
                return []
            }

            // Get all branches checked out within the past 2 weeks
            let twoWeeksAgo = now.addingTimeInterval(-Self.recentCheckoutWindow)
            let recentlyCheckedOutCanonicalRefs = try await getBranchCheckouts(gitRepository, twoWeeksAgo)
                .keys.map(formatAsLocalRef).exactSet

            // get the locally cached branches of remotes (ie `refs/remotes/origin/main`)
            let remoteBranches = try await getBranches(gitRepository, "refs/remotes/").map(\.ref).exactSet

            // and each local branch's upstream, as a full ref
            let upstreamRefs = try await upstreamRefsByBranch(gitRepository)

            // get branches checked out in linked worktrees so we don't delete them
            let worktreeBranches = try await listWorktrees(gitRepository).compactMap(\.branch).exactSet

            // and the branches rebases in progress are rebasing
            let rebasingBranches = await branchesBeingRebased(gitRepository)

            // create list of branches to be pruned, in git's order (by ref)
            let branchesReadyForPruning = mergedBranches.keys.sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }.filter { ref in
                let key = ExactString(ref)
                if Self.reservedRefs.contains(key) || recentlyCheckedOutCanonicalRefs.contains(key) || worktreeBranches.contains(key)
                    || rebasingBranches.contains(key) {
                    return false
                }
                // Only an upstream that names a remote-tracking branch can be
                // gone; one that names a local branch never is.
                guard let upstreamRef = upstreamRefs[key], JSCompat.startsWith(upstreamRef, "refs/remotes/") else {
                    return false
                }
                return !remoteBranches.contains(ExactString(upstreamRef))
            }

            logger.info("[BranchPruner] Pruning \(branchesReadyForPruning.count) branches that have been merged into the default branch, \(defaultBranch.name, privacy: .private) (\(defaultBranch.tip.sha, privacy: .public)), from '\(name, privacy: .private)'")

            let branchRefPrefix = "refs/heads/"
            return branchesReadyForPruning.compactMap { ref -> PrunedBranch? in
                guard JSCompat.startsWith(ref, branchRefPrefix), let sha = mergedBranches[ref] else {
                    return nil
                }
                return PrunedBranch(name: JSCompat.dropFirst(ref, branchRefPrefix.unicodeScalars.count), sha: sha, date: now)
            }
        } catch {
            SyncModel.logFailure("[BranchPruner] Finding branches to prune failed", error)
            return []
        }
    }

    /// Deletes `branch` if it still points at the commit it was found merged
    /// at, comparing and deleting in one step (`git update-ref -d` with that
    /// commit), so a branch that moved since then, which may hold new work,
    /// is kept even when it moves while the pruner runs. A deleted branch's
    /// configuration (`branch.<name>.*`) goes too, as with `git branch -D`;
    /// failing to remove it is only logged, since the branch is gone.
    func deleteIfUnchanged(_ branch: PrunedBranch, in repository: Repository) async -> Bool {
        do {
            guard try await deleteRef(repository, "refs/heads/\(branch.name)", ifAt: branch.sha) else {
                logger.info("[BranchPruner] Kept branch \(branch.name, privacy: .private), which moved")
                return false
            }
        } catch {
            SyncModel.logFailure("[BranchPruner] Deleting \(branch.name) failed", error)
            return false
        }
        do {
            try await removeBranchConfiguration(repository, branch.name)
        } catch {
            SyncModel.logFailure("[BranchPruner] Removing the configuration of \(branch.name) failed", error)
        }
        logger.info("[BranchPruner] Pruned branch \(branch.name, privacy: .private) ((was \(branch.sha, privacy: .public)))")
        return true
    }

    /// Records the last prune date in the repository's GitHub row.
    private func recordPruneDate(_ date: Date, for gitHubRepository: GitHubRepository) {
        app?.updateGitHubRepositories { table in
            var row = table[gitHubRepository.dbID] ?? StoredGitHubRepository(gitHubRepository)
            row.lastPruneDate = date
            table.update(row)
        }
    }
}

/// The branches rebases in progress in the repository's worktrees are
/// rebasing, as canonical refs (`refs/heads/feature`): the `head-name` of
/// each worktree's rebase state (`rebase-merge`, or a rebase's
/// `rebase-apply`), stopped on conflicts or interrupted between commits.
/// HEAD is detached during a rebase, so the branch isn't the current one;
/// the rebase's end moves it, so it must stay. Empty when the repository's
/// directories can't be found.
@concurrent
func branchesBeingRebased(_ repository: Repository) async -> Set<ExactString> {
    guard let paths = await resolveWatchedPaths(repository.path) else {
        return []
    }
    let fileManager = FileManager.default
    // The main worktree's git directory is the common directory; linked
    // worktrees have theirs under `worktrees/`.
    let worktrees = POSIXPath.join(paths.commonDirectory, "worktrees")
    let linked = ((try? fileManager.contentsOfDirectory(atPath: worktrees)) ?? []).map { POSIXPath.join(worktrees, $0) }
    var refs: Set<ExactString> = []
    for gitDirectory in [paths.commonDirectory] + linked {
        for name in ["rebase-merge", "rebase-apply"] {
            let directory = POSIXPath.join(gitDirectory, name)
            // `rebase-apply` is `git am`'s too; a rebase marks its own.
            if name == "rebase-apply", !fileManager.fileExists(atPath: POSIXPath.join(directory, "rebasing")) {
                continue
            }
            guard let data = fileManager.contents(atPath: POSIXPath.join(directory, "head-name")) else {
                continue
            }
            let headName = JSCompat.trim(String(decoding: data, as: UTF8.self))
            if JSCompat.startsWith(headName, "refs/heads/") {
                refs.insert(ExactString(headName))
            }
        }
    }
    return refs
}

/// Each local branch's upstream as a full ref, by the branch's ref:
/// `refs/remotes/origin/feature` for a branch tracking a remote branch,
/// `refs/heads/main` for one tracking a local branch (`branch.<name>.remote`
/// is `.`). A branch without an upstream, or whose upstream git can't map
/// to a ref (its remote has no fetch refspec for it), is left out.
@concurrent
private func upstreamRefsByBranch(_ repository: Repository) async throws -> [ExactString: String] {
    let parser = createForEachRefParser([
        UpstreamRefField.ref: "%(refname)",
        .upstream: "%(upstream)",
    ])
    let result = try await git(["for-each-ref"] + parser.formatArgs + ["refs/heads"], repository.path, "branchPrunerUpstreams")
    var upstreams: [ExactString: String] = [:]
    for record in try parser.parse(result.stdout) where !record[.upstream].isEmpty {
        upstreams[ExactString(record[.ref])] = record[.upstream]
    }
    return upstreams
}

private enum UpstreamRefField: Hashable, Sendable {
    case ref, upstream
}

extension SyncModel {
    /// Recreates a branch the pruner deleted, at the commit it pointed at,
    /// and takes it off `prunedBranches`. Returns after the refresh.
    public func restorePrunedBranch(_ branch: PrunedBranch) async throws(OperationError) {
        guard let repository else {
            throw notInList(.restoreBranch)
        }
        try await repository.perform(OperationDescriptor(kind: .restoreBranch, refreshAfter: .full)) { ctx in
            try await GitKit.createBranch(ctx.repository, branch.name, branch.sha)
        }
        prunedBranches.removeAll { $0 == branch }
        await repository.awaitOperationRefresh(covering: .full)
    }
}
