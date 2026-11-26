import EspalierSupport
import Foundation
import GitHubKit
import GitKit
import Observation
import os

/// Whether the repository list has loaded.
public enum AppLoadState: Sendable, Equatable {
    case notLoaded, loading, ready
}

/// What the main window shows.
public enum AppSelection: Hashable, Sendable {
    case repository(RepositoryID)
    case clone(CloneID)
}

/// A worktree whose folder disappeared while it was selected: the window
/// shows another worktree of its repository instead.
public struct RemovedWorktreeNotice: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The removed worktree's folder name.
    public let worktreeName: String
    /// The name of the repository selected instead.
    public let shownName: String

    public init(id: UUID = UUID(), worktreeName: String, shownName: String) {
        self.id = id
        self.worktreeName = worktreeName
        self.shownName = shownName
    }
}

/// A problem with the repository list file, to tell the user about.
public enum PersistenceIssue: Sendable, Equatable {
    /// The list couldn't be read; the file was moved aside and what could be
    /// read was kept.
    case repositoryListUnreadable(movedTo: URL)
    /// The list was written by a newer version of Espalier; it was left
    /// alone and nothing is saved this session.
    case repositoryListFromNewerVersion(Int)
    /// The list couldn't be read or moved aside (the reason); nothing is
    /// saved this session.
    case repositoryListInaccessible(String)
    /// Saving the list failed (the reason); the previous file is intact.
    case repositoryListSaveFailed(String)
}

/// The app: its repositories, what's selected, and the app-wide features.
@MainActor @Observable
public final class AppModel {
    @ObservationIgnored public let environment: AppEnvironment

    // MARK: Lifecycle (AppModel+Lifecycle.swift)

    public internal(set) var loadState: AppLoadState = .notLoaded
    /// Whether Espalier is the active app.
    public internal(set) var isActive = true
    /// Whether the main window is visible (not occluded). It counts as
    /// visible until the window reports otherwise.
    public internal(set) var isMainWindowVisible = true

    // MARK: Repository list

    /// The repositories, in the order they were added.
    public internal(set) var repositories: [RepositoryRecord] = []
    /// What the repository list shows of each repository's status, once it
    /// has loaded: its head, ahead/behind, changed files, and stopped
    /// operation.
    public internal(set) var indicators: [RepositoryID: RepositoryIndicator] = [:]
    /// Every listed repository's worktrees, the main one first, then the
    /// linked ones in git's order, each with its status, once they have
    /// loaded (`WorktreeStatusWatcher`, WorktreeStatus.swift). None while
    /// the repository indicators are off.
    public internal(set) var worktreeStatuses: [RepositoryID: [WorktreeStatus]] = [:]
    /// How the pull request of each repository's branch is doing, for the
    /// branches kept current (BranchPullRequestStatus.swift); read it with
    /// `pullRequestStatus(for:branch:)`.
    public internal(set) var branchPullRequests: [RepositoryBranch: BranchPullRequestStatus] = [:]
    /// Called when a refresh finds that something happened to a branch's
    /// pull request: it was opened, merged, or closed, its checks finished,
    /// or a review approved it or requested changes. A branch's first load
    /// is never news.
    @ObservationIgnored public var onPullRequestNews: (@MainActor (PullRequestNews) -> Void)?
    /// The previously selected repositories, most recent first, at most
    /// three, without the current one.
    public internal(set) var recentRepositoryIDs: [RepositoryID] = []

    // MARK: Selection (AppModel+Selection.swift)

    public internal(set) var selection: AppSelection?

    // MARK: Watched folders (AppModel+WatchedFolders.swift)

    /// Whether a scan of the watched folders is running, or waiting for one
    /// that is.
    public internal(set) var isScanningFolders = false

    // MARK: Feature models

    @ObservationIgnored public let preferences: Preferences
    @ObservationIgnored public let prompts: PromptCenter
    @ObservationIgnored public let accounts: AccountsModel
    @ObservationIgnored public let integrations: IntegrationsModel
    @ObservationIgnored public let clones: CloneCoordinator
    @ObservationIgnored public let ai: AIModel
    /// The worktrees' activity, what's unseen, when each last changed, and
    /// the pinned repositories (`board` and `shelf` are made of them).
    @ObservationIgnored public let worktreeActivity: WorktreeActivityModel
    /// Moves pieces of work out of In Progress when their time runs out.
    @ObservationIgnored public let workClock: WorkClock
    /// All Work's viewed marks, every worktree's.
    @ObservationIgnored public let viewedMarks: ViewedMarksStore

    // MARK: Unsolicited facts

    public internal(set) var persistenceIssue: PersistenceIssue?
    /// The selected worktree whose folder disappeared, until the user has
    /// been told.
    public internal(set) var removedWorktreeNotice: RemovedWorktreeNotice?

    // MARK: Internals

    /// Starts and stops the background services.
    @ObservationIgnored var background: BackgroundCoordinator!
    @ObservationIgnored let listStore: RepositoryListStore
    @ObservationIgnored var models: [RepositoryID: RepositoryModel] = [:]
    @ObservationIgnored var gitHubRepositories = GitHubRepositoryTable()
    @ObservationIgnored let networkLanes = NetworkLaneRegistry()
    /// The git common directories whose commit-graph file a repository is
    /// writing (RepositoryModel+CommitGraph.swift).
    @ObservationIgnored var commitGraphWrites: Set<String> = []
    /// The repository to select at the next launch.
    @ObservationIgnored var persistedSelectionID: RepositoryID?
    @ObservationIgnored var documentRevision: UInt64 = 0
    @ObservationIgnored var isSaveScheduled = false
    @ObservationIgnored var saveTasks: [Task<Void, Never>] = []
    /// The questions about a repository's account being asked, by
    /// repository (RepositoryAccounts.swift): asking again joins the one
    /// already asked.
    @ObservationIgnored var repositoryAccountPrompts: [RepositoryID: Task<Account?, Never>] = [:]
    /// The scan of the watched folders asked for last, while it or one
    /// before it runs: the next one waits for it.
    @ObservationIgnored var folderScan: Task<[RepositoryID], Never>?
    /// The scans of the watched folders asked for and not finished.
    @ObservationIgnored var folderScansInFlight = 0
    /// When a scan of every watched folder was last asked for.
    @ObservationIgnored var lastWatchedFoldersScan: Date?
    /// Called with each status that loads for a worktree other than the one
    /// its repository's record points at (`worktreeStatusDidLoad`).
    @ObservationIgnored var onWorktreeStatus: (@MainActor (WorktreeStatusUpdate) -> Void)?

    public init(environment: AppEnvironment) {
        self.environment = environment
        preferences = Preferences(store: PreferenceStore(environment.defaults.defaults), homeDirectory: environment.homeDirectory)
        prompts = environment.prompts
        accounts = AccountsModel(store: environment.accountsStore)
        integrations = IntegrationsModel(environment: environment, preferences: preferences)
        clones = CloneCoordinator()
        ai = AIModel(environment: environment)
        worktreeActivity = WorktreeActivityModel(environment: environment)
        workClock = WorkClock(scheduler: environment.scheduler)
        viewedMarks = ViewedMarksStore(fileURL: environment.directories.viewedMarks)
        let scheduler = environment.scheduler
        listStore = RepositoryListStore(fileURL: environment.directories.repositoryList, now: { scheduler.now })
        background = BackgroundCoordinator(app: self, environment: environment)
        clones.app = self
        worktreeActivity.app = self
        workClock.app = self
        accounts.attach(to: self)
        ai.attach(to: self)
    }

    /// The record of a repository in the list.
    public func record(_ id: RepositoryID) -> RepositoryRecord? {
        repositories.first { $0.id == id }
    }

    /// The model of a repository in the list, created on first use and
    /// dropped when the repository is removed.
    public func repository(_ id: RepositoryID) -> RepositoryModel? {
        if let model = models[id] {
            return model
        }
        guard let record = record(id) else {
            return nil
        }
        let model = RepositoryModel(record: record, app: self, environment: environment)
        models[id] = model
        return model
    }

    /// Forgets the persistence issue once the user has seen it.
    public func dismissPersistenceIssue() {
        persistenceIssue = nil
    }

    /// Forgets the removed worktree once the user has been told.
    public func dismissRemovedWorktreeNotice() {
        removedWorktreeNotice = nil
    }
}
