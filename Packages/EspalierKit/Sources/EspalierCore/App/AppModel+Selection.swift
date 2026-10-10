import Foundation

/// How many previously selected repositories are kept.
let recentRepositoriesLength = 3

extension AppModel {
    /// The selected repository's model, when a repository is selected.
    public var selectedRepository: RepositoryModel? {
        guard case .repository(let id) = selection else {
            return nil
        }
        return repository(id)
    }

    /// Selects a repository, a clone, or nothing.
    ///
    /// Synchronous: the repository model is activated (watched while the
    /// window is visible) and its full refresh requested before this
    /// returns, so `idle()` covers it. Its GitHub association refreshes and
    /// the background services start afterwards. A missing repository isn't
    /// activated; recovering it is tried instead. Selecting the selected
    /// repository again refreshes it.
    public func select(_ selection: AppSelection?) {
        if selection == self.selection {
            if case .repository(let id) = selection, let model = repository(id), !model.record.isMissing {
                model.requestRefresh(.full, reason: .selection)
            }
            return
        }

        let previous = self.selection
        if case .repository(let previousID) = previous {
            models[previousID]?.becomeInactive()
        }
        self.selection = selection

        if case .repository(let id) = selection {
            if case .repository(let previousID) = previous {
                updateRecentRepositories(previous: previousID, current: id)
            } else {
                updateRecentRepositories(previous: nil, current: id)
            }
            persistedSelectionID = id
            persist()

            if let model = repository(id) {
                if model.record.isMissing {
                    Task { await self.recoverMissingRepository(id) }
                } else {
                    model.becomeActive(watching: isMainWindowVisible)
                    model.gitHub.repositoryDidBecomeSelected()
                    Task { await self.refreshGitHubAssociation(id) }
                }
            }
        }
        background.update()
    }

    /// Keeps the previously selected repositories, most recent first,
    /// without the current one, at most three.
    func updateRecentRepositories(previous: RepositoryID?, current: RepositoryID) {
        guard previous != current else {
            return
        }
        var recents = recentRepositoryIDs.filter { $0 != current && $0 != previous }
        if let previous {
            recents.insert(previous, at: 0)
        }
        recents = Array(recents.prefix(recentRepositoriesLength))
        if recents != recentRepositoryIDs {
            recentRepositoryIDs = recents
        }
    }
}
