import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "persistence")

/// What loading the repository list found.
public enum RepositoryListLoadResult: Sendable, Equatable {
    /// There is no repository list yet.
    case empty

    /// The list, read in full.
    case loaded(RepositoryListDocument)

    /// The file couldn't be read in full. It was moved to `movedAside`, and
    /// the document is what could be read from it (possibly nothing), which
    /// was saved in its place.
    case recovered(RepositoryListDocument, movedAside: URL)

    /// The file was written by a newer version of Espalier (this schema
    /// version). Nothing was loaded, and the store saves nothing this
    /// session, so the file stays as it is.
    case newerVersion(Int)

    /// The file couldn't be read, or couldn't be moved aside (the reason).
    /// Nothing was loaded, and the store saves nothing this session.
    case unreadable(String)
}

/// Errors from `RepositoryListStore`.
public enum RepositoryListStoreError: Error, Equatable {
    /// `save` was called before `load`, which decides whether saving is safe.
    case notLoaded
}

/// Reads and writes the repository list document.
///
/// Saves are atomic: the document is encoded on the actor and written to a
/// temporary file that replaces the old one, so a reader (or a crash) never
/// sees half a list. Each save carries the model's revision number, and a
/// save older than the last one written is skipped, because tasks reaching
/// an actor are not ordered.
///
/// The user's list is never destroyed: an unreadable file is moved aside
/// before anything is written, and a file from a newer version is left
/// alone.
public actor RepositoryListStore {
    public nonisolated let fileURL: URL
    private let now: @Sendable () -> Date

    private var isSavingAllowed: Bool?
    private var lastSavedRevision: UInt64?

    /// - Parameters:
    ///   - fileURL: The document (`AppDirectories.repositoryList`).
    ///   - now: The clock that dates a file moved aside.
    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    /// Whether `save` writes: true after a load that allows it (`empty`,
    /// `loaded`, `recovered`).
    public var isSavingEnabled: Bool {
        isSavingAllowed == true
    }

    /// The revision of the last document written, if any.
    public var lastWrittenRevision: UInt64? {
        lastSavedRevision
    }

    /// Reads the document.
    public func load() -> RepositoryListLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error where Self.isFileNotFound(error) {
            isSavingAllowed = true
            return .empty
        } catch {
            logger.error("Could not read the repository list: \(error.localizedDescription, privacy: .public)")
            isSavingAllowed = false
            return .unreadable(error.localizedDescription)
        }

        switch Self.decode(data) {
        case .newerVersion(let version):
            logger.notice("The repository list is from a newer version (schema \(version, privacy: .public)); leaving it alone")
            isSavingAllowed = false
            return .newerVersion(version)
        case .document(let document, damaged: false):
            isSavingAllowed = true
            return .loaded(document)
        case .document(let document, damaged: true):
            return recover(document)
        case .unreadable:
            return recover(RepositoryListDocument())
        }
    }

    /// Writes `document`, unless a later revision has already been written
    /// or this session doesn't save (see `load`).
    ///
    /// - Returns: Whether the document was written.
    /// - Throws: `RepositoryListStoreError.notLoaded` before `load`, or the
    ///   error encoding or writing failed with (the previous file is intact).
    @discardableResult
    public func save(_ document: RepositoryListDocument, revision: UInt64) throws -> Bool {
        guard let isSavingAllowed else {
            throw RepositoryListStoreError.notLoaded
        }
        guard isSavingAllowed else {
            return false
        }
        if let lastSavedRevision, revision <= lastSavedRevision {
            return false
        }

        try write(document)
        lastSavedRevision = revision
        return true
    }

    // MARK: Reading

    private enum Decoded {
        case document(RepositoryListDocument, damaged: Bool)
        case newerVersion(Int)
        case unreadable
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// A value that fails to decode without failing the array it's in.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    /// The document with every part read leniently: a row or ID that can't
    /// be read is dropped instead of failing the document.
    private struct LossyDocument: Decodable {
        let selectedRepositoryID: Lossy<RepositoryID>?
        let recentRepositoryIDs: [Lossy<RepositoryID>]?
        let nextGitHubRepositoryID: Lossy<Int>?
        let repositories: [Lossy<StoredRepository>]?
        let gitHubRepositories: [Lossy<StoredGitHubRepository>]?
    }

    private static func decode(_ data: Data) -> Decoded {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeDate)

        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            return .unreadable
        }
        if probe.version > RepositoryListDocument.currentVersion {
            return .newerVersion(probe.version)
        }
        // Version 1 is the first; older documents would be migrated here,
        // one version at a time.
        guard probe.version == RepositoryListDocument.currentVersion,
              let lossy = try? decoder.decode(LossyDocument.self, from: data)
        else {
            return .unreadable
        }
        return repair(lossy)
    }

    /// The document from what could be read, and whether anything had to be
    /// dropped or unlinked to make it consistent.
    private static func repair(_ lossy: LossyDocument) -> Decoded {
        var damaged = false

        var repositories: [StoredRepository] = []
        var repositoryIDs: Set<RepositoryID> = []
        for row in lossy.repositories ?? [] {
            guard let repository = row.value, repositoryIDs.insert(repository.id).inserted else {
                damaged = true
                continue
            }
            repositories.append(repository)
        }

        var gitHubRepositories: [StoredGitHubRepository] = []
        var gitHubIDs: Set<Int> = []
        for row in lossy.gitHubRepositories ?? [] {
            guard let repository = row.value, gitHubIDs.insert(repository.id).inserted else {
                damaged = true
                continue
            }
            gitHubRepositories.append(repository)
        }
        for index in gitHubRepositories.indices {
            if let parentID = gitHubRepositories[index].parentID, !gitHubIDs.contains(parentID) {
                gitHubRepositories[index].parentID = nil
                damaged = true
            }
        }
        for index in repositories.indices {
            if let id = repositories[index].gitHubRepositoryID, !gitHubIDs.contains(id) {
                repositories[index].gitHubRepositoryID = nil
                damaged = true
            }
        }

        if let selected = lossy.selectedRepositoryID, selected.value == nil {
            damaged = true
        }
        let recents = (lossy.recentRepositoryIDs ?? []).compactMap { row -> RepositoryID? in
            if row.value == nil {
                damaged = true
            }
            return row.value
        }
        if let next = lossy.nextGitHubRepositoryID, next.value == nil {
            damaged = true
        }

        let maximumID = gitHubIDs.max() ?? 0
        var uniqueRecents: [RepositoryID] = []
        for id in recents where repositoryIDs.contains(id) && !uniqueRecents.contains(id) {
            uniqueRecents.append(id)
        }
        let document = RepositoryListDocument(
            version: RepositoryListDocument.currentVersion,
            selectedRepositoryID: lossy.selectedRepositoryID?.value.flatMap { repositoryIDs.contains($0) ? $0 : nil },
            recentRepositoryIDs: uniqueRecents,
            nextGitHubRepositoryID: max(lossy.nextGitHubRepositoryID?.value ?? 1, maximumID + 1),
            repositories: repositories,
            gitHubRepositories: gitHubRepositories
        )
        return .document(document, damaged: damaged)
    }

    /// ISO 8601 dates, with or without fractional seconds.
    @Sendable
    private static func decodeDate(_ decoder: any Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = try? Date(string, strategy: .iso8601) {
            return date
        }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(string)")
    }

    private static func isFileNotFound(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
            return true
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    // MARK: Recovering

    /// Moves the unreadable file aside and saves what could be read in its
    /// place. If the file can't be moved, nothing is saved this session.
    private func recover(_ document: RepositoryListDocument) -> RepositoryListLoadResult {
        let movedAside: URL
        do {
            movedAside = try moveAside()
        } catch {
            logger.error("Could not move the unreadable repository list aside: \(error.localizedDescription, privacy: .public)")
            isSavingAllowed = false
            return .unreadable(error.localizedDescription)
        }
        logger.error("The repository list was unreadable; moved it to \(movedAside.path(percentEncoded: false), privacy: .private)")
        isSavingAllowed = true

        if !document.repositories.isEmpty {
            do {
                try write(document)
            } catch {
                logger.error("Could not save the recovered repository list: \(error.localizedDescription, privacy: .public)")
            }
        }
        return .recovered(document, movedAside: movedAside)
    }

    /// Renames the file to `repositories.corrupt-<date>.json` (ISO 8601
    /// basic format, UTC) beside it, adding `-2`, `-3`, ... if that's taken.
    private func moveAside() throws -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension
        let stamp = now().formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()
            .time(includingFractionalSeconds: false).timeZone(separator: .omitted)
            .dateSeparator(.omitted).timeSeparator(.omitted))

        var attempt = 1
        while true {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let destination = directory.appending(path: "\(stem).corrupt-\(stamp)\(suffix).\(fileExtension)", directoryHint: .notDirectory)
            do {
                try FileManager.default.moveItem(at: fileURL, to: destination)
                return destination
            } catch CocoaError.fileWriteFileExists where attempt < 100 {
                attempt += 1
            }
        }
    }

    // MARK: Writing

    private func write(_ document: RepositoryListDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
