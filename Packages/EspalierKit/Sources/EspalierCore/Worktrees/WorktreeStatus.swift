// What the repository list shows of each repository's worktrees.
// `WorktreeStatusWatcher` keeps it current.

import EspalierSupport
import GitKit

/// One of a repository's worktrees, with its status
/// (`AppModel.worktreeStatuses`).
///
/// A status of its own is run only for a worktree nothing else covers:
///
/// | Worktree | Its indicator |
/// |---|---|
/// | The one the repository's record points at (`isCurrent`) | the repository's, `AppModel.indicators[id]` |
/// | One whose folder is another repository in the list (`repositoryID`) | that repository's, `AppModel.indicators[repositoryID]` |
/// | Any other | `indicator`, from a status run in its folder |
///
/// `AppModel.indicator(for:of:)` picks the right one.
public struct WorktreeStatus: Sendable, Equatable, Identifiable {
    /// The worktree, as `git worktree list` has it.
    public var entry: WorktreeEntry
    /// Whether it's the worktree the repository's record points at.
    public var isCurrent: Bool
    /// The other repository in the list whose folder this worktree is, if
    /// there's one.
    public var repositoryID: RepositoryID?
    /// What a status in the worktree's folder told. Nil until one has
    /// loaded, when the folder is gone or isn't a repository, and for a
    /// worktree whose indicator is a repository's.
    public var indicator: RepositoryIndicator?

    public init(
        entry: WorktreeEntry,
        isCurrent: Bool = false,
        repositoryID: RepositoryID? = nil,
        indicator: RepositoryIndicator? = nil
    ) {
        self.entry = entry
        self.isCurrent = isCurrent
        self.repositoryID = repositoryID
        self.indicator = indicator
    }

    /// The worktree's folder, which no two worktrees share.
    public var id: ExactString {
        ExactString(entry.path)
    }

    /// The local branch the worktree has checked out: its status's, else
    /// its list entry's; nil when it's detached.
    public var branchName: String? {
        switch indicator?.head {
        case .branch(let name)?, .unborn(let name)?:
            return name
        case .detached?:
            return nil
        case nil:
            let prefix = "refs/heads/"
            guard let ref = entry.branch, JSCompat.startsWith(ref, prefix) else {
                return nil
            }
            return JSCompat.dropFirst(ref, prefix.unicodeScalars.count)
        }
    }
}

/// A status that loaded for a worktree other than the one its repository's
/// record points at (`AppModel.worktreeStatusDidLoad`).
struct WorktreeStatusUpdate: Sendable {
    /// The repository whose worktree it is.
    let repositoryID: RepositoryID
    /// The worktree's folder, as `git worktree list` has it.
    let worktreePath: String
    /// The worktree's git directory, when it's known.
    var gitDirectory: String?
    let status: StatusResult
    /// The tip the status tells (`tipFromStatus`).
    let tip: Tip
}

extension AppModel {
    /// The indicator the list shows for `worktree`, one of repository
    /// `id`'s (`WorktreeStatus`'s table).
    public func indicator(for worktree: WorktreeStatus, of id: RepositoryID) -> RepositoryIndicator? {
        if worktree.isCurrent {
            return indicators[id]
        }
        if let repositoryID = worktree.repositoryID {
            return indicators[repositoryID]
        }
        return worktree.indicator
    }

    /// Sets a repository's worktrees, or removes them. The activity of
    /// the worktrees a loaded list no longer has is forgotten.
    func setWorktreeStatuses(_ statuses: [WorktreeStatus]?, for id: RepositoryID) {
        if worktreeStatuses[id] != statuses {
            worktreeStatuses[id] = statuses
        }
        if let statuses, !statuses.isEmpty, let record = record(id) {
            worktreeActivity.forgetWorktrees(of: id, except: [record.path] + statuses.map(\.entry.path))
        }
    }

    /// The hook for worktree statuses: every status that loads for a
    /// worktree other than the one its repository's record points at comes
    /// through here, on the main actor, after its indicator is set. The
    /// first comes when the worktree starts being watched, then one about a
    /// second after each change to its files or its git state, whether or
    /// not it differs from the last. A worktree several repositories in
    /// the list have comes once for each. What the status differs in from
    /// the worktree's last is recorded as activity
    /// (`WorktreeActivityModel.recordStatus`), keyed by the folder as
    /// `git worktree list` has it; `onWorktreeStatus` is called first.
    ///
    /// (The worktree a record points at gets its statuses from its
    /// repository's refresh passes: `RepositoryRefresher`'s step 3.)
    func worktreeStatusDidLoad(_ update: WorktreeStatusUpdate) async {
        onWorktreeStatus?(update)
        let snapshot = await WorktreeStatusSnapshot.load(
            update.status,
            workingDirectory: update.worktreePath,
            gitDirectory: update.gitDirectory
        )
        worktreeActivity.recordStatus(snapshot, forWorktreeAt: update.worktreePath, of: update.repositoryID)
        await worktreeActivity.recordStatusForUnpushedCommits(
            update.status,
            forWorktreeAt: update.worktreePath,
            gitDirectory: update.gitDirectory,
            of: update.repositoryID
        )
    }
}
