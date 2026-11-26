import EspalierSupport
import Foundation
import GitKit
import Observation
import os

private let logger = Log.logger(category: "worktree-activity")

/// What's kept about the worktrees to order and mark them: when each kind
/// of activity last happened in each worktree, which worktrees have activity
/// the user hasn't seen, when each last changed on disk, and the pinned
/// repositories. `AppModel.board` and `AppModel.shelf` are made of it.
///
/// - **What shows at launch.** What each worktree's piece of work was made
///   of (`WorktreeFacts`: its status, its place among the repository's
///   worktrees, its pull request) is saved with the rest, with its changed
///   files' names and its commits to push. The next launch shows them
///   (`rememberedFacts`, `AppModel.worktreeFacts(of:)`) until it tells the
///   worktree's status itself, so Home and the shelf have every repository
///   at once and bring each up to date as its status loads.
/// - **Activity.** Each status of a worktree arrives as a snapshot
///   (`recordStatus`), is compared with the worktree's previous one, and
///   the kinds of activity between them get the current time. The
///   snapshots are kept between launches, so the first status after a
///   launch tells what changed while the app was quit. A worktree's first
///   snapshot records no activity.
/// - **Unseen.** A worktree is open while its repository is the selected
///   one and the record points at it. `WorktreeActivity.lastOpen` follows
///   it: set when the worktree is opened, with each activity recorded
///   while it's open, and when it's left. Activity later than that is
///   unseen.
/// - **Pins.** In the order they were pinned.
///
/// Removing a repository drops its pin, activity, and snapshots. All of it
/// is saved in `worktree-activity.json`: a pin at once, the rest
/// `saveDelay` after the first change not yet saved (while
/// `BackgroundServices.worktreeActivityAutosave` is among the
/// environment's services), and whatever is left on `flush()`,
/// which quitting calls.
@MainActor @Observable
public final class WorktreeActivityModel {
    /// How long after a change the state is saved; changes meanwhile go
    /// into the same save.
    static let saveDelay: Duration = .seconds(5)

    /// When each kind of activity last happened in each worktree, and when
    /// the worktree was last open. A worktree nothing happened in has no
    /// entry.
    public private(set) var activity: [WorktreeKey: WorktreeActivity] = [:]

    /// The pinned repositories, in the order they were pinned.
    public private(set) var pinnedRepositoryIDs: [RepositoryID] = []

    /// The open worktree: the selected repository's, where its record
    /// points. Nothing in it is unseen.
    public private(set) var openWorktree: WorktreeKey?

    /// When each worktree last changed on disk, as its last status found
    /// (`WorktreeStatusSnapshot.lastChanged`), kept between launches.
    public private(set) var lastChanged: [WorktreeKey: Date] = [:]

    /// A few of each worktree's changed files, as its last status found
    /// (`WorktreeStatusSnapshot.changedFilesSample`), kept between launches.
    public private(set) var changedFilesSamples: [WorktreeKey: [ChangedFileSample]] = [:]

    /// The commits each worktree that's ahead of its upstream has to push,
    /// as its last status found them (`recordStatusForUnpushedCommits`),
    /// kept between launches.
    public private(set) var unpushedCommits: [WorktreeKey: UnpushedCommits] = [:]

    /// What each repository's worktrees were when the state was last saved
    /// before this launch: the ones no status has told of since. A
    /// worktree's goes once this launch tells its status, whatever it
    /// tells (`forgetRememberedFacts`), and with a worktree its repository
    /// no longer lists.
    public private(set) var rememberedFacts: [RepositoryID: [WorktreeFacts]] = [:]

    /// The pull request status each branch had then, until GitHub answers
    /// about the branch in this launch (`forgetRememberedPullRequest`).
    public private(set) var rememberedPullRequests: [RepositoryBranch: BranchPullRequestStatus] = [:]

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let store: WorktreeActivityStore
    @ObservationIgnored private let scheduler: any Scheduler
    /// Whether changes are saved on their own, `saveDelay` after them.
    @ObservationIgnored private let autosaves: Bool
    /// Each worktree's last status, as its snapshot.
    @ObservationIgnored private(set) var snapshots: [WorktreeKey: WorktreeStatusSnapshot] = [:]

    /// What the repositories' pieces of work are made of
    /// (`AppModel.workToRemember()`), as last taken for saving.
    @ObservationIgnored private var work: [WorktreeActivityDocument.StoredWork] = []
    /// Whether `work` was taken for quitting, and stays as it is.
    @ObservationIgnored private var isWorkFinal = false

    /// Whether the saved state has been read: nothing is saved before.
    @ObservationIgnored private var isLoaded = false
    /// Bumped by every change.
    @ObservationIgnored private var revision: UInt64 = 0
    /// The revision of the last save started.
    @ObservationIgnored private var savedRevision: UInt64 = 0
    /// The wait before the next save, while there is one.
    @ObservationIgnored private var saveTimer: Task<Void, Never>?
    /// The saves being written, by revision.
    @ObservationIgnored private var writes: [UInt64: Task<Void, Never>] = [:]

    @ObservationIgnored let environment: AppEnvironment
    /// The latest read of each worktree's commits to push: an older one
    /// that finishes later is dropped.
    @ObservationIgnored private var unpushedCommitsRequests: [WorktreeKey: UInt64] = [:]
    @ObservationIgnored private var nextUnpushedCommitsRequest: UInt64 = 0

    init(environment: AppEnvironment) {
        self.environment = environment
        store = WorktreeActivityStore(fileURL: environment.directories.worktreeActivity)
        scheduler = environment.scheduler
        autosaves = environment.backgroundServices.contains(.worktreeActivityAutosave)
    }

    // MARK: Activity

    /// The worktree at `path` of repository `id` has a new status,
    /// `snapshot` (`WorktreeStatusSnapshot.load`): what differs from the
    /// worktree's previous snapshot is recorded as activity, now
    /// (`WorktreeStatusSnapshot.activity(since:)`). The worktree's first
    /// snapshot is only kept. A repository that isn't in the list records
    /// nothing.
    public func recordStatus(_ snapshot: WorktreeStatusSnapshot, forWorktreeAt path: String, of id: RepositoryID) {
        guard isListed(id) else {
            return
        }
        let key = WorktreeKey(repositoryID: id, path: path)
        if lastChanged[key] != snapshot.lastChanged {
            lastChanged[key] = snapshot.lastChanged
        }
        if changedFilesSamples[key] ?? [] != snapshot.changedFilesSample {
            changedFilesSamples[key] = snapshot.changedFilesSample.isEmpty ? nil : snapshot.changedFilesSample
        }
        guard let previous = snapshots[key] else {
            snapshots[key] = snapshot
            didChange()
            return
        }
        guard previous != snapshot else {
            return
        }
        snapshots[key] = snapshot
        didChange()
        record(snapshot.activity(since: previous), in: key)
    }

    /// A fetch found the ahead/behind of the worktree at `path` of
    /// repository `id`, without a status: a branch further behind its
    /// upstream than at the worktree's last status records `server`
    /// activity. Nothing before the worktree's first status.
    public func recordAheadBehind(_ aheadBehind: AheadBehind?, forWorktreeAt path: String, of id: RepositoryID) {
        guard var snapshot = snapshots[WorktreeKey(repositoryID: id, path: path)] else {
            return
        }
        snapshot.behind = aheadBehind?.behind
        recordStatus(snapshot, forWorktreeAt: path, of: id)
    }

    /// Records that `kind` happened now in the worktree at `path` of
    /// repository `id`: how a pull request's activity comes in. A
    /// repository that isn't in the list records nothing.
    public func recordActivity(_ kind: WorktreeActivityKind, forWorktreeAt path: String, of id: RepositoryID) {
        guard isListed(id) else {
            return
        }
        record([kind], in: WorktreeKey(repositoryID: id, path: path))
    }

    /// Forgets the worktrees of repository `id` that aren't at `paths`:
    /// their activity and snapshots. For when a repository's worktrees
    /// were listed and some are gone.
    public func forgetWorktrees(of id: RepositoryID, except paths: [String]) {
        let kept = Set(paths.map { WorktreeKey(repositoryID: id, path: $0) })
        forget { $0.repositoryID == id && !kept.contains($0) }
    }

    // MARK: What shows at launch

    /// This launch told the status of the worktree at `path` of repository
    /// `id` (or that it has none): what was remembered of it goes. Its
    /// branch's pull request stays until GitHub answers.
    func forgetRememberedFacts(forWorktreeAt path: String, of id: RepositoryID) {
        guard let facts = rememberedFacts[id] else {
            return
        }
        let key = WorktreeKey(repositoryID: id, path: path)
        let remaining = facts.filter { WorktreeKey(repositoryID: id, path: $0.path) != key }
        if remaining.count != facts.count {
            rememberedFacts[id] = remaining.isEmpty ? nil : remaining
        }
    }

    /// GitHub answered about `branch` in this launch, or the branch stopped
    /// being asked about: the pull request status remembered for it goes.
    func forgetRememberedPullRequest(_ branch: RepositoryBranch) {
        if rememberedPullRequests[branch] != nil {
            rememberedPullRequests[branch] = nil
        }
    }

    /// Quitting: takes what the pieces of work are made of now, for the
    /// last save. The background services stop next and remove the
    /// worktrees they published, which mustn't be what's saved.
    func takeWorkForTermination() {
        if takeWork() {
            revision &+= 1
        }
        isWorkFinal = true
    }

    /// Takes what the pieces of work are made of now, and returns whether
    /// it differs from what was last taken.
    private func takeWork() -> Bool {
        guard !isWorkFinal else {
            return false
        }
        let current = app?.workToRemember() ?? []
        guard current != work else {
            return false
        }
        work = current
        return true
    }

    /// Saves what the pieces of work are made of a while after it changes,
    /// while saves happen on their own: follows what it's read from, and
    /// counts a change when it differs from what was last taken.
    private func observeWork() {
        guard autosaves, isLoaded, let app else {
            return
        }
        withObservationTracking {
            _ = app.workToRemember()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeWork()
            }
        }
        if takeWork() {
            didChange()
        }
    }

    private func record(_ kinds: Set<WorktreeActivityKind>, in key: WorktreeKey) {
        guard !kinds.isEmpty else {
            return
        }
        let now = scheduler.now
        var entry = activity[key] ?? WorktreeActivity()
        for kind in kinds {
            entry[kind] = now
        }
        // Seen as it happens.
        if key == openWorktree {
            entry.lastOpen = now
        }
        activity[key] = entry
        didChange()
    }

    func isListed(_ id: RepositoryID) -> Bool {
        app?.record(id) != nil
    }

    // MARK: Commits to push

    func setUnpushedCommits(_ commits: UnpushedCommits?, for key: WorktreeKey) {
        if commits == nil {
            unpushedCommitsRequests[key] = nil
        }
        if unpushedCommits[key] != commits {
            unpushedCommits[key] = commits
            didChange()
        }
    }

    func beginUnpushedCommitsRequest(for key: WorktreeKey) -> UInt64 {
        nextUnpushedCommitsRequest &+= 1
        unpushedCommitsRequests[key] = nextUnpushedCommitsRequest
        return nextUnpushedCommitsRequest
    }

    func isCurrentUnpushedCommitsRequest(_ request: UInt64, for key: WorktreeKey) -> Bool {
        unpushedCommitsRequests[key] == request
    }

    // MARK: The open worktree

    /// The selection or the selected repository's record changed: brings
    /// `openWorktree` up to date. The worktree left and the one opened
    /// were open now.
    func openWorktreeDidChange() {
        let current = app.flatMap { app -> WorktreeKey? in
            guard case .repository(let id) = app.selection, let record = app.record(id) else {
                return nil
            }
            return WorktreeKey(repositoryID: id, path: record.path)
        }
        guard current != openWorktree else {
            return
        }
        let now = scheduler.now
        for key in [openWorktree, current] {
            if let key, activity[key] != nil {
                activity[key]?.lastOpen = now
                didChange()
            }
        }
        openWorktree = current
    }

    // MARK: Pins

    /// Whether repository `id` is pinned.
    public func isPinned(_ id: RepositoryID) -> Bool {
        pinnedRepositoryIDs.contains(id)
    }

    /// Pins repository `id`, after the ones already pinned. Nothing for
    /// one that's pinned, or not in the list.
    public func pin(_ id: RepositoryID) {
        guard isListed(id), !isPinned(id) else {
            return
        }
        pinnedRepositoryIDs.append(id)
        didChange(savingNow: true)
    }

    /// Unpins repository `id`.
    public func unpin(_ id: RepositoryID) {
        guard isPinned(id) else {
            return
        }
        pinnedRepositoryIDs.removeAll { $0 == id }
        didChange(savingNow: true)
    }

    // MARK: Removing

    /// Repository `id` left the list: drops its pin, and its worktrees'
    /// activity and snapshots.
    func forgetRepository(_ id: RepositoryID) {
        forget { $0.repositoryID == id }
        if openWorktree?.repositoryID == id {
            openWorktree = nil
        }
        let forgottenPullRequests = rememberedPullRequests.keys.filter { $0.repositoryID == id }
        for key in forgottenPullRequests {
            rememberedPullRequests[key] = nil
        }
        if isPinned(id) {
            pinnedRepositoryIDs.removeAll { $0 == id }
            didChange(savingNow: true)
        }
    }

    /// Drops the activity and snapshots of the worktrees `shouldForget`
    /// picks.
    private func forget(_ shouldForget: (WorktreeKey) -> Bool) {
        let forgottenActivity = activity.keys.filter(shouldForget)
        let forgottenSnapshots = snapshots.keys.filter(shouldForget)
        let forgottenTimes = lastChanged.keys.filter(shouldForget)
        if !forgottenTimes.isEmpty {
            var remaining = lastChanged
            for key in forgottenTimes {
                remaining[key] = nil
            }
            lastChanged = remaining
        }
        let forgottenCommits = unpushedCommits.keys.filter(shouldForget)
        if !forgottenCommits.isEmpty {
            var remaining = unpushedCommits
            for key in forgottenCommits {
                remaining[key] = nil
                unpushedCommitsRequests[key] = nil
            }
            unpushedCommits = remaining
        }
        let forgottenSamples = changedFilesSamples.keys.filter(shouldForget)
        if !forgottenSamples.isEmpty {
            var remaining = changedFilesSamples
            for key in forgottenSamples {
                remaining[key] = nil
            }
            changedFilesSamples = remaining
        }
        for (id, facts) in rememberedFacts {
            let remaining = facts.filter { !shouldForget(WorktreeKey(repositoryID: id, path: $0.path)) }
            if remaining.count != facts.count {
                rememberedFacts[id] = remaining.isEmpty ? nil : remaining
            }
        }
        guard !forgottenActivity.isEmpty || !forgottenSnapshots.isEmpty else {
            return
        }
        if !forgottenActivity.isEmpty {
            var remaining = activity
            for key in forgottenActivity {
                remaining[key] = nil
            }
            activity = remaining
        }
        for key in forgottenSnapshots {
            snapshots[key] = nil
        }
        didChange()
    }

    // MARK: Saving

    /// Takes the saved state, once the repository list has loaded: what's
    /// kept for the repositories in the list.
    func apply(_ document: WorktreeActivityDocument) {
        let listed = Set(app?.repositories.map(\.id) ?? [])
        var pinned: [RepositoryID] = []
        for id in document.pinnedRepositoryIDs where listed.contains(id) && !pinned.contains(id) {
            pinned.append(id)
        }
        var activity: [WorktreeKey: WorktreeActivity] = [:]
        var snapshots: [WorktreeKey: WorktreeStatusSnapshot] = [:]
        var commits: [WorktreeKey: UnpushedCommits] = [:]
        for worktree in document.worktrees where listed.contains(worktree.repositoryID) {
            let key = WorktreeKey(repositoryID: worktree.repositoryID, path: worktree.path)
            activity[key] = worktree.activity
            snapshots[key] = worktree.snapshot
            commits[key] = worktree.unpushedCommits
        }
        // What the pieces of work were made of, for the repositories still
        // in the list; a missing one shows nothing of it.
        let missing = Set(app?.repositories.lazy.filter(\.isMissing).map(\.id) ?? [])
        var facts: [RepositoryID: [WorktreeFacts]] = [:]
        var pullRequests: [RepositoryBranch: BranchPullRequestStatus] = [:]
        for stored in document.work ?? [] where listed.contains(stored.repositoryID) && !missing.contains(stored.repositoryID) {
            let known = stored.worktrees.filter { $0.indicator != nil }
            guard !known.isEmpty, facts[stored.repositoryID] == nil else {
                continue
            }
            facts[stored.repositoryID] = known
            for fact in known {
                if case .branch(let name)? = fact.indicator?.head, let pullRequest = fact.pullRequest, pullRequest != .unknown {
                    pullRequests[RepositoryBranch(repositoryID: stored.repositoryID, name: name)] = pullRequest
                }
            }
        }
        pinnedRepositoryIDs = pinned
        self.activity = activity
        self.snapshots = snapshots
        lastChanged = snapshots.compactMapValues(\.lastChanged)
        changedFilesSamples = snapshots.compactMapValues { $0.changedFilesSample.isEmpty ? nil : $0.changedFilesSample }
        unpushedCommits = commits
        rememberedFacts = facts
        rememberedPullRequests = pullRequests
        work = document.work ?? []
        isLoaded = true
        observeWork()
    }

    /// The state as it's saved.
    private var document: WorktreeActivityDocument {
        var worktrees: [WorktreeActivityDocument.StoredWorktree] = []
        worktrees.reserveCapacity(max(snapshots.count, activity.count))
        for (key, snapshot) in snapshots {
            worktrees.append(.init(
                repositoryID: key.repositoryID,
                path: key.path,
                snapshot: snapshot,
                activity: activity[key],
                unpushedCommits: unpushedCommits[key]
            ))
        }
        for (key, entry) in activity where snapshots[key] == nil {
            worktrees.append(.init(repositoryID: key.repositoryID, path: key.path, snapshot: nil, activity: entry))
        }
        return WorktreeActivityDocument(pinnedRepositoryIDs: pinnedRepositoryIDs, worktrees: worktrees, work: work)
    }

    /// Something that's saved changed: it's written now, or, while saves
    /// happen on their own, `saveDelay` after the first change not yet
    /// saved.
    private func didChange(savingNow: Bool = false) {
        revision &+= 1
        guard isLoaded else {
            return
        }
        if savingNow {
            startWrite()
        } else if autosaves, saveTimer == nil {
            saveTimer = Task { [weak self, scheduler] in
                try? await scheduler.sleep(for: Self.saveDelay)
                guard let self, !Task.isCancelled else {
                    return
                }
                self.saveTimer = nil
                self.startWrite()
            }
        }
    }

    /// Writes the state as it is now, unless it's been written.
    private func startWrite() {
        guard isLoaded else {
            return
        }
        // What the pieces of work are made of is taken as it's written.
        if takeWork() {
            revision &+= 1
        }
        guard revision != savedRevision else {
            return
        }
        let revision = revision
        let document = document
        savedRevision = revision
        writes[revision] = Task { [weak self, store] in
            do {
                try await store.save(document, revision: revision)
            } catch {
                logger.error("Could not save the worktree activity: \(error.localizedDescription, privacy: .public)")
            }
            self?.writes[revision] = nil
        }
    }

    /// Whether everything is saved.
    var isFlushed: Bool {
        !isLoaded || (revision == savedRevision && writes.isEmpty)
    }

    /// Writes what isn't saved yet, without the wait, and returns once
    /// it's written.
    func flush() async {
        saveTimer?.cancel()
        saveTimer = nil
        startWrite()
        while !writes.isEmpty {
            for write in Array(writes.values) {
                await write.value
            }
        }
    }
}
