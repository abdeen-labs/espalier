// Ported from desktop/app/src/lib/stores/app-store.ts
//
// Every load runs in a `LatestTask` slot keyed by what it loads, so only the
// latest one applies and a stale changeset never lands on a newer
// selection. Clearing the selection replaces it as one value.

import EspalierSupport
import Foundation
import GitKit
import Observation

extension CommitSelection {
    /// The selected commits the diff doesn't show: in a history that
    /// interleaves branches, a contiguous selection's range can leave out
    /// commits that aren't ancestors of the newest one. Empty when every
    /// selected commit is in the diff.
    public var unreachableSHAs: [String] {
        let inDiff = shasInDiff.exactSet
        return shas.filter { !inDiff.contains(ExactString($0)) }
    }

    /// Whether the selection has changes to show: one commit, or a
    /// contiguous range (nothing else is diffed).
    public var hasDiff: Bool {
        shas.count == 1 || (shas.count > 1 && isContiguous)
    }
}

/// When multiple commits are selected, the diff is created using the rev
/// range of firstSha^..lastSha in the selected shas. Thus comparing the trees
/// of the the lastSha and the first parent of the first sha. However, our
/// history list shows commits in chronological order. Thus, when a branch is
/// merged, the commits from that branch are injected in their chronological
/// order into the history list. Therefore, given a branch history of A, B, C,
/// D, MergeCommit where B and C are from the merged branch, diffing on the
/// selection of A through D would not have the changes from B an C.
///
/// This method traverses the ancestral path from the last commit in the
/// selection back to the first commit via checking the parents. The commits
/// on this path are the commits whose changes will be seen in the diff. This
/// is equivalent to doing `git rev-list firstSha^..lastSha`.
///
/// - Parameter selectedShas: The selection, oldest first
///   (`orderShasByHistory`).
func getShasInDiff(_ selectedShas: [String], isContiguous: Bool, parents: (String) -> [String]?) -> [String] {
    guard selectedShas.count > 1, isContiguous, let newest = selectedShas.last else {
        return selectedShas
    }

    var shasInDiff: [String] = []
    var inDiff: Set<ExactString> = []
    let selected = selectedShas.exactSet
    var shasToTraverse = [newest]

    while let sha = shasToTraverse.popLast() {
        if inDiff.insert(ExactString(sha)).inserted {
            shasInDiff.append(sha)
            for parentSha in parents(sha) ?? [] {
                if selected.contains(ExactString(parentSha)), !inDiff.contains(ExactString(parentSha)) {
                    shasToTraverse.append(parentSha)
                }
            }
        }
    }

    return shasInDiff
}

/// Multi selection on the commit list can give an order of 1, 5, 3 if that
/// is how the user selected them. However, sometimes we want them in
/// chronological ordering of the commits such as when get a range files
/// changed. Thus, assuming 1 is the first commit made by the user and 5 is
/// the last. We want the order to be, 1, 3, 5.
///
/// - Parameter index: A commit's position in the list (newest first), or nil
///   when it isn't listed. Unlisted commits keep their order after the
///   listed ones.
func orderShasByHistory(_ shas: [String], index: (String) -> Int?) -> [String] {
    let positions = shas.enumerated().map { (offset: $0.offset, sha: $0.element, index: index($0.element)) }
    return positions.sorted { lhs, rhs in
        switch (lhs.index, rhs.index) {
        case let (left?, right?):
            left != right ? left > right : lhs.offset < rhs.offset
        case (.some, nil):
            true
        case (nil, .some):
            false
        case (nil, nil):
            lhs.offset < rhs.offset
        }
    }.map(\.sha)
}

/// What a load needs from the repository, captured on the main actor.
struct HistoryLoadContext: Sendable {
    let repository: Repository
    let environment: AppEnvironment
    let record: RepositoryRecord

    /// `error` as the operation `kind`'s failure, classified as an
    /// operation's would be (without the side effects).
    func failure(_ error: any Error, _ kind: OperationKind) async -> OperationError {
        await ErrorClassifier.classify(
            error,
            descriptor: OperationDescriptor(kind: kind, lanes: [], policy: .user, refreshAfter: []),
            record: record,
            context: ClassificationContext()
        )
    }
}

/// A commit selection and the loads that fill it: the changed files of the
/// selected commits, then the selected file's diff.
@MainActor @Observable
final class CommitSelectionLoader {
    /// Where the selection's changes come from.
    enum Source: Sendable, Hashable {
        /// Commits of a history or comparison: one commit's own changes, or
        /// a contiguous range's.
        case commits
        /// A pull request's changes from the merge base of `base` and
        /// `head` (refs or SHAs); `latestCommit` is the newest commit.
        case mergeBase(base: String, head: String, latestCommit: String)
    }

    private struct DiffKey: Hashable, Sendable {
        let shas: [String]
        let source: Source
        let fileID: String
        let hideWhitespace: Bool
    }

    private(set) var selection = CommitSelection()

    @ObservationIgnored private var source = Source.commits
    /// The selection oldest first, as the range loads take it.
    @ObservationIgnored private var orderedShas: [String] = []
    /// The repository to load from, when there is one.
    @ObservationIgnored var context: @MainActor () -> HistoryLoadContext? = { nil }
    /// Whether diffs hide whitespace changes (the owning model's preference).
    @ObservationIgnored var hideWhitespace: @MainActor () -> Bool = { false }
    @ObservationIgnored private let changesetSlot = LatestTask<[String]>()
    @ObservationIgnored private let diffSlot = LatestTask<DiffKey>()

    init() {}

    // MARK: Selecting

    /// Selects commits of a history or comparison and loads their changes: the
    /// changed files, then the first file's diff. Nothing happens when the same
    /// commits are selected in the same order and their changes are loaded or
    /// loading.
    ///
    /// - Parameters:
    ///   - orderedShas: `shas` oldest first (`orderShasByHistory`).
    ///   - parents: A commit's parents, for `shasInDiff`.
    func select(shas: [String], contiguous: Bool, orderedShas: [String], parents: (String) -> [String]?) {
        if source == .commits, selection.isContiguous == contiguous, selection.shas.count == shas.count,
           zip(selection.shas, shas).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) {
            resumeLoads()
            return
        }
        source = .commits
        self.orderedShas = orderedShas
        var selection = CommitSelection()
        selection.shas = shas
        selection.shasInDiff = getShasInDiff(orderedShas, isContiguous: contiguous, parents: parents)
        selection.isContiguous = contiguous
        diffSlot.cancel()
        self.selection = selection
        loadChangeset()
    }

    /// Shows a pull request's changes from the merge base: every commit, the
    /// changed files loaded with the preview, then the first file's diff.
    func showMergeBaseChanges(commitSHAs: [String], changeset: ChangesetData, source: Source) {
        self.source = source
        orderedShas = commitSHAs.reversed()
        changesetSlot.cancel()
        diffSlot.cancel()
        var selection = CommitSelection()
        selection.shas = commitSHAs
        selection.shasInDiff = commitSHAs
        selection.isContiguous = true
        selection.changeset = .loaded(changeset)
        self.selection = selection
        if let first = changeset.files.first {
            selectFile(first)
        }
    }

    /// Clears the selection and stops its loads.
    func clear() {
        changesetSlot.cancel()
        diffSlot.cancel()
        source = .commits
        orderedShas = []
        if selection != CommitSelection() {
            selection = CommitSelection()
        }
    }

    /// Stops the loads in flight; what's loaded stays.
    func cancelLoads() {
        if changesetSlot.isRunning {
            changesetSlot.cancel()
            if selection.changeset.isLoading {
                selection.changeset = .idle
            }
        }
        if diffSlot.isRunning {
            diffSlot.cancel()
            if selection.diff.isLoading {
                selection.diff = .idle
            }
        }
    }

    /// Loads what `cancelLoads()` stopped: the changed files, or the
    /// selected file's diff.
    func resumeLoads() {
        guard selection.hasDiff, context() != nil else {
            return
        }
        if source == .commits, selection.changeset == .idle, !changesetSlot.isRunning {
            loadChangeset()
        } else if let file = selection.file, selection.diff == .idle, !diffSlot.isRunning {
            selectFile(file)
        }
    }

    /// Whether a load is in flight.
    var isRunning: Bool {
        changesetSlot.isRunning || diffSlot.isRunning
    }

    /// Waits for the loads in flight, including the diff a changeset starts.
    func idle() async {
        while isRunning {
            await changesetSlot.idle()
            await diffSlot.idle()
        }
    }

    // MARK: Files

    /// Selects a changed file and loads its diff. Nil clears the file.
    func selectFile(_ file: CommittedFileChange?) {
        selection.file = file
        guard let file, selection.hasDiff, let context = context() else {
            diffSlot.cancel()
            if selection.diff != .idle {
                selection.diff = .idle
            }
            return
        }
        selection.diff = selection.diff.reloading
        let hideWhitespace = hideWhitespace()
        let shas = selection.shas
        let orderedShas = orderedShas
        let source = source
        diffSlot.run(
            DiffKey(shas: shas, source: source, fileID: file.id, hideWhitespace: hideWhitespace),
            operation: { () async -> Result<Diff, OperationError> in
                await context.environment.withRuntimes { () async -> Result<Diff, OperationError> in
                    do {
                        let diff: Diff
                        switch source {
                        case .commits where shas.count > 1:
                            diff = try await getCommitRangeDiff(
                                context.repository, file, orderedShas, hideWhitespaceInDiff: hideWhitespace
                            )
                        case .commits:
                            diff = try await getCommitDiff(context.repository, file, shas[0], hideWhitespaceInDiff: hideWhitespace)
                        case .mergeBase(let base, let head, let latestCommit):
                            diff = try await getBranchMergeBaseDiff(
                                context.repository, file, base, head,
                                hideWhitespaceInDiff: hideWhitespace, latestCommit: latestCommit
                            )
                        }
                        return .success(diff)
                    } catch {
                        return .failure(await context.failure(error, .loadDiff))
                    }
                }
            },
            apply: { [weak self] result in
                guard let self, case .success(let loaded) = result else { return }
                self.selection.diff = Loadable(loaded)
            }
        )
    }

    /// Loads the selected file's diff again (whitespace shown or hidden).
    func reloadDiff() {
        if let file = selection.file {
            selectFile(file)
        }
    }

    // MARK: Changesets

    /// Loads the changed files of the selected commits: nothing for no
    /// commits or a selection that isn't contiguous.
    private func loadChangeset() {
        let shas = selection.shas
        guard selection.hasDiff, let context = context() else {
            changesetSlot.cancel()
            return
        }
        let orderedShas = orderedShas
        selection.changeset = .loading(previous: nil)
        changesetSlot.run(
            shas,
            operation: { () async -> Result<ChangesetData, OperationError> in
                await context.environment.withRuntimes { () async -> Result<ChangesetData, OperationError> in
                    do {
                        if orderedShas.count > 1 {
                            return .success(try await getCommitRangeChangedFiles(context.repository, orderedShas))
                        }
                        return .success(try await getChangedFiles(context.repository, shas[0]))
                    } catch {
                        return .failure(await context.failure(error, .loadDiff))
                    }
                }
            },
            apply: { [weak self] result in
                guard let self, case .success(let loaded) = result else { return }
                self.selection.changeset = Loadable(loaded)
                // If we're selecting a commit for the first time, we should
                // select the first file in the commit and render the diff
                // immediately.
                if case .success(let changeset) = loaded, self.selection.file == nil, let first = changeset.files.first {
                    self.selectFile(first)
                }
            }
        )
    }
}
