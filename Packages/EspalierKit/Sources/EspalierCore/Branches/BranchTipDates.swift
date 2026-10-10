// Ported in part from desktop/app/src/ui/branches/branch-list.tsx
//
// The author date of the commit each branch points at, which branch lists
// show beside the name. Each repository's branches model keeps a cache,
// keyed by commit, so it never goes stale.

import EspalierSupport
import Foundation
import GitKit
import os

private let logger = Log.logger(category: "branches")

/// The most dates kept; past it the cache starts over.
let branchTipDateCacheSize = 10_000

/// Author dates by commit, for branch lists.
@MainActor
final class BranchTipDateCache {
    private var dates: [ExactString: Date] = [:]

    /// How many dates are cached (for tests).
    var count: Int {
        dates.count
    }

    func date(for sha: String) -> Date? {
        dates[ExactString(sha)]
    }

    func store(_ date: Date, for sha: String) {
        if dates.count >= branchTipDateCacheSize {
            dates.removeAll(keepingCapacity: true)
        }
        dates[ExactString(sha)] = date
    }

    func removeAll() {
        dates.removeAll()
    }
}

extension BranchesModel {
    /// The cached author date of the commit `sha`, if it was loaded.
    public func cachedTipDate(_ sha: String) -> Date? {
        tipDateCache.date(for: sha)
    }

    /// The author dates of the commits `branches` point at, by SHA: cached
    /// dates at once, the others read with one `git log --no-walk` for every
    /// missing commit. When git fails, the dates already cached are returned
    /// and the failure is logged; branch lists then show no date.
    public func tipDates(for branches: [Branch]) async -> [String: Date] {
        var result: [String: Date] = [:]
        var missing: [String] = []
        var seen: Set<ExactString> = []
        for branch in branches {
            let sha = branch.tip.sha
            guard seen.insert(ExactString(sha)).inserted else {
                continue
            }
            if let date = tipDateCache.date(for: sha) {
                result[sha] = date
            } else {
                missing.append(sha)
            }
        }
        guard !missing.isEmpty, let repository else {
            return result
        }

        let gitRepository = repository.gitRepository
        let shas = missing
        let authors: [CommitIdentity]
        do {
            authors = try await repository.environment.withRuntimes {
                try await getAuthors(gitRepository, shas)
            }
        } catch {
            logger.error("Failed to populate commit dates: \(error.localizedDescription, privacy: .public)")
            return result
        }
        for (sha, author) in zip(shas, authors) {
            tipDateCache.store(author.date, for: sha)
            result[sha] = author.date
        }
        return result
    }
}
