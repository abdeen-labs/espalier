import EspalierSupport
import Foundation
import GitHubKit
import os

private let logger = Log.logger(category: "persistence")

extension AppModel {
    /// Changes a repository's record, pushes it to its model, and persists
    /// the list.
    func updateRecord(_ id: RepositoryID, _ change: (inout RepositoryRecord) -> Void) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else {
            return
        }
        var record = repositories[index]
        change(&record)
        guard record != repositories[index] else {
            return
        }
        repositories[index] = record
        models[id]?.recordDidChange(record)
        persist()
    }

    /// Changes the GitHub repository table and persists the list. Records
    /// keep their resolved GitHub repositories; rebuild them with
    /// `gitHubRepositories.gitHubRepository(withID:)` when a row changes.
    func updateGitHubRepositories(_ change: (inout GitHubRepositoryTable) -> Void) {
        var table = gitHubRepositories
        change(&table)
        guard table != gitHubRepositories else {
            return
        }
        gitHubRepositories = table
        persist()
    }

    /// Marks a repository missing, or found again.
    func setMissing(_ missing: Bool, for id: RepositoryID) {
        updateRecord(id) { $0.isMissing = missing }
        if missing {
            setIndicator(nil, for: id)
            models[id]?.setAvailability(.missing)
        }
    }

    /// Sets or removes a repository's badge.
    func setIndicator(_ indicator: RepositoryIndicator?, for id: RepositoryID) {
        if indicators[id] != indicator {
            indicators[id] = indicator
        }
    }

    // MARK: The document

    /// The repository list as it's saved.
    var document: RepositoryListDocument {
        RepositoryListDocument(
            records: repositories,
            gitHubRepositories: gitHubRepositories,
            selectedRepositoryID: persistedSelectionID,
            recentRepositoryIDs: recentRepositoryIDs
        )
    }

    /// Records a change to the list and schedules one save per main-actor
    /// turn. The store skips saves older than the last one written.
    func persist() {
        documentRevision &+= 1
        guard !isSaveScheduled else {
            return
        }
        isSaveScheduled = true
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            self.isSaveScheduled = false
            await self.saveNow()
        }
        saveTasks.append(task)
    }

    /// Writes the current list.
    func saveNow() async {
        guard loadState == .ready else {
            return
        }
        let revision = documentRevision
        let document = document
        do {
            try await listStore.save(document, revision: revision)
        } catch {
            logger.error("Could not save the repository list: \(error.localizedDescription, privacy: .public)")
            persistenceIssue = .repositoryListSaveFailed(error.localizedDescription)
        }
    }

    /// Waits for every scheduled save to be written.
    func flushPersistence() async {
        while !saveTasks.isEmpty {
            let tasks = saveTasks
            saveTasks = []
            for task in tasks {
                await task.value
            }
        }
    }
}
