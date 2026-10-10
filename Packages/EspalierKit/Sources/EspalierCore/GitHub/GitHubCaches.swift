// Pull requests, issues, and mentionable users are kept in JSON files under
// `~/Library/Caches/dev.abdeen.espalier/<kind>/<id>.json`, which may be
// deleted at any time and rebuild from the API.

import EspalierSupport
import Foundation
import os
import Synchronization

private let logger = Log.logger(category: "github-cache")

/// JavaScript's `Date.parse` for the ISO 8601 timestamps GitHub sends; nil
/// where JavaScript returns `NaN`.
func parseGitHubTimestamp(_ string: String) -> Date? {
    if let date = try? Date(string, strategy: .iso8601) {
        return date
    }
    return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

/// An ISO 8601 timestamp with second resolution, as GitHub sends them.
func gitHubTimestamp(_ date: Date) -> String {
    date.formatted(.iso8601)
}

/// Reads and writes the GitHub caches, one file at a time.
///
/// Writes are atomic. Each write carries a revision taken on the caller's
/// side when the data was current (`nextRevision()`); since tasks reaching an
/// actor don't arrive in order, a write older than the last one written to
/// the same file is skipped. A file that can't be read or decoded is
/// removed: the caller starts over from the API, as with no file.
actor GitHubCacheFiles {
    /// The one instance: every cache file goes through it.
    static let shared = GitHubCacheFiles()

    private static let revisions = Mutex<UInt64>(0)

    /// A revision for a write about to be requested: later calls get later
    /// revisions.
    nonisolated static func nextRevision() -> UInt64 {
        revisions.withLock { revision in
            revision &+= 1
            return revision
        }
    }

    private var lastWritten: [String: UInt64] = [:]

    /// The decoded file, or nil when it's missing or unreadable (then it's
    /// removed).
    func read<Value: Decodable>(_ url: URL, as type: Value.Type) -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return nil
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            logger.info("Removing the unreadable cache \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Writes `value` to `url` unless a later revision was written already.
    func write<Value: Encodable & Sendable>(_ value: Value, to url: URL, revision: UInt64) {
        let key = url.path(percentEncoded: false)
        if let last = lastWritten[key], last > revision {
            return
        }
        lastWritten[key] = revision
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Could not write the cache \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Removes the file, unless a later revision was written already.
    func remove(_ url: URL, revision: UInt64) {
        let key = url.path(percentEncoded: false)
        if let last = lastWritten[key], last > revision {
            return
        }
        lastWritten[key] = revision
        try? FileManager.default.removeItem(at: url)
    }
}

/// The kinds of GitHub cache, each a directory of files named by the GitHub
/// repository's ID in the repository list (`GitHubRepository.dbID`).
enum GitHubCacheKind: String {
    case pullRequests = "pull-requests"
    case issues
    case mentionables

    /// The file for `gitHubRepositoryID` under `directories`.
    func url(in directories: AppDirectories, gitHubRepositoryID: Int) -> URL {
        directories.cacheDirectory(rawValue).appending(path: "\(gitHubRepositoryID).json", directoryHint: .notDirectory)
    }
}

/// Identifies the GitHub repository a cache file was written for, so a file
/// whose ID now names another repository (a list from another Mac, a
/// restored backup) is ignored.
struct CachedRepositoryIdentity: Codable, Sendable, Hashable {
    let endpoint: String
    let owner: String
    let name: String

    init(endpoint: String, owner: String, name: String) {
        self.endpoint = endpoint
        self.owner = owner
        self.name = name
    }

    /// Whether this names the same repository, ignoring case as GitHub does.
    func matches(endpoint: String, owner: String, name: String) -> Bool {
        JSCompat.caseInsensitiveEquals(self.endpoint, endpoint)
            && JSCompat.caseInsensitiveEquals(self.owner, owner)
            && JSCompat.caseInsensitiveEquals(self.name, name)
    }
}
