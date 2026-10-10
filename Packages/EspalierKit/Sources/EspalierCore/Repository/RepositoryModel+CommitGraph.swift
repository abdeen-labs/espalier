// Git's commit-graph file, written once in the background when a repository
// has none. Without it, every page of History in topological order walks the
// whole history, and the sidebar's comparisons of branches with their
// upstreams take about five times as long.

import EspalierSupport
import Foundation
import GitKit

private let logger = Log.logger(category: "repository")

extension RepositoryModel {
    /// Writes git's commit-graph file (`git commit-graph write --reachable
    /// --split`) in the background when the repository has none: when
    /// History opens, and when the sidebar first compares branches with
    /// their upstreams. It changes no commits, refs, or files.
    ///
    /// It runs once per repository, and never twice at once: History and
    /// the sidebar share one write, and worktrees of the same repository
    /// (one object database) don't start a second. It holds no lane, so no
    /// operation ever waits for it, and it doesn't start while an operation
    /// holds one of the repository's lanes (a fetch can write the
    /// commit-graph itself, and git fails on the other's lock); the next
    /// call tries again.
    func writeCommitGraphIfMissing() {
        guard environment.writesCommitGraphs, commitGraphTask == nil, localLane.isFree, networkLane.isFree else {
            return
        }
        // The git common directory once a refresh resolved it.
        let objectDatabase = networkLaneKey
        let app = app
        if let app {
            guard app.commitGraphWrites.insert(objectDatabase).inserted else {
                return
            }
        }
        let environment = environment
        let gitRepository = gitRepository
        commitGraphTask = Task(priority: .utility) { [weak app] in
            do {
                try await environment.withRuntimes {
                    if try await !hasCommitGraph(gitRepository) {
                        try await writeCommitGraph(gitRepository)
                    }
                }
            } catch {
                logger.error("Could not write a commit-graph: \(error.localizedDescription, privacy: .public)")
            }
            app?.commitGraphWrites.remove(objectDatabase)
        }
    }

    /// Waits until the commit-graph write, if one started, is done.
    func commitGraphIdle() async {
        await commitGraphTask?.value
    }
}
