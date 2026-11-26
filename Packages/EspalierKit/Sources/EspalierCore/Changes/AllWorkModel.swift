// All Work: everything on the current branch that isn't in its base, its
// commits since the merge base and the uncommitted changes as one list,
// each file's diff running from the merge base to the working tree. Changes
// shows it in its All Work scope, for reading: nothing here writes to the
// repository. The files carry viewed marks, kept per worktree in
// `ViewedMarksStore` with the content each file had when marked.

import EspalierSupport
import Foundation
import GitKit
import Observation
import os

private let logger = Log.logger(category: "changes")

/// What Changes lists.
public enum ChangesScope: String, Sendable, Equatable, CaseIterable {
    /// Everything on the branch that isn't in its base: the commits since
    /// the merge base and the uncommitted changes.
    case allWork
    /// The uncommitted changes, with their include checkboxes.
    case uncommitted
}

/// The base All Work compares the branch with, and what it found.
public struct AllWorkComparison: Sendable, Equatable {
    /// The base's name ("main", "origin/main").
    public let baseName: String
    /// The merge base of the base and HEAD.
    public let mergeBase: String
    /// The commits on HEAD since the merge base.
    public let commitCount: Int

    public init(baseName: String, mergeBase: String, commitCount: Int) {
        self.baseName = baseName
        self.mergeBase = mergeBase
        self.commitCount = commitCount
    }
}

/// A file All Work lists.
public struct AllWorkFile: Sendable, Equatable, Identifiable {
    /// The change from the merge base to the working tree (its `commitish`
    /// and `parentCommitish` are the merge base).
    public let change: CommittedFileChange
    /// The lines added and deleted, from the list's `--numstat`; nil for a
    /// binary file and an untracked one (Changes counts those).
    public let lineCount: FileLineCount?
    /// The file's content on disk as git hashes it, "deleted" for a deleted
    /// file: a viewed mark holds the one it was marked with.
    public let contentID: String

    public init(change: CommittedFileChange, lineCount: FileLineCount?, contentID: String) {
        self.change = change
        self.lineCount = lineCount
        self.contentID = contentID
    }

    public var id: String {
        change.id
    }

    public var path: String {
        change.path
    }
}

/// The base a branch's work is compared with: its ref and name.
struct AllWorkBase: Sendable, Equatable {
    let name: String
    let ref: String
}

/// All Work's files, their selection, the selected file's diff, and the
/// viewed marks; and which scope Changes shows.
@MainActor @Observable
public final class AllWorkModel: RepositoryFeature {
    /// The comparison with the branch's base; nil without one (a detached
    /// HEAD, an unborn branch, no base found, no shared history) and until
    /// it loads.
    public private(set) var comparison: AllWorkComparison?
    /// The files, sorted by path (case-insensitively), loaded while All
    /// Work is the scope chosen; empty otherwise.
    public private(set) var files: [AllWorkFile] = []
    /// The files' load failed.
    public private(set) var failure: OperationError?
    /// The scope the user chose for this worktree; `scope` is what shows.
    public private(set) var chosenScope: ChangesScope = .uncommitted
    /// The selected file's ID.
    public private(set) var selectedFileID: String?
    /// The selected file's diff. While a newer one loads, `.loading` keeps
    /// the previous diff of the same file.
    public private(set) var diff: Loadable<Diff, OperationError> = .idle
    /// The file `diff` belongs to.
    public private(set) var diffFileID: String?
    /// The worktree's viewed marks: each marked file's content ID when it
    /// was marked, by its path.
    public private(set) var viewedMarks: [ExactString: String] = [:]

    @ObservationIgnored weak var repository: RepositoryModel?
    @ObservationIgnored let loads = LatestTask<UInt64>()
    @ObservationIgnored var loadSequence: UInt64 = 0
    @ObservationIgnored let diffLoads = LatestTask<AllWorkDiffKey>()
    /// The worktree whose scope and marks are loaded.
    @ObservationIgnored private var loadedWorktree: String?

    init() {}

    func attach(to repository: RepositoryModel) {
        self.repository = repository
        loadWorktreeState()
        observeWhitespacePreference()
    }

    // MARK: Scope

    /// Whether All Work would list something Uncommitted doesn't: HEAD is
    /// on a branch with commits since its base, and no operation waits on
    /// conflicts.
    public var isAvailable: Bool {
        guard let repository, let comparison, comparison.commitCount > 0 else {
            return false
        }
        return repository.gitState.inProgress == nil && repository.operations.conflictState == nil
    }

    /// The scope Changes shows: All Work when chosen and available, else
    /// Uncommitted.
    public var scope: ChangesScope {
        isAvailable && chosenScope == .allWork ? .allWork : .uncommitted
    }

    /// Chooses the scope Changes shows in this worktree, remembered for it.
    /// All Work shows once it's available.
    public func choose(_ scope: ChangesScope) {
        guard scope != chosenScope else {
            return
        }
        chosenScope = scope
        if let repository {
            PreferenceStore(repository.environment.defaults.defaults).defaults
                .set(scope == .allWork, forKey: Self.scopeKey(repository.record.path))
        }
        if scope == .allWork {
            reload()
        } else {
            files = []
            failure = nil
            select(nil)
        }
    }

    /// The `UserDefaults` key of whether a worktree shows All Work.
    static func scopeKey(_ worktree: String) -> String {
        "changes-all-work-\(worktree)"
    }

    // MARK: Files

    /// The files the list shows: those whose path matches the toolbar's
    /// search (Changes' filter text).
    public var visibleFiles: [AllWorkFile] {
        guard let query = repository?.changes.filter.textQuery else {
            return files
        }
        return files.filter { query.matches($0.path) }
    }

    /// The paths of the uncommitted changes (a rename's old path too).
    public var uncommittedPaths: Set<ExactString> {
        var paths = Set<ExactString>()
        for file in repository?.changes.workingDirectory.files ?? [] {
            paths.insert(ExactString(file.path))
            if let oldPath = file.status.oldPath {
                paths.insert(ExactString(oldPath))
            }
        }
        return paths
    }

    /// Whether `file` also has uncommitted changes.
    public func isUncommitted(_ file: AllWorkFile, in paths: Set<ExactString>) -> Bool {
        paths.contains(ExactString(file.path)) || file.change.status.oldPath.map { paths.contains(ExactString($0)) } == true
    }

    /// The lines `file` adds and deletes: the list's, or for an untracked
    /// file, Changes' count once it's loaded.
    public func lineCount(_ file: AllWorkFile) -> FileLineCount? {
        file.lineCount ?? repository?.changes.lineCounts[ExactString(file.id)]
    }

    /// The selected file.
    public var selectedFile: AllWorkFile? {
        selectedFileID.flatMap(file(withID:))
    }

    func file(withID id: String) -> AllWorkFile? {
        files.first { JSCompat.strictEquals($0.id, id) }
    }

    /// Selects a file and loads its diff; nil clears the diff.
    public func select(_ fileID: String?) {
        if selectedFileID != fileID {
            selectedFileID = fileID
        }
        loadSelectedDiff()
    }

    // MARK: Viewed marks

    /// Whether `file` is marked viewed with the content it has now.
    public func isViewed(_ file: AllWorkFile) -> Bool {
        viewedMarks[ExactString(file.path)] == file.contentID
    }

    /// How many files are viewed.
    public var viewedCount: Int {
        files.count(where: isViewed)
    }

    /// Marks `file` viewed, or not, with the content it has now.
    public func setViewed(_ file: AllWorkFile, _ viewed: Bool) {
        var marks = viewedMarks
        marks[ExactString(file.path)] = viewed ? file.contentID : nil
        saveMarks(marks)
    }

    /// Toggles the selected file's mark; once it's viewed, selects the next
    /// file not viewed after it (from the top past the end), if any.
    public func toggleSelectedViewed() {
        guard let file = selectedFile else {
            return
        }
        let viewed = !isViewed(file)
        setViewed(file, viewed)
        guard viewed, let index = files.firstIndex(where: { JSCompat.strictEquals($0.id, file.id) }) else {
            return
        }
        let following = files[(index + 1)...] + files[..<index]
        if let next = following.first(where: { !isViewed($0) }) {
            select(next.id)
        }
    }

    private func saveMarks(_ marks: [ExactString: String]) {
        guard marks != viewedMarks else {
            return
        }
        viewedMarks = marks
        if let repository, let store = repository.app?.viewedMarks {
            store.setMarks(marks, for: repository.record.path)
        }
    }

    /// Drops the marks of files no longer listed, and of files changed
    /// since they were marked.
    private func pruneMarks() {
        var current: [ExactString: String] = [:]
        for file in files {
            current[ExactString(file.path)] = file.contentID
        }
        let kept = viewedMarks.filter { current[$0.key] == $0.value }
        saveMarks(kept)
    }

    // MARK: Refreshing

    func repositoryDidRefresh(_ update: RefreshUpdate) {
        if !update.applied.isDisjoint(with: [.status, .refs]) {
            reload()
        }
    }

    func repositoryDidBecomeInactive() {
        loads.cancel()
        diffLoads.cancel()
        if case .loading(let previous) = diff {
            diff = previous.map { .loaded($0) } ?? .idle
        }
    }

    func repositoryPathDidChange(keepingSharedState: Bool) {
        loads.cancel()
        diffLoads.cancel()
        comparison = nil
        files = []
        failure = nil
        selectedFileID = nil
        diff = .idle
        diffFileID = nil
        loadWorktreeState()
    }

    /// Reads the worktree's scope and marks.
    private func loadWorktreeState() {
        guard let repository else {
            return
        }
        let worktree = repository.record.path
        loadedWorktree = worktree
        let shows = PreferenceStore(repository.environment.defaults.defaults).getBoolean(Self.scopeKey(worktree), false)
        chosenScope = shows ? .allWork : .uncommitted
        viewedMarks = repository.app?.viewedMarks.marks(for: worktree) ?? [:]
    }

    /// Loads the comparison, and the files while All Work is chosen, for
    /// the repository's state now. Only while the repository is selected.
    func reload() {
        guard let repository, repository.isActive else {
            return
        }
        guard let base = Self.base(for: repository) else {
            loads.cancel()
            apply(nil)
            return
        }
        let request = AllWorkRequest(
            repository: repository.gitRepository,
            base: base,
            wantsFiles: chosenScope == .allWork,
            untracked: repository.changes.workingDirectory.files.filter { $0.status.kind == .untracked }
        )
        let environment = repository.environment
        let record = repository.record
        loadSequence &+= 1
        loads.run(loadSequence, operation: {
            await environment.withRuntimes {
                do {
                    return .success(try await loadAllWork(request))
                } catch {
                    return .failure(await classifyLoadFailure(error, kind: .loadChangesDiff, record: record))
                }
            }
        }, apply: { [weak self] (result: Result<Result<AllWorkLoaded?, OperationError>, any Error>) in
            guard let self, case .success(let loaded) = result else {
                return
            }
            switch loaded {
            case .success(let loaded):
                self.apply(loaded)
            case .failure(let error):
                logger.error("Could not load All Work: \(error.message, privacy: .private)")
                self.failure = error
            }
        })
    }

    private func apply(_ loaded: AllWorkLoaded?) {
        let comparison = loaded?.comparison
        if comparison != self.comparison {
            self.comparison = comparison
        }
        if failure != nil {
            failure = nil
        }
        guard let loaded, let files = loaded.files else {
            if !files.isEmpty {
                files = []
            }
            if selectedFileID != nil || diffFileID != nil {
                select(nil)
            }
            return
        }
        if files != self.files {
            self.files = files
        }
        pruneMarks()
        // The selected file stays while it's listed; else the first.
        let selected = selectedFileID.flatMap(file(withID:))?.id ?? files.first?.id
        select(selected)
    }

    /// The base the current branch's work is compared with: the default
    /// branch its work goes to, as Preview Pull Request picks it
    /// (`findContributionTargetDefaultBranch`); on that branch itself, its
    /// upstream. Nil on a detached HEAD, an unborn branch, or without one.
    static func base(for repository: RepositoryModel) -> AllWorkBase? {
        guard case .valid(let current) = repository.gitState.tip else {
            return nil
        }
        let branches = repository.gitState.branches
        guard let target = findContributionTargetDefaultBranch(repository.record, branches) else {
            return nil
        }
        guard JSCompat.strictEquals(target.ref, current.ref) else {
            return AllWorkBase(name: target.name, ref: target.ref)
        }
        if let upstream = branches.upstreams[ExactString(current.ref)] {
            return AllWorkBase(name: upstream.name, ref: upstream.ref)
        }
        guard let upstream = current.upstream else {
            return nil
        }
        return AllWorkBase(name: upstream, ref: "refs/remotes/\(upstream)")
    }

    // MARK: The diff

    /// Loads the selected file's diff, from the merge base to the working
    /// tree, unless the one shown is already of its content.
    func loadSelectedDiff() {
        guard let repository, let file = selectedFile, let comparison else {
            diffLoads.cancel()
            if case .idle = diff {} else {
                diff = .idle
            }
            if diffFileID != nil {
                diffFileID = nil
            }
            return
        }
        guard repository.isActive else {
            return
        }
        let hidesWhitespace = hidesWhitespace
        let key = AllWorkDiffKey(
            fileID: ExactString(file.id),
            contentID: file.contentID,
            mergeBase: comparison.mergeBase,
            hidesWhitespace: hidesWhitespace
        )
        // The diff shown, or loading, is already of this content.
        if diffLoads.currentKey == key, diff.failure == nil {
            return
        }
        let sameFile = diffFileID.map { JSCompat.strictEquals($0, file.id) } ?? false
        diff = sameFile ? diff.reloading : .loading(previous: nil)
        if !sameFile {
            diffFileID = file.id
        }
        let gitRepository = repository.gitRepository
        let environment = repository.environment
        let record = repository.record
        let change = file.change
        let mergeBase = comparison.mergeBase
        diffLoads.run(key, operation: {
            await environment.withRuntimes {
                do {
                    return .success(try await getWorkingTreeDiff(gitRepository, change, since: mergeBase, hideWhitespaceInDiff: hidesWhitespace))
                } catch {
                    return .failure(await classifyLoadFailure(error, kind: .loadChangesDiff, record: record))
                }
            }
        }, apply: { [weak self] (result: Result<Result<Diff, OperationError>, any Error>) in
            guard let self, self.selectedFileID.map(ExactString.init) == key.fileID,
                  case .success(let loaded) = result
            else {
                return
            }
            switch loaded {
            case .success(let diff):
                self.diff = .loaded(diff)
            case .failure(let error):
                logger.error("Could not load the diff: \(error.message, privacy: .private)")
                self.diff = .failed(error)
            }
        })
    }

    /// Whether diffs leave whitespace changes out: Changes' setting.
    private var hidesWhitespace: Bool {
        repository?.app?.preferences.hideWhitespaceInChangesDiff ?? false
    }

    /// Reloads the diff when Changes' whitespace setting changes.
    private func observeWhitespacePreference() {
        guard let preferences = repository?.app?.preferences else {
            return
        }
        withObservationTracking {
            _ = preferences.hideWhitespaceInChangesDiff
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.loadSelectedDiff()
                self?.observeWhitespacePreference()
            }
        }
    }

    // MARK: Waiting

    /// Waits for the loads in flight (for tests).
    public func idle() async {
        while loads.isRunning || diffLoads.isRunning {
            await loads.idle()
            await diffLoads.idle()
        }
    }
}

/// What a diff load is for: the same key is the same diff.
struct AllWorkDiffKey: Hashable, Sendable {
    let fileID: ExactString
    let contentID: String
    let mergeBase: String
    let hidesWhitespace: Bool
}

/// What All Work loads, read on the main actor.
struct AllWorkRequest: Sendable {
    let repository: Repository
    let base: AllWorkBase
    /// Whether to list the files (All Work is chosen).
    let wantsFiles: Bool
    /// The untracked files, which `git diff` leaves out.
    let untracked: [WorkingDirectoryFileChange]
}

/// What All Work loaded: the comparison, and the files when asked for and
/// the branch has commits since its base.
struct AllWorkLoaded: Sendable, Equatable {
    let comparison: AllWorkComparison
    let files: [AllWorkFile]?
}

/// The content ID of a deleted file.
let deletedContentID = "deleted"

/// Loads All Work for `request`: the merge base of the base and HEAD and
/// the commits since it; then, when asked for and there are commits, the
/// files changed from the merge base to the working tree with the
/// untracked files, and their content IDs. Nil when the base and HEAD share
/// no history.
@concurrent
func loadAllWork(_ request: AllWorkRequest) async throws -> AllWorkLoaded? {
    let repository = request.repository
    guard let mergeBase = try await getMergeBase(repository, request.base.ref, "HEAD"), !mergeBase.isEmpty else {
        return nil
    }
    // The left side's commits are `ahead`.
    let commitCount = try await getAheadBehind(repository, revSymmetricDifference("HEAD", mergeBase))?.ahead ?? 0
    let comparison = AllWorkComparison(baseName: request.base.name, mergeBase: mergeBase, commitCount: commitCount)
    guard request.wantsFiles, commitCount > 0 else {
        return AllWorkLoaded(comparison: comparison, files: nil)
    }
    let changeset = try await getWorkingTreeChangedFiles(repository, since: mergeBase)
    var changes = changeset.files
    var listed = Set(changes.map { ExactString($0.path) })
    for file in request.untracked where listed.insert(ExactString(file.path)).inserted {
        changes.append(CommittedFileChange(path: file.path, status: file.status, commitish: mergeBase, parentCommitish: mergeBase))
    }
    let sorted = changes.enumerated()
        .sorted { x, y in
            let order = JSCompat.caseInsensitiveCompare(x.element.path, y.element.path)
            return order != 0 ? order < 0 : x.offset < y.offset
        }
        .map(\.element)
    let contentIDs = try await getContentIDs(repository, sorted)
    let files = sorted.map { change in
        AllWorkFile(
            change: change,
            lineCount: changeset.lineCounts[change.id],
            contentID: contentIDs[ExactString(change.path)] ?? deletedContentID
        )
    }
    return AllWorkLoaded(comparison: comparison, files: files)
}

/// The content IDs of `files` on disk, by path: git's hash of each file's
/// bytes (`hash-object --no-filters`), or of a submodule's checked-out
/// commit; none for a file that isn't there.
@concurrent
func getContentIDs(_ repository: Repository, _ files: [CommittedFileChange]) async throws -> [ExactString: String] {
    var ids: [ExactString: String] = [:]
    var paths: [String] = []
    for file in files where file.status.kind != .deleted {
        let fullPath = POSIXPath.join(repository.path, file.path)
        var info = stat()
        guard lstat(fullPath, &info) == 0 else {
            continue
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG, S_IFLNK:
            paths.append(file.path)
        case S_IFDIR:
            // A submodule: its checked-out commit.
            let result = try await git(
                ["rev-parse", "--verify", "--quiet", "HEAD"],
                fullPath,
                "getSubmoduleContentID",
                options: GitExecutionOptions(successExitCodes: [0, 1, 128])
            )
            let stdout = result.stdout
            if result.exitCode == 0 {
                ids[ExactString(file.path)] = "submodule:\(JSCompat.trim(stdout))"
            }
        default:
            continue
        }
    }
    // Paths as arguments, which `hash-object` reads as plain paths, in
    // batches that stay well under the argument limit.
    for start in stride(from: 0, to: paths.count, by: 500) {
        let batch = Array(paths[start..<min(start + 500, paths.count)])
        let result = try await git(["hash-object", "--no-filters", "--"] + batch, repository.path, "getContentIDs")
        let stdout = result.stdout
        let hashes = JSCompat.split(JSCompat.trim(stdout), "\n")
        for (path, hash) in zip(batch, hashes) {
            ids[ExactString(path)] = hash
        }
    }
    return ids
}
