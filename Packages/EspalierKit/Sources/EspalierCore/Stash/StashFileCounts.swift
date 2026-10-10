// How many files each listed stash entry changes, for the sidebar's
// Stashes section, which lists every branch's entry with its count.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "stash")

extension StashModel {
    /// How many files `entry` changes, once counted (`countFiles()`), as the
    /// stash's file list shows them.
    public func fileCount(of entry: StashEntry) -> Int? {
        fileCounts[entry.stashSha]
    }

    /// Counts the files of the listed entries (each branch's newest automatic
    /// stash) that aren't counted yet, and forgets the counts of entries no
    /// longer listed. Does nothing once every entry is counted, so the sidebar
    /// can call it whenever the list changes.
    ///
    /// The count is the length of `getStashedFiles`, the list the stash's
    /// place shows. An entry whose files can't be listed stays uncounted.
    public func countFiles() {
        guard let repository else {
            return
        }
        let listed = Set(repository.gitState.stashes.entriesByBranch.values.map(\.stashSha))
        let kept = fileCounts.filter { listed.contains($0.key) }
        if kept.count != fileCounts.count {
            fileCounts = kept
        }
        let missing = listed.filter { kept[$0] == nil }.sorted()
        guard !missing.isEmpty else {
            countLoads.cancel()
            return
        }
        if countLoads.isRunning, countLoads.currentKey == missing {
            return
        }

        let gitRepository = repository.gitRepository
        let environment = repository.environment
        countLoads.run(missing, operation: {
            await environment.withRuntimes {
                await countStashedFiles(missing, in: gitRepository)
            }
        }, apply: { [weak self] (result: Result<[String: Int], any Error>) in
            guard let self, case .success(let counts) = result else {
                return
            }
            for (sha, count) in counts {
                self.recordFileCount(count, of: sha)
            }
        })
    }

    /// Records that the entry `stashSha` changes `count` files, while it's
    /// listed.
    func recordFileCount(_ count: Int, of stashSha: String) {
        guard fileCounts[stashSha] != count,
              repository?.gitState.stashes.entriesByBranch.values.contains(where: { $0.stashSha == stashSha }) == true
        else {
            return
        }
        fileCounts[stashSha] = count
    }
}

/// The number of files each of `shas` changes, skipping those git can't
/// list.
@concurrent
private func countStashedFiles(_ shas: [String], in repository: Repository) async -> [String: Int] {
    var counts: [String: Int] = [:]
    for sha in shas {
        guard !Task.isCancelled else {
            break
        }
        do {
            counts[sha] = try await getStashedFiles(repository, sha).count
        } catch {
            logger.error("Could not count the files of stash \(sha, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
    return counts
}
