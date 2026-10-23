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

/// How another branch's commits come into the current branch: the choices
/// of the call to action on a branch's Ahead.
public enum CompareMethod: String, Sendable, Hashable, CaseIterable, Identifiable {
    case merge
    case squashMerge
    case rebase

    public var id: String {
        rawValue
    }

    /// The option's label.
    public var label: String {
        switch self {
        case .merge: "Create a Merge Commit"
        case .squashMerge: "Squash and Merge"
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
    /// What merging the compared branch into the current one would do: its
    /// status is `.loading` while git works it out, then clean, conflicted,
    /// or impossible (unrelated histories), or nil when git couldn't tell;
    /// its commits are the ones behind. Nil when there's nothing to merge
    /// (the current branch isn't behind), or while the check isn't running:
    /// one stopped with the comparison's loads runs again when they resume
    /// (`resumeLoads()`). A check git couldn't make runs again when the
    /// comparison loads again or its loads resume.
    public private(set) var mergePreview: MergePreview?
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
    /// rebase, the merge preview's otherwise; nil when git couldn't check
    /// the merge (`isMergeCheckFailed`).
    public var computedAction: ComputedAction? {
        method == .rebase ? rebasePreview?.kind : mergePreview?.status?.kind
    }

    /// Whether git couldn't check what merging or squash merging would do:
    /// the status message says so, and the merge can still start.
    public var isMergeCheckFailed: Bool {
        guard method != .rebase, let mergePreview else {
            return false
        }
        return mergePreview.status == nil
    }

    /// What `method` would do, or nil when there's nothing to say (no
    /// commits to bring in).
    public var statusMessage: String? {
        guard commitCount > 0, let branch, let currentBranch else {
            return nil
        }
        if isMergeCheckFailed {
            return "Couldn't check whether this merges cleanly"
        }
        guard let action = computedAction else {
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
            guard method != .rebase, case .conflicts(let count)? = mergePreview?.status else {
                return nil
            }
            let files = count == 1 ? "file" : "files"
            return "There will be \(count) conflicted \(files) when merging \(branch.name) into \(currentBranch.name)"
        }
    }

    /// Whether `method` can start: there are commits to bring in, and a
    /// rebase's preview is clean, or a merge's check allows it
    /// (`MergePreview.canStart`).
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
        return mergePreview?.canStart ?? false
    }

    // MARK: Updating (HistoryModel)

    /// A comparison with `branch` started.
    func begin(branch: Branch, currentBranch: Branch, direction: ComparisonDirection) {
        let isSamePair = self.branch?.tip.sha == branch.tip.sha && self.currentBranch?.tip.sha == currentBranch.tip.sha
            && self.branch?.ref == branch.ref
        if !isSamePair {
            aheadBehind = nil
            mergePreview = nil
            rebasePreview = nil
            mergeabilitySlot.cancel()
            rebasePreviewSlot.cancel()
        }
        self.branch = branch
        self.currentBranch = currentBranch
        self.direction = direction
        isLoading = true
    }

    /// The comparison loaded: checks the merge (only when the current
    /// branch is behind) and, for a rebase, the rebase preview.
    func didLoad(_ aheadBehind: AheadBehind) {
        isLoading = false
        self.aheadBehind = aheadBehind
        // `begin` forgot the results of another pair of commits; the same
        // pair (another direction) keeps them, but for a check git couldn't
        // make.
        if aheadBehind.behind > 0 {
            if needsMergeCheck {
                loadMergeability()
            }
        } else if mergePreview != nil || mergeabilitySlot.isRunning {
            mergeabilitySlot.cancel()
            mergePreview = nil
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
        mergePreview = nil
        rebasePreview = nil
        isLoading = false
        method = .merge
    }

    /// Stops the loads in flight.
    func cancelLoads() {
        if mergeabilitySlot.isRunning {
            mergeabilitySlot.cancel()
            if mergePreview?.status == .loading {
                mergePreview = nil
            }
        }
        if rebasePreviewSlot.isRunning {
            rebasePreviewSlot.cancel()
            if rebasePreview == .loading {
                rebasePreview = nil
            }
        }
    }

    /// Runs again the checks `cancelLoads()` stopped, and a merge check git
    /// couldn't make: the merge's, while the current branch is behind, and a
    /// rebase's preview.
    func resumeLoads() {
        guard !isLoading, let aheadBehind else {
            return
        }
        if aheadBehind.behind > 0, needsMergeCheck, !mergeabilitySlot.isRunning {
            loadMergeability()
        }
        if method == .rebase, rebasePreview == nil, !rebasePreviewSlot.isRunning {
            loadRebasePreview()
        }
    }

    /// Whether the merge check is to run: it hasn't, it was stopped, or git
    /// couldn't make it.
    private var needsMergeCheck: Bool {
        guard let mergePreview else {
            return true
        }
        return mergePreview.status == nil
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
    /// (`determineMergeability`), in a slot keyed by the two commits; a
    /// failure leaves the preview's status nil.
    private func loadMergeability() {
        guard let branch, let currentBranch, let context = context() else {
            return
        }
        let commitCount = aheadBehind?.behind
        mergePreview = MergePreview(status: .loading, commitCount: commitCount)
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
                self.mergePreview = MergePreview(status: status, commitCount: commitCount)
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
