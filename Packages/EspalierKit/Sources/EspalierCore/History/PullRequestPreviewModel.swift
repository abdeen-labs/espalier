// Ported from desktop/app/src/lib/stores/app-store.ts
//
// An open pull request's changes show this way too, when its head commit is
// in the repository. Commits are pinned by SHA when the preview loads, so
// the file list and every diff describe the same commits.

import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Observation
import os

private let logger = Log.logger(category: "history")

/// The changes a pull request would bring: its commits, the files changed
/// since the merge base, and whether it merges cleanly.
@MainActor @Observable
public final class PullRequestPreviewModel {
    public enum Status: Sendable, Equatable {
        /// Nothing is previewed.
        case idle
        case loading
        /// There's no base branch to compare against.
        case noBaseBranch
        /// The pull request's head commit isn't in the repository: check it
        /// out (or fetch) to see its changes.
        case changesNotAvailable
        case loaded
        case failed(OperationError)
    }

    public private(set) var status = Status.idle
    /// The branch the pull request merges into (a preview's).
    public private(set) var baseBranch: Branch?
    /// The branch the pull request comes from (a preview's: the current
    /// branch).
    public private(set) var headBranch: Branch?
    /// The pull request shown (`showChanges(of:)`).
    public private(set) var pullRequest: PullRequest?
    /// The pull request's commits, newest first; empty when the branches
    /// share no history.
    public private(set) var commits: [Commit] = []
    /// Whether the branches share history. When they don't, nothing can be
    /// merged.
    public private(set) var hasMergeBase = true
    /// Whether the pull request merges cleanly into its base; nil without
    /// commits, or when git failed.
    public private(set) var mergeStatus: MergeTreeResult?

    /// The commits, the files changed since the merge base, and the
    /// selected file's diff.
    public var selection: CommitSelection {
        loader.selection
    }

    /// The pull request's commits' SHAs, newest first.
    public var commitSHAs: [String] {
        commits.map(\.sha)
    }

    @ObservationIgnored weak var repository: RepositoryModel?
    @ObservationIgnored private let request = LatestRequest()
    @ObservationIgnored private let mergeabilitySlot = LatestTask<[String]>()
    @ObservationIgnored private let loader = CommitSelectionLoader()

    init() {
        loader.context = { [weak self] in self?.loadContext() }
        loader.hideWhitespace = { [weak self] in
            self?.repository?.app?.preferences.hideWhitespaceInPullRequestDiff ?? false
        }
    }

    // MARK: Previewing

    /// Previews a pull request from the current branch into `base`: its commits
    /// (`base..current`), the files changed since the merge base, the first
    /// file's diff, and its mergeability. Without a base branch, the status is
    /// `.noBaseBranch`. Nothing happens unless HEAD is on a branch with
    /// commits.
    func preview(base: Branch?) async {
        guard let repository, case .valid(let currentBranch) = repository.gitState.tip else {
            return
        }
        guard let base else {
            show(.noBaseBranch, base: nil, head: currentBranch, pullRequest: nil)
            return
        }
        show(.loading, base: base, head: currentBranch, pullRequest: nil)
        await load(baseSHA: base.tip.sha, headSHA: currentBranch.tip.sha)
    }

    /// Shows an open pull request's changes since the merge base of its head
    /// and its base, when the head commit is in the repository; otherwise
    /// the status is `.changesNotAvailable`. The base is the remote-tracking
    /// branch of the base repository's remote, when there is one, else the
    /// commit GitHub reported.
    public func showChanges(of pullRequest: PullRequest) async {
        guard let repository, let context = loadContext() else {
            return
        }
        show(.loading, base: nil, head: nil, pullRequest: pullRequest)
        let baseRefs = repository.gitState.remotes.all
            .filter { repositoryMatchesRemote(pullRequest.base.gitHubRepository, remoteURL: $0.url) }
            .map { "refs/remotes/\($0.name)/\(pullRequest.base.ref)" }
        let resolved = await request.perform { () async -> PullRequestCommits in
            await context.environment.withRuntimes { () async -> PullRequestCommits in
                guard let head = await resolveHistoryCommit(context.repository, pullRequest.head.sha) else {
                    return .unavailable
                }
                for ref in baseRefs {
                    if let base = await resolveHistoryCommit(context.repository, ref) {
                        return .available(base: base, head: head)
                    }
                }
                guard let base = await resolveHistoryCommit(context.repository, pullRequest.base.sha) else {
                    return .unavailable
                }
                return .available(base: base, head: head)
            }
        }
        guard let resolved, self.pullRequest == pullRequest else {
            return
        }
        switch resolved {
        case .unavailable:
            status = .changesNotAvailable
        case .available(let base, let head):
            await load(baseSHA: base, headSHA: head)
        }
    }

    /// Previews against another base branch.
    public func setBaseBranch(_ base: Branch) async {
        guard pullRequest == nil, status != .idle else {
            return
        }
        await preview(base: base)
    }

    /// Selects a changed file and loads its diff from the merge base.
    public func selectFile(_ file: CommittedFileChange?) {
        loader.selectFile(file)
    }

    /// Hides or shows whitespace changes in pull request diffs (the
    /// `hide-whitespace-in-pull-request-diff` preference) and reloads the
    /// diff.
    public func setHideWhitespaceInDiff(_ hide: Bool) {
        if let preferences = repository?.app?.preferences, preferences.hideWhitespaceInPullRequestDiff != hide {
            preferences.hideWhitespaceInPullRequestDiff = hide
        }
        loader.reloadDiff()
    }

    /// Stops previewing.
    public func close() {
        request.cancel()
        mergeabilitySlot.cancel()
        loader.clear()
        show(.idle, base: nil, head: nil, pullRequest: nil)
    }

    /// Stops the loads in flight; what's loaded stays.
    func cancelLoads() {
        if request.isRunning {
            request.cancel()
            if status == .loading {
                status = .idle
            }
        }
        if mergeabilitySlot.isRunning {
            mergeabilitySlot.cancel()
            if mergeStatus == .loading {
                mergeStatus = nil
            }
        }
        loader.cancelLoads()
    }

    /// Whether a load is in flight.
    var isRunning: Bool {
        request.isRunning || mergeabilitySlot.isRunning || loader.isRunning
    }

    /// Waits for the loads in flight.
    func idle() async {
        while isRunning {
            await request.idle()
            await mergeabilitySlot.idle()
            await loader.idle()
        }
    }

    // MARK: Copy

    /// The summary of what merging would do: "Merge 3 commits into main from
    /// feature."
    public var summary: String? {
        guard let baseBranch, let headBranch, status == .loaded else {
            return nil
        }
        let count = commits.count
        return "Merge \(count) commit\(count > 1 ? "s" : "") into \(baseBranch.name) from \(headBranch.name)."
    }

    /// Why there's nothing to show, as a title and a message: no changes,
    /// unrelated histories, or no base branch.
    public var emptyMessage: (title: String, message: String)? {
        switch status {
        case .noBaseBranch:
            return ("Could not find a default branch to compare against.", "Select a base branch above.")
        case .loaded where commits.isEmpty:
            let base = baseBranch?.name ?? pullRequest?.base.ref ?? ""
            let head = headBranch?.name ?? pullRequest?.head.ref ?? ""
            if hasMergeBase {
                return ("There are no changes.", "\(base) is up to date with all commits from \(head).")
            }
            return ("There are no changes.", "\(base) and \(head) are entirely different commit histories.")
        default:
            return nil
        }
    }

    /// The merge status in words: a bold part and the rest.
    public var mergeStatusMessage: (title: String, message: String)? {
        switch mergeStatus {
        case nil:
            return nil
        case .loading:
            return ("Checking mergeability…", "You can still create the pull request.")
        case .invalid:
            return ("Error checking merge status.", "These branches have unrelated histories and can't be merged")
        case .clean:
            return ("Able to merge.", "These branches can be automatically merged.")
        case .conflicts:
            return ("Can't automatically merge.", "You can still create the pull request.")
        }
    }

    /// The branches a preview can merge into: those of the `upstream` remote
    /// for a fork contributing to its parent, else of the default remote.
    public var baseBranchCandidates: [Branch] {
        guard let repository else {
            return []
        }
        let remote = pullRequestRemoteName(repository)
        return repository.gitState.branches.all.filter { isOnRemote($0, remote) }
    }

    /// The newest commit, when it has been pushed: files can be viewed on
    /// GitHub at it.
    public var nonLocalCommitSHA: String? {
        guard let newest = commits.first?.sha, let repository else {
            return nil
        }
        return repository.gitState.localCommitSHAs.contains(newest) ? nil : newest
    }

    // MARK: Loading

    private func show(_ status: Status, base: Branch?, head: Branch?, pullRequest: PullRequest?) {
        request.cancel()
        mergeabilitySlot.cancel()
        loader.clear()
        self.status = status
        baseBranch = base
        headBranch = head
        self.pullRequest = pullRequest
        commits = []
        hasMergeBase = true
        mergeStatus = nil
    }

    /// Loads the commits from `baseSHA` to `headSHA`, the files changed since
    /// their merge base, and the mergeability.
    private func load(baseSHA: String, headSHA: String) async {
        guard let context = loadContext() else {
            return
        }
        let loaded = await request.perform { () async -> Result<LoadedPreview, OperationError> in
            await context.environment.withRuntimes { () async -> Result<LoadedPreview, OperationError> in
                do {
                    let commits = try await getCommits(context.repository, revRange(baseSHA, headSHA))
                    // A user may compare two branches with no changes
                    // between them.
                    let changeset: ChangesetData? = if let newest = commits.first {
                        try await getBranchMergeBaseChangedFiles(context.repository, baseSHA, headSHA, newest.sha)
                    } else {
                        ChangesetData(files: [], linesAdded: 0, linesDeleted: 0)
                    }
                    return .success(LoadedPreview(commits: commits, changeset: changeset))
                } catch {
                    return .failure(await context.failure(error, .loadHistory))
                }
            }
        }
        guard let loaded else {
            return
        }
        switch loaded {
        case .failure(let error):
            status = .failed(error)
        case .success(let result):
            hasMergeBase = result.changeset != nil
            // We don't care how many commits exist on the unrelated history
            // that can't be merged.
            commits = hasMergeBase ? result.commits : []
            status = .loaded
            let empty = ChangesetData(files: [], linesAdded: 0, linesDeleted: 0)
            loader.showMergeBaseChanges(
                commitSHAs: commitSHAs,
                changeset: result.changeset ?? empty,
                source: .mergeBase(base: baseSHA, head: headSHA, latestCommit: commits.first?.sha ?? headSHA)
            )
            if !commits.isEmpty {
                loadMergeability(baseSHA: baseSHA, headSHA: headSHA, context: context)
            } else {
                mergeStatus = hasMergeBase ? nil : .invalid
            }
        }
    }

    private func loadMergeability(baseSHA: String, headSHA: String, context: HistoryLoadContext) {
        mergeStatus = .loading
        let base = Branch(name: baseBranch?.name ?? baseSHA, upstream: nil, tip: BranchTip(sha: baseSHA), type: .local, ref: baseSHA)
        let head = Branch(name: headBranch?.name ?? headSHA, upstream: nil, tip: BranchTip(sha: headSHA), type: .local, ref: headSHA)
        mergeabilitySlot.run(
            [baseSHA, headSHA],
            operation: { () async -> MergeTreeResult? in
                await context.environment.withRuntimes { () async -> MergeTreeResult? in
                    do {
                        return try await determineMergeability(context.repository, base, head)
                    } catch {
                        logger.warning(
                            "Error occurred while trying to merge \(base.name, privacy: .public) (\(baseSHA, privacy: .public)) and \(head.name, privacy: .public) (\(headSHA, privacy: .public)): \(error.localizedDescription, privacy: .public)"
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

    private func loadContext() -> HistoryLoadContext? {
        guard let repository else {
            return nil
        }
        return HistoryLoadContext(repository: repository.gitRepository, environment: repository.environment, record: repository.record)
    }
}

/// A pull request's commits, if they're in the repository.
private enum PullRequestCommits: Sendable {
    case available(base: String, head: String)
    case unavailable
}

/// What a preview loads: the commits, and the files changed since the merge
/// base (nil when there's none).
private struct LoadedPreview: Sendable {
    let commits: [Commit]
    let changeset: ChangesetData?
}

/// The remote a pull request goes to: `upstream` for a fork contributing to
/// its parent, else the default remote.
@MainActor
private func pullRequestRemoteName(_ repository: RepositoryModel) -> String? {
    isForkedRepositoryContributingToParent(repository.record)
        ? upstreamRemoteName
        : repository.gitState.remotes.defaultRemote?.name
}

/// Whether `branch` is on `remote` or tracks a branch there.
private func isOnRemote(_ branch: Branch, _ remote: String?) -> Bool {
    guard let remote else {
        return false
    }
    return branch.upstreamRemoteName == remote || (try? branch.remoteName) == remote
}

/// The full SHA of the commit `revision` names, if it's in the repository.
@concurrent
func resolveHistoryCommit(_ repository: Repository, _ revision: String) async -> String? {
    guard !revision.isEmpty, !JSCompat.startsWith(revision, "-"),
          let result = try? await git(
              ["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"],
              repository.path,
              "resolveHistoryCommit",
              options: GitExecutionOptions(successExitCodes: [0, 1, 128])
          ),
          result.exitCode == 0
    else {
        return nil
    }
    let sha = JSCompat.trim(result.stdout)
    return sha.isEmpty ? nil : sha
}
