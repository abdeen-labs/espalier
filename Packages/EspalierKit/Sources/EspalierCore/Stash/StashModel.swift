// The primitives operations share are in StashPrimitives.swift.

import EspalierSupport
import Foundation
import GitKit
import Observation
import os

private let logger = Log.logger(category: "stash")

/// Restores a stash entry again.
public struct PopStashRetry: RetryableOperation {
    public let repositoryID: RepositoryID
    public let entry: StashEntry

    public init(repositoryID: RepositoryID, entry: StashEntry) {
        self.repositoryID = repositoryID
        self.entry = entry
    }

    public var kind: OperationKind {
        .restoreStash
    }

    public var displayName: String? {
        entry.branchName
    }

    @discardableResult
    @MainActor
    public func perform(in app: AppModel) async throws(OperationError) -> OperationOutcome {
        try await app.requireRepository(repositoryID, for: kind).stash.restore(entry)
        return .nothing
    }
}

/// A stash entry whose changes came back with conflicts. Git kept the
/// entry; it's dropped once the conflicts are resolved with the changes
/// kept, so discarding the conflicted changes doesn't lose them.
public struct ConflictedStashRestore: Sendable, Equatable {
    /// The entry, still in the stash list.
    public let entry: StashEntry
    /// The files that conflicted.
    public let paths: [String]
    /// HEAD when the entry was restored: a file the resolution left as HEAD
    /// had it lost the stash's changes, so the entry stays.
    let baseTip: String?
}

/// The stash entries' files and diffs, and stashing.
@MainActor @Observable
public final class StashModel: RepositoryFeature {
    /// The stash entry shown instead of the working directory, if any.
    public private(set) var shownEntry: StashEntry?
    /// The shown entry's files.
    public private(set) var files: Loadable<[CommittedFileChange], OperationError> = .idle
    /// The selected stashed file, while the stash is shown.
    public private(set) var selectedFile: CommittedFileChange?
    /// The selected stashed file's diff, against the commit the stash was
    /// made on.
    public private(set) var diff: Loadable<Diff, OperationError> = .idle
    /// A restored entry kept because its changes conflicted, until the
    /// conflicts are resolved.
    public private(set) var conflictedRestore: ConflictedStashRestore?
    /// How many files each listed entry changes, by stash SHA, as
    /// `countFiles()` counts them (StashFileCounts.swift). A stash never
    /// changes, so it's counted once.
    public internal(set) var fileCounts: [String: Int] = [:]

    @ObservationIgnored weak var repository: RepositoryModel?

    @ObservationIgnored let fileLoads = LatestTask<String>()
    @ObservationIgnored let diffLoads = LatestTask<StashDiffKey>()
    /// Counts the listed entries' files (StashFileCounts.swift).
    @ObservationIgnored let countLoads = LatestTask<[String]>()
    /// The last file list loaded, by stash SHA (a stash's files never change).
    @ObservationIgnored var cachedFiles: (stashSha: String, files: [CommittedFileChange])?
    /// The load `diff` holds or waits for.
    @ObservationIgnored var diffKey: StashDiffKey?
    /// Settles `conflictedRestore` once its conflicts are gone.
    @ObservationIgnored var restoreSettlement: Task<Void, Never>?

    init() {}

    func attach(to repository: RepositoryModel) {
        self.repository = repository
    }

    /// The current branch's stash entry: none unless HEAD is on a branch.
    public var current: StashEntry? {
        guard let repository, let branch = repository.gitState.tip.branch else {
            return nil
        }
        return repository.gitState.stashes.entriesByBranch[branch.name]
    }

    /// Whether a stash entry is shown instead of the working directory.
    public var isShowing: Bool {
        shownEntry != nil && repository?.changes.isShowingStash == true
    }

    // MARK: Stashing

    /// Stashes every change as the current branch's stash, replacing its
    /// previous one.
    ///
    /// - Returns: Whether a stash was made: false without a branch (detached
    ///   or unborn) or without changes.
    /// - Throws: `.confirmationRequired(.overwriteStash)` when the branch
    ///   has a stash and it isn't confirmed.
    @discardableResult
    public func stashAllChanges(confirmed: Set<ConfirmationKind> = []) async throws(OperationError) -> Bool {
        guard let repository, let branch = repository.gitState.tip.branch else {
            return false
        }
        if current != nil, !confirmed.contains(.overwriteStash) {
            throw OperationError(
                .confirmationRequired(.overwriteStash(checkingOut: nil)),
                operation: .stash,
                repositoryID: repository.id
            )
        }
        let created = try await repository.perform(OperationDescriptor(kind: .stash)) { ctx in
            try await self.createStashAndDropPreviousEntry(for: branch, in: ctx)
        }
        // Returns after the refresh, so a retry that follows (the "Stash
        // Changes and Continue" recovery) sees the clean tree.
        if created {
            await repository.awaitOperationRefresh(covering: .full)
        }
        return created
    }

    // MARK: Restoring and dropping

    /// Restores (pops) `entry`, the current branch's stash, into the working
    /// directory. Returns after the refresh.
    ///
    /// When the changes conflict, git keeps the entry: `conflictedRestore`
    /// records it, and it's dropped once the conflicts are resolved with the
    /// changes kept.
    ///
    /// - Throws: `.precondition` for another branch's entry ("Switch to
    ///   <branch> to restore these changes."), while an operation or the
    ///   working directory has conflicts; `.localChangesOverwritten` (with no
    ///   "Stash Changes and Continue") when changes are in the way; the
    ///   classified git error otherwise. The entry is kept.
    public func restore(_ entry: StashEntry) async throws(OperationError) {
        guard let repository else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .restoreStash)
        }
        guard let branch = repository.gitState.tip.branch, JSCompat.strictEquals(branch.name, entry.branchName) else {
            throw OperationError(
                .precondition("Switch to \(entry.branchName) to restore these changes."),
                operation: .restoreStash,
                repositoryID: repository.id
            )
        }
        try repository.operations.requireNoOperationInProgress(.restoreStash)
        if repository.changes.workingDirectory.files.contains(where: { $0.status.kind == .conflicted }) {
            throw OperationError(
                .precondition("Resolve the conflicts in your changes before restoring stashed changes."),
                operation: .restoreStash,
                repositoryID: repository.id
            )
        }

        let descriptor = OperationDescriptor(kind: .restoreStash, retry: PopStashRetry(repositoryID: repository.id, entry: entry))
        try await repository.perform(descriptor) { ctx in
            try await self.popStashPrimitive(entry, in: ctx)
            logger.info("Popped stash with commit id \(entry.stashSha, privacy: .public)")
        }
        await repository.awaitOperationRefresh(covering: .full)
    }

    /// Drops `entry`, permanently. Returns after the stash list reloads.
    ///
    /// - Throws: `.confirmationRequired(.discardStash)` when
    ///   `confirmDiscardStash` is on ("Discard Stash?").
    public func discard(_ entry: StashEntry, confirmed: Set<ConfirmationKind> = []) async throws(OperationError) {
        guard let repository, let app = repository.app else {
            throw OperationError(.precondition("The repository is no longer in the list."), operation: .dropStash)
        }
        if app.preferences.confirmDiscardStash, !confirmed.contains(.discardStash) {
            throw OperationError(.confirmationRequired(.discardStash()), operation: .dropStash, repositoryID: repository.id)
        }
        try await repository.perform(OperationDescriptor(kind: .dropStash, refreshAfter: .refs)) { ctx in
            try await dropDesktopStashEntry(ctx.repository, entry.stashSha)
            logger.info("Dropped stash with commit id \(entry.stashSha, privacy: .public)")
        }
        if let pending = conflictedRestore, JSCompat.strictEquals(pending.entry.stashSha, entry.stashSha) {
            conflictedRestore = nil
        }
        await repository.awaitOperationRefresh(covering: .refs)
    }

    // MARK: Showing

    /// Shows the current branch's stash instead of the working directory,
    /// selecting `file`, or when nil the file already selected, or else the
    /// first. Does nothing without a stash.
    public func show(file: CommittedFileChange?) {
        guard let current else {
            return
        }
        show(current, file: file)
    }

    /// Shows `entry` (the current branch's or another branch's) instead of
    /// the working directory, selecting `file`, or when nil the file
    /// already selected, or else the first. Its files load once; its diffs
    /// load as files are selected.
    public func show(_ entry: StashEntry, file: CommittedFileChange? = nil) {
        let requested: FileRequest = if let file {
            .file(file.id)
        } else if let selectedFile {
            .keep(selectedFile.id)
        } else {
            .first
        }
        show(entry, requested)
    }

    private func show(_ entry: StashEntry, _ requested: FileRequest) {
        guard let repository else {
            return
        }
        let sameEntry = shownEntry.map { JSCompat.strictEquals($0.stashSha, entry.stashSha) } ?? false
        if shownEntry != entry {
            shownEntry = entry
        }
        if !sameEntry {
            selectedFile = nil
            diffLoads.cancel()
            diffKey = nil
            diff = .idle
        }
        repository.changes.showStash(fileID: selectedFile?.id)

        if let cached = cachedFiles, JSCompat.strictEquals(cached.stashSha, entry.stashSha) {
            setFiles(.loaded(cached.files))
            select(requested, from: cached.files, in: entry)
            return
        }

        setFiles(.loading(previous: nil))
        let gitRepository = repository.gitRepository
        let environment = repository.environment
        let record = repository.record
        let sha = entry.stashSha
        fileLoads.run(sha, operation: {
            await environment.withRuntimes {
                do {
                    return .success(try await getStashedFiles(gitRepository, sha))
                } catch {
                    return .failure(await classifyLoadFailure(error, kind: .loadStashedChanges, record: record))
                }
            }
        }, apply: { [weak self] (result: Result<Result<[CommittedFileChange], OperationError>, any Error>) in
            guard let self, let shown = self.shownEntry, JSCompat.strictEquals(shown.stashSha, sha),
                  case .success(let loaded) = result
            else {
                return
            }
            switch loaded {
            case .success(let files):
                self.cachedFiles = (sha, files)
                self.recordFileCount(files.count, of: sha)
                self.setFiles(.loaded(files))
                self.select(requested, from: files, in: shown)
            case .failure(let error):
                logger.error("Could not load the stashed files: \(error.message, privacy: .private)")
                self.setFiles(.failed(error))
            }
        })
    }

    /// Goes back to the working directory, with the files selected before the
    /// stash was shown.
    public func hide() {
        guard let repository, repository.changes.isShowingStash else {
            return
        }
        repository.changes.selectWorkingDirectory()
    }

    /// The selection left the stash: forget what was shown.
    func stashWasHidden() {
        fileLoads.cancel()
        diffLoads.cancel()
        diffKey = nil
        if shownEntry != nil {
            shownEntry = nil
        }
        setFiles(.idle)
        if selectedFile != nil {
            selectedFile = nil
        }
        if case .idle = diff {} else {
            diff = .idle
        }
    }

    private enum FileRequest {
        case file(String), keep(String), first
    }

    /// Selects a stashed file (the requested one if it's in the entry, else
    /// none; with no request the selected one or the first) and loads its
    /// diff.
    private func select(_ request: FileRequest, from files: [CommittedFileChange], in entry: StashEntry) {
        let file: CommittedFileChange? = switch request {
        case .file(let id): files.first { JSCompat.strictEquals($0.id, id) }
        case .keep(let id): files.first { JSCompat.strictEquals($0.id, id) } ?? files.first
        case .first: files.first
        }
        if selectedFile != file {
            selectedFile = file
        }
        repository?.changes.showStash(fileID: file?.id)
        loadDiff(of: file, in: entry)
    }

    /// Loads the diff of `file` in `entry` (`getCommitDiff` against the
    /// stash's first parent, never hiding whitespace). A stash never changes,
    /// so a loaded diff isn't loaded again.
    private func loadDiff(of file: CommittedFileChange?, in entry: StashEntry) {
        guard let file, let repository else {
            diffLoads.cancel()
            diffKey = nil
            diff = .idle
            return
        }
        let key = StashDiffKey(stashSha: entry.stashSha, fileID: file.id)
        if diffKey == key, !diff.isLoading, diff.failure == nil {
            return
        }
        diffKey = key
        diff = .loading(previous: nil)
        let gitRepository = repository.gitRepository
        let environment = repository.environment
        let record = repository.record
        diffLoads.run(key, operation: {
            await environment.withRuntimes {
                do {
                    return .success(try await getCommitDiff(gitRepository, file, file.commitish))
                } catch {
                    return .failure(await classifyLoadFailure(error, kind: .loadStashedChanges, record: record))
                }
            }
        }, apply: { [weak self] (result: Result<Result<Diff, OperationError>, any Error>) in
            guard let self, self.diffKey == key, case .success(let loaded) = result else {
                return
            }
            switch loaded {
            case .success(let diff):
                self.diff = .loaded(diff)
            case .failure(let error):
                logger.error("Could not load the stashed diff: \(error.message, privacy: .private)")
                self.diff = .failed(error)
            }
        })
    }

    private func setFiles(_ files: Loadable<[CommittedFileChange], OperationError>) {
        if self.files != files {
            self.files = files
        }
    }

    /// Waits for the stash loads in flight (for tests).
    func loadsIdle() async {
        await fileLoads.idle()
        await diffLoads.idle()
        await countLoads.idle()
    }

    // MARK: Refreshing

    func repositoryDidRefresh(_ update: RefreshUpdate) {
        if let status = update.status {
            settleConflictedRestoreIfResolved(status)
        }
        if update.applied.contains(.refs) {
            followShownEntry()
        }
    }

    /// When the shown entry is gone, the working directory shows; when its
    /// branch has a new one, that one shows, keeping the selected file.
    private func followShownEntry() {
        guard let shown = shownEntry, let repository, repository.changes.isShowingStash else {
            return
        }
        guard let latest = repository.gitState.stashes.entriesByBranch[shown.branchName] else {
            hide()
            return
        }
        if !JSCompat.strictEquals(latest.stashSha, shown.stashSha) || !(files.value != nil || files.isLoading) {
            show(latest, selectedFile.map { .keep($0.id) } ?? .first)
        }
    }

    func repositoryDidBecomeInactive() {
        // The selection's refresh shows the entry again; the sidebar counts
        // again what's left.
        fileLoads.cancel()
        diffLoads.cancel()
        countLoads.cancel()
        if case .loading = files {
            setFiles(.idle)
        }
        if case .loading = diff {
            diffKey = nil
            diff = .idle
        }
    }

    func repositoryPathDidChange(keepingSharedState: Bool) {
        // `fileCounts` stays: it's by stash SHA, and a repository's worktrees
        // share its stashes.
        fileLoads.cancel()
        diffLoads.cancel()
        countLoads.cancel()
        restoreSettlement?.cancel()
        restoreSettlement = nil
        cachedFiles = nil
        diffKey = nil
        shownEntry = nil
        files = .idle
        selectedFile = nil
        diff = .idle
        conflictedRestore = nil
    }

    // MARK: Conflicted restores

    /// Records a restore that conflicted (the primitives call it).
    func restoreDidConflict(_ restore: ConflictedStashRestore) {
        conflictedRestore = restore
    }

    /// Once no file of the conflicted restore is conflicted any more,
    /// settles it with the lane held: drops the entry when every file still
    /// differs from what HEAD had when it was restored (the resolution kept
    /// the stash's changes, in the working directory or committed since),
    /// and otherwise keeps it and stops tracking it (some changes were
    /// discarded or resolved away; the entry still has them). Skipped while
    /// another operation runs; the refresh after it tries again.
    private func settleConflictedRestoreIfResolved(_ status: StatusResult) {
        guard let pending = conflictedRestore, restoreSettlement == nil else {
            return
        }
        let conflicted = status.workingDirectory.files.filter { $0.status.kind == .conflicted }.map(\.path).exactSet
        guard !pending.paths.contains(where: { conflicted.contains(ExactString($0)) }) else {
            return
        }
        restoreSettlement = Task { [weak self] in
            await self?.settle(pending)
            self?.restoreSettlement = nil
        }
    }

    private func settle(_ pending: ConflictedStashRestore) async {
        guard let repository else {
            return
        }
        let descriptor = OperationDescriptor(kind: .dropStash, policy: .background, refreshAfter: .refs)
        do {
            guard let outcome = try await repository.performIfIdle(descriptor, { ctx in
                try await settleConflictedRestore(pending, in: ctx.repository)
            }) else {
                return
            }
            switch outcome {
            case .stillConflicted:
                break
            case .dropped:
                logger.info("Dropped stash '\(pending.entry.stashSha, privacy: .public)' after its conflicts were resolved")
                clearConflictedRestore(pending)
            case .kept:
                logger.info("Keeping stash '\(pending.entry.stashSha, privacy: .public)': resolving its conflicts dropped some of its changes")
                clearConflictedRestore(pending)
            }
        } catch {
            logger.error("Could not settle a conflicted stash restore; keeping the entry: \(error.message, privacy: .public)")
            clearConflictedRestore(pending)
        }
    }

    private func clearConflictedRestore(_ pending: ConflictedStashRestore) {
        if conflictedRestore == pending {
            conflictedRestore = nil
        }
    }

    /// Waits for a conflicted restore being settled (for tests).
    func settlementIdle() async {
        await restoreSettlement?.value
    }
}

/// Identifies a stashed file's diff.
struct StashDiffKey: Hashable, Sendable {
    let stashSha: String
    let fileID: String
}

/// What settling a conflicted restore did.
enum ConflictedRestoreOutcome: Sendable, Equatable {
    case stillConflicted, dropped, kept
}

/// Settles a conflicted restore with the lane held (see
/// `StashModel.settleConflictedRestoreIfResolved`).
@concurrent
func settleConflictedRestore(_ pending: ConflictedStashRestore, in repository: Repository) async throws -> ConflictedRestoreOutcome {
    guard let status = try await getStatus(repository) else {
        return .kept
    }
    let conflicted = status.workingDirectory.files.filter { $0.status.kind == .conflicted }.map(\.path).exactSet
    if pending.paths.contains(where: { conflicted.contains(ExactString($0)) }) {
        return .stillConflicted
    }
    guard let baseTip = pending.baseTip, !pending.paths.isEmpty else {
        return .kept
    }

    // Which of the files differ from HEAD at the restore, in the working
    // directory (committed since, or not). The paths are literal pathspecs:
    // read as patterns, `:x.txt` would have named x.txt.
    let result = try await git(
        ["diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", "--end-of-options", baseTip, "--"] + literalPathspecs(pending.paths),
        repository.path,
        "settleConflictedRestore"
    )
    let changed = JSCompat.split(result.stdout, "\0").filter { !$0.isEmpty }.exactSet
    guard pending.paths.allSatisfy({ changed.contains(ExactString($0)) }) else {
        return .kept
    }
    try await dropDesktopStashEntry(repository, pending.entry.stashSha)
    return .dropped
}
