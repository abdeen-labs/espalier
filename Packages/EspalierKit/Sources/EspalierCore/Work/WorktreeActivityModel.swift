import EspalierSupport
import Foundation
import GitKit
import Observation
import os

private let logger = Log.logger(category: "worktree-activity")

/// What's kept about the repositories to order and mark them:
/// when each kind of activity last happened in each worktree, which
/// worktrees have activity the user hasn't seen, and the pinned
/// repositories. `AppModel.arrangedRepositories` is the list made of it.
///
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

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let store: WorktreeActivityStore
    @ObservationIgnored private let scheduler: any Scheduler
    /// Whether changes are saved on their own, `saveDelay` after them.
    @ObservationIgnored private let autosaves: Bool
    /// Each worktree's last status, as its snapshot.
    @ObservationIgnored private(set) var snapshots: [WorktreeKey: WorktreeStatusSnapshot] = [:]

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

    init(environment: AppEnvironment) {
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

    private func isListed(_ id: RepositoryID) -> Bool {
        app?.record(id) != nil
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
        for worktree in document.worktrees where listed.contains(worktree.repositoryID) {
            let key = WorktreeKey(repositoryID: worktree.repositoryID, path: worktree.path)
            activity[key] = worktree.activity
            snapshots[key] = worktree.snapshot
        }
        pinnedRepositoryIDs = pinned
        self.activity = activity
        self.snapshots = snapshots
        isLoaded = true
    }

    /// The state as it's saved.
    private var document: WorktreeActivityDocument {
        var worktrees: [WorktreeActivityDocument.StoredWorktree] = []
        worktrees.reserveCapacity(max(snapshots.count, activity.count))
        for (key, snapshot) in snapshots {
            worktrees.append(.init(repositoryID: key.repositoryID, path: key.path, snapshot: snapshot, activity: activity[key]))
        }
        for (key, entry) in activity where snapshots[key] == nil {
            worktrees.append(.init(repositoryID: key.repositoryID, path: key.path, snapshot: nil, activity: entry))
        }
        return WorktreeActivityDocument(pinnedRepositoryIDs: pinnedRepositoryIDs, worktrees: worktrees)
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
        guard isLoaded, revision != savedRevision else {
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
