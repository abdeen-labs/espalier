// The viewed marks All Work's files carry, saved beside the repository list
// (`viewed-marks.json`): per worktree, each marked file's path and the
// content it had when marked.

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "persistence")

/// The viewed marks of every worktree, read from their file the first time
/// they're asked for and written after each change, off the main actor.
@MainActor
public final class ViewedMarksStore {
    public nonisolated let fileURL: URL
    /// Each worktree's marks, by its path: each marked file's content ID,
    /// by its path. Nil until read.
    private var worktrees: [ExactString: [ExactString: String]]?
    private let writer: ViewedMarksWriter
    private var revision: UInt64 = 0
    /// The last save, for `idle()`.
    private var lastSave: Task<Void, Never>?

    /// - Parameter fileURL: The marks' file (`AppDirectories.viewedMarks`).
    public init(fileURL: URL) {
        self.fileURL = fileURL
        writer = ViewedMarksWriter(fileURL: fileURL)
    }

    /// The marks of the worktree at `worktree`: each marked file's content
    /// ID when it was marked, by its path.
    public func marks(for worktree: String) -> [ExactString: String] {
        loaded()[ExactString(worktree)] ?? [:]
    }

    /// Replaces the marks of the worktree at `worktree` and saves them; no
    /// marks forget the worktree.
    public func setMarks(_ marks: [ExactString: String], for worktree: String) {
        var worktrees = loaded()
        let key = ExactString(worktree)
        guard worktrees[key] ?? [:] != marks else {
            return
        }
        worktrees[key] = marks.isEmpty ? nil : marks
        self.worktrees = worktrees
        revision &+= 1
        let document = ViewedMarksDocument(worktrees)
        let revision = revision
        let writer = writer
        let previous = lastSave
        lastSave = Task {
            await previous?.value
            await writer.write(document, revision: revision)
        }
    }

    /// Waits until the saves started so far have been written.
    public func idle() async {
        await lastSave?.value
    }

    private func loaded() -> [ExactString: [ExactString: String]] {
        if let worktrees {
            return worktrees
        }
        let read = Self.read(fileURL)
        worktrees = read
        return read
    }

    /// The marks in the file at `url`; none when there's no file, or it
    /// can't be read.
    nonisolated static func read(_ url: URL) -> [ExactString: [ExactString: String]] {
        guard let data = try? Data(contentsOf: url) else {
            return [:]
        }
        do {
            return try JSONDecoder().decode(ViewedMarksDocument.self, from: data).marks
        } catch {
            logger.error("Could not read the viewed marks: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}

/// The marks' file: a list of worktrees, each with its marked files. Lists,
/// not dictionaries, so paths that differ only in Unicode normalization
/// stay apart.
struct ViewedMarksDocument: Codable, Sendable, Equatable {
    struct Worktree: Codable, Sendable, Equatable {
        var path: String
        var files: [File]
    }

    struct File: Codable, Sendable, Equatable {
        var path: String
        var content: String
    }

    var version = 1
    var worktrees: [Worktree]

    init(_ marks: [ExactString: [ExactString: String]]) {
        worktrees = marks
            .map { worktree, files in
                Worktree(
                    path: worktree.value,
                    files: files.map { File(path: $0.key.value, content: $0.value) }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
                )
            }
            .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    var marks: [ExactString: [ExactString: String]] {
        var marks: [ExactString: [ExactString: String]] = [:]
        for worktree in worktrees {
            var files: [ExactString: String] = [:]
            for file in worktree.files {
                files[ExactString(file.path)] = file.content
            }
            marks[ExactString(worktree.path)] = files
        }
        return marks
    }
}

/// Writes the marks' file atomically, skipping a document older than the
/// last one written.
private actor ViewedMarksWriter {
    let fileURL: URL
    private var lastRevision: UInt64?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func write(_ document: ViewedMarksDocument, revision: UInt64) {
        if let lastRevision, revision <= lastRevision {
            return
        }
        lastRevision = revision
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Could not save the viewed marks: \(error.localizedDescription, privacy: .public)")
        }
    }
}
