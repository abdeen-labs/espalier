// Ported from desktop/app/src/lib/stores/app-store.ts
//
// Each comparison has its own slot keyed by the two commits, so a result
// lands only on the comparison it was computed for.

import EspalierSupport
import Foundation
import GitKit
import Observation
import os

private let logger = Log.logger(category: "history")

/// How the compared branch's commits come into the current branch.
public enum CompareMethod: Sendable, Hashable, CaseIterable {
    case merge
    case squashMerge
    case rebase

    /// The option's label.
    public var label: String {
        switch self {
        case .merge: "Create a merge commit"
        case .squashMerge: "Squash and merge"
        case .rebase: "Rebase"
        }
    }

    /// The option's description.
    public var description: String {
        switch self {
        case .merge:
            "Adds the selected branch's commits to the current branch with a merge commit."
        case .squashMerge:
            "Combines the selected branch's commits into one commit on the current branch."
        case .rebase:
            "Replays the current branch's commits on top of the selected branch."
        }
    }

    /// The operation's name, lowercased, as the loading message names it.
    var operationName: String {
        switch self {
        case .merge: "merge"
        case .squashMerge: "squash"
        case .rebase: "rebase"
        }
    }
}

/// The comparison of the current branch with another one: how far apart
/// they are, whether merging would conflict, and what a rebase would apply.
/// `HistoryModel.compare(with:direction:)` starts one; the history's list
/// shows the commits of the chosen direction meanwhile.
@MainActor @Observable
public final class CompareModel {
    /// The compared branch, as the last comparison saw it.
    public private(set) var branch: Branch?
    /// The current branch, as the last comparison saw it.
    public private(set) var currentBranch: Branch?
    public private(set) var direction = ComparisonDirection.behind
    /// How far the current branch is ahead of and behind the compared one;
    /// nil until the comparison loads.
    public private(set) var aheadBehind: AheadBehind?
    /// Whether merging the compared branch into the current one would be
    /// clean, conflict, or can't be done (unrelated histories); `.loading`
    /// while git works it out. Nil when there's nothing to merge (the
    /// current branch isn't behind) or git failed.
    public private(set) var mergeStatus: MergeTreeResult?
    /// What rebasing the current branch onto the compared one would apply;
    /// loaded while `method` is `.rebase`.
    public private(set) var rebasePreview: RebasePreview?
    /// Whether the comparison is loading.
    public private(set) var isLoading = false

    /// How the commits would come into the current branch; choosing
    /// `.rebase` loads the rebase preview.
    public var method = CompareMethod.merge {
        didSet {
            if method == .rebase, oldValue != .rebase {
                loadRebasePreview()
            }
        }
    }

    /// The repository to load from, when there is one.
    @ObservationIgnored var context: @MainActor () -> HistoryLoadContext? = { nil }
    @ObservationIgnored private let mergeabilitySlot = LatestTask<CommitPair>()
    @ObservationIgnored private let rebasePreviewSlot = LatestTask<CommitPair>()

    /// Two commits, in order.
    private struct CommitPair: Hashable, Sendable {
        let first: String
        let second: String
    }

    init() {}

    // MARK: Copy

    /// The Behind tab's title ("Behind (n)").
    public var behindTitle: String {
        "Behind (\(formatNumber(Double(aheadBehind?.behind ?? 0))))"
    }

    /// The Ahead tab's title ("Ahead (n)").
    public var aheadTitle: String {
        "Ahead (\(formatNumber(Double(aheadBehind?.ahead ?? 0))))"
    }

    /// The message for an empty list of commits in the current direction.
    public var emptyListMessage: String? {
        guard let branch else {
            return nil
        }
        return switch direction {
        case .ahead: "The compared branch (\(branch.name)) is up to date with your branch"
        case .behind: "Your branch is up to date with the compared branch (\(branch.name))"
        }
    }

    /// The number of commits `method` would bring in: the commits behind
    /// for a merge, the current branch's commits a clean rebase would apply.
    public var commitCount: Int {
        switch method {
        case .rebase:
            if case .clean(let commitsAhead, _) = rebasePreview {
                return commitsAhead.count
            }
            return 0
        case .merge, .squashMerge:
            return aheadBehind?.behind ?? 0
        }
    }

    /// The outcome the status message shows: the rebase preview's for a
    /// rebase, the merge status's otherwise.
    public var computedAction: ComputedAction? {
        method == .rebase ? rebasePreview?.kind : mergeStatus?.kind
    }

    /// What `method` would do, or nil when there's nothing to say (no
    /// commits to bring in).
    public var statusMessage: String? {
        guard commitCount > 0, let action = computedAction, let branch, let currentBranch else {
            return nil
        }
        switch action {
        case .loading:
            return "Checking whether Git can \(method.operationName) automatically…"
        case .clean:
            let commits = commitCount == 1 ? "commit" : "commits"
            if method == .rebase {
                return "This will update \(currentBranch.name) by applying its \(commitCount) \(commits) on top of \(branch.name)"
            }
            return "This will merge \(commitCount) \(commits) from \(branch.name) into \(currentBranch.name)"
        case .invalid:
            if method == .rebase {
                return "Can't start the rebase. Check that you chose a valid branch."
            }
            return "These branches have unrelated histories and can't be merged"
        case .conflicts:
            guard method != .rebase, case .conflicts(let count) = mergeStatus else {
                return nil
            }
            let files = count == 1 ? "file" : "files"
            return "There will be \(count) conflicted \(files) when merging \(branch.name) into \(currentBranch.name)"
        }
    }

    /// Whether `method` can start: there are commits to bring in, a rebase's
    /// preview is clean, and a merge isn't between unrelated histories.
    public var canStart: Bool {
        if commitCount <= 0 {
            return false
        }
        if method == .rebase {
            if case .clean = rebasePreview {
                return true
            }
            return false
        }
        return mergeStatus?.kind != .invalid
    }

    // MARK: Updating (HistoryModel)

    /// A comparison with `branch` started.
    func begin(branch: Branch, currentBranch: Branch, direction: ComparisonDirection) {
        let isSamePair = self.branch?.tip.sha == branch.tip.sha && self.currentBranch?.tip.sha == currentBranch.tip.sha
            && self.branch?.ref == branch.ref
        if !isSamePair {
            aheadBehind = nil
            mergeStatus = nil
            rebasePreview = nil
            mergeabilitySlot.cancel()
            rebasePreviewSlot.cancel()
        }
        self.branch = branch
        self.currentBranch = currentBranch
        self.direction = direction
        isLoading = true
    }

    /// The comparison loaded: computes the merge status (only when the
    /// current branch is behind) and, for a rebase, the rebase preview.
    func didLoad(_ aheadBehind: AheadBehind) {
        isLoading = false
        self.aheadBehind = aheadBehind
        // `begin` forgot the results of another pair of commits; the same
        // pair (another direction) keeps them.
        if aheadBehind.behind > 0 {
            if mergeStatus == nil {
                loadMergeability()
            }
        } else if mergeStatus != nil || mergeabilitySlot.isRunning {
            mergeabilitySlot.cancel()
            mergeStatus = nil
        }
        if method == .rebase, rebasePreview == nil {
            loadRebasePreview()
        }
    }

    /// The comparison failed or was replaced before it loaded.
    func didFail() {
        isLoading = false
    }

    /// Back to the history: forgets the comparison.
    func reset() {
        mergeabilitySlot.cancel()
        rebasePreviewSlot.cancel()
        branch = nil
        currentBranch = nil
        direction = .behind
        aheadBehind = nil
        mergeStatus = nil
        rebasePreview = nil
        isLoading = false
        method = .merge
    }

    /// Stops the loads in flight.
    func cancelLoads() {
        if mergeabilitySlot.isRunning {
            mergeabilitySlot.cancel()
            if mergeStatus == .loading {
                mergeStatus = nil
            }
        }
        if rebasePreviewSlot.isRunning {
            rebasePreviewSlot.cancel()
            if rebasePreview == .loading {
                rebasePreview = nil
            }
        }
    }

    /// Whether a load is in flight.
    var isRunning: Bool {
        mergeabilitySlot.isRunning || rebasePreviewSlot.isRunning
    }

    /// Waits for the loads in flight.
    func idle() async {
        while isRunning {
            await mergeabilitySlot.idle()
            await rebasePreviewSlot.idle()
        }
    }

    // MARK: Loads

    /// Dry-runs merging the compared branch into the current one
    /// (`determineMergeability`), in a slot keyed by the two commits.
    private func loadMergeability() {
        guard let branch, let currentBranch, let context = context() else {
            return
        }
        mergeStatus = .loading
        mergeabilitySlot.run(
            CommitPair(first: currentBranch.tip.sha, second: branch.tip.sha),
            operation: { () async -> MergeTreeResult? in
                await context.environment.withRuntimes { () async -> MergeTreeResult? in
                    do {
                        return try await determineMergeability(context.repository, currentBranch, branch)
                    } catch {
                        logger.warning(
                            "Error occurred while trying to merge \(currentBranch.name, privacy: .public) (\(currentBranch.tip.sha, privacy: .public)) and \(branch.name, privacy: .public) (\(branch.tip.sha, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                        )
                        return nil
                    }
                }
            },
            apply: { [weak self] result in
                guard let self, case .success(let status) = result else { return }
                self.mergeStatus = status
            }
        )
    }

    /// Works out what rebasing the current branch onto the compared one
    /// would apply (with the compared branch as the base and the current
    /// branch as the target).
    private func loadRebasePreview() {
        guard let branch, let currentBranch, let context = context() else {
            return
        }
        rebasePreview = .loading
        rebasePreviewSlot.run(
            CommitPair(first: currentBranch.tip.sha, second: branch.tip.sha),
            operation: { () async -> RebasePreview? in
                await context.environment.withRuntimes { () async -> RebasePreview? in
                    do {
                        let commitsBehind = try await getCommitsBetweenCommits(
                            context.repository, currentBranch.tip.sha, branch.tip.sha
                        )
                        let commitsAhead = try await getCommitsBetweenCommits(
                            context.repository, branch.tip.sha, currentBranch.tip.sha
                        )
                        // If we are unable to find any commits to rebase,
                        // indicate that we're unable to proceed with the
                        // rebase.
                        guard let commitsBehind else {
                            return .invalid
                        }
                        return .clean(commitsAhead: commitsAhead ?? [], commitsBehind: commitsBehind)
                    } catch {
                        logger.warning("Could not preview the rebase: \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
            },
            apply: { [weak self] result in
                guard let self, case .success(let preview) = result else { return }
                self.rebasePreview = preview
            }
        )
    }
}
