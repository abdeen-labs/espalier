import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "persistence")

/// The worktrees' activity, the pinned repositories, and what each
/// repository's pieces of work were made of, as they're kept between
/// launches: `worktree-activity.json`.
///
/// ```json
/// {
///   "pinnedRepositoryIDs": ["0F4C…"],
///   "worktrees": [{
///     "repositoryID": "0F4C…",
///     "path": "/Users/me/src/app",
///     "snapshot": { "tip": "5d3a…", "branch": "main", "behind": 0, "changedFiles": "9c1e…" },
///     "activity": { "files": 785000000.25, "lastOpen": 785000100.5 }
///   }],
///   "work": [{
///     "repositoryID": "0F4C…",
///     "worktrees": [{ "path": "/Users/me/src/app", "isCurrent": true, "indicator": { … } }]
///   }]
/// }
/// ```
///
/// Dates are seconds since 2001, with their fractions, so two times
/// compare after a launch as they did before it.
struct WorktreeActivityDocument: Codable, Sendable, Equatable {
    /// The pinned repositories, in the order they were pinned.
    var pinnedRepositoryIDs: [RepositoryID] = []
    var worktrees: [StoredWorktree] = []
    /// What each repository's pieces of work were made of
    /// (`WorktreeActivityModel.rememberedFacts`); nil in a document saved
    /// without them.
    var work: [StoredWork]?

    /// What's kept for one worktree of a repository.
    struct StoredWorktree: Codable, Sendable, Equatable {
        var repositoryID: RepositoryID
        var path: String
        /// What its last status told.
        var snapshot: WorktreeStatusSnapshot?
        /// When each kind of activity last happened in it, and when it was
        /// last open.
        var activity: WorktreeActivity?
        /// The commits it had to push.
        var unpushedCommits: UnpushedCommits?
    }

    /// What one repository's pieces of work were made of: its worktrees
    /// that a status had told of, in their order.
    struct StoredWork: Codable, Sendable, Equatable {
        var repositoryID: RepositoryID
        var worktrees: [WorktreeFacts]
    }
}

/// Reads and writes the worktrees' activity and the pins.
///
/// Saves are atomic, and each carries the model's revision number: a save
/// older than the last one written is skipped, because tasks reaching an
/// actor are not ordered.
actor WorktreeActivityStore {
    nonisolated let fileURL: URL

    private var lastSavedRevision: UInt64?

    /// - Parameter fileURL: The document (`AppDirectories.worktreeActivity`).
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The saved state; nothing when there is none, or it can't be read.
    func load() -> WorktreeActivityDocument {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return WorktreeActivityDocument()
        }
        do {
            return try JSONDecoder().decode(WorktreeActivityDocument.self, from: data)
        } catch {
            logger.error("Could not read the worktree activity: \(error.localizedDescription, privacy: .public)")
            return WorktreeActivityDocument()
        }
    }

    /// Writes `document`, unless a later revision has already been written.
    ///
    /// - Returns: Whether the document was written.
    @discardableResult
    func save(_ document: WorktreeActivityDocument, revision: UInt64) throws -> Bool {
        if let lastSavedRevision, revision <= lastSavedRevision {
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        lastSavedRevision = revision
        return true
    }
}
