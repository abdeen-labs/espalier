// The refresh loads only the local commits' SHAs, so the Changes column's
// last-commit row loads the newest one here.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "commit")

extension CommitModel {
    /// Loads the newest local commit when it changed: the first of
    /// `gitState.localCommitSHAs`, from the history when it's loaded there,
    /// else with `git log`. With no local commits, forgets it.
    func loadMostRecentLocalCommit() {
        guard let repository else {
            return
        }
        guard let sha = repository.gitState.localCommitSHAs.first else {
            mostRecentLocalCommitLoads.cancel()
            if mostRecentLocalCommit != nil {
                mostRecentLocalCommit = nil
            }
            return
        }
        if let loaded = mostRecentLocalCommit, JSCompat.strictEquals(loaded.sha, sha) {
            return
        }
        if mostRecentLocalCommitLoads.isRunning, let key = mostRecentLocalCommitLoads.currentKey, JSCompat.strictEquals(key, sha) {
            return
        }
        if let commit = repository.history.commit(sha) {
            mostRecentLocalCommitLoads.cancel()
            mostRecentLocalCommit = commit
            return
        }

        let gitRepository = repository.gitRepository
        let environment = repository.environment
        mostRecentLocalCommitLoads.run(sha, operation: {
            try await environment.withRuntimes {
                try await getCommit(gitRepository, sha)
            }
        }, apply: { [weak self] (result: Result<Commit?, any Error>) in
            guard let self else {
                return
            }
            switch result {
            case .success(let commit?):
                // Still the newest local commit?
                if let newest = self.repository?.gitState.localCommitSHAs.first, JSCompat.strictEquals(newest, commit.sha) {
                    self.mostRecentLocalCommit = commit
                }
            case .success(nil):
                self.mostRecentLocalCommit = nil
            case .failure(let error):
                logger.error("Could not load the most recent local commit: \(error.localizedDescription, privacy: .public)")
                self.mostRecentLocalCommit = nil
            }
        })
    }

    /// Waits for the newest local commit's load (for tests).
    func mostRecentLocalCommitIdle() async {
        await mostRecentLocalCommitLoads.idle()
    }
}
