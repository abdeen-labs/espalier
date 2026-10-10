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
    /// The repository list's badges.
    public internal(set) var indicators: [RepositoryID: RepositoryIndicator] = [:]
    /// The previously selected repositories, most recent first, at most
    /// three, without the current one.
    public internal(set) var recentRepositoryIDs: [RepositoryID] = []

    // MARK: Selection (AppModel+Selection.swift)

    public internal(set) var selection: AppSelection?

    // MARK: Feature models

    @ObservationIgnored public let preferences: Preferences
    @ObservationIgnored public let prompts: PromptCenter
    @ObservationIgnored public let accounts: AccountsModel
    @ObservationIgnored public let integrations: IntegrationsModel
    @ObservationIgnored public let clones: CloneCoordinator
    @ObservationIgnored public let ai: AIModel

    // MARK: Unsolicited facts

    public internal(set) var persistenceIssue: PersistenceIssue?

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

    public init(environment: AppEnvironment) {
        self.environment = environment
        preferences = Preferences(store: PreferenceStore(environment.defaults.defaults), homeDirectory: environment.homeDirectory)
        prompts = environment.prompts
        accounts = AccountsModel(store: environment.accountsStore)
        integrations = IntegrationsModel(environment: environment, preferences: preferences)
        clones = CloneCoordinator()
        ai = AIModel(environment: environment)
        let scheduler = environment.scheduler
        listStore = RepositoryListStore(fileURL: environment.directories.repositoryList, now: { scheduler.now })
        background = BackgroundCoordinator(app: self, environment: environment)
        clones.app = self
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
}
