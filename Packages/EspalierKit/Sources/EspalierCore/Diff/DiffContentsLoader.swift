// Ported from desktop/app/src/ui/diff/syntax-highlighting/index.ts
//
// The old and new contents of a changed file, which a diff view uses to
// expand context and to highlight syntax, loaded in a `LatestTask` slot so
// a slow file never lands on a newer one.

import EspalierSupport
import Foundation
import GitKit
import Observation
import os

private let logger = Log.logger(category: "diff")

/// The maximum number of bytes we'll process for highlighting.
let maxHighlightContentLength = 1024 * 1024

/// There is no good way to get the actual length of the old/new contents,
/// since we're directly truncating the git output to up to
/// `maxHighlightContentLength` characters. Therefore, when we try to limit
/// diff expansion, we can't know if a file is exactly
/// `maxHighlightContentLength` characters long or longer, so we'll look for
/// exactly that amount of characters minus 1.
let maxDiffExpansionNewContentLength = maxHighlightContentLength - 1

/// How many leading bytes are checked for a NUL byte, as git does to tell
/// binary contents (`buffer_is_binary`).
let binaryDetectionLength = 8000

/// A changed file's contents before and after the change.
public struct DiffFileContents: Sendable, Equatable {
    /// The file's ID (`FileChange.id`).
    public let fileID: String
    /// The lines before the change; empty for a new file, a binary file, or
    /// when they couldn't be read. Line endings (`\n` or `\r\n`) are removed.
    public let oldLines: [String]
    /// The lines after the change; empty for a deleted file, a binary file,
    /// or when they couldn't be read.
    public let newLines: [String]
    /// Whether the diff can be expanded to show more of the file: the new
    /// contents were read and are under 1 MiB. The contents are cut at 1 MiB,
    /// enough to highlight what's visible.
    public let canBeExpanded: Bool
    /// Whether either side is binary (it has a NUL byte in its first 8,000
    /// bytes, as git judges): no lines are given, and nothing expands.
    public let isBinary: Bool

    public init(fileID: String, oldLines: [String], newLines: [String], canBeExpanded: Bool, isBinary: Bool) {
        self.fileID = fileID
        self.oldLines = oldLines
        self.newLines = newLines
        self.canBeExpanded = canBeExpanded
        self.isBinary = isBinary
    }
}

/// Loads a changed file's whole old and new contents for a diff view: to
/// expand the diff's context and to highlight its syntax. A diff view makes
/// one and loads the file it shows; loading another file cancels the load
/// in flight.
@MainActor @Observable
public final class DiffContentsLoader {
    /// The contents of the file last asked for.
    public private(set) var contents: Loadable<DiffFileContents, OperationError> = .idle

    @ObservationIgnored private weak var repository: RepositoryModel?
    @ObservationIgnored private let slot = LatestTask<Key>()

    private struct Key: Hashable, Sendable {
        let fileID: String
        /// The commits, or the working directory.
        let source: String
        let generation: UInt64
    }

    @ObservationIgnored private var generation: UInt64 = 0

    /// A loader for files of `repository`.
    public init(repository: RepositoryModel) {
        self.repository = repository
    }

    /// Loads a file changed in a commit (or a range, or a pull request): its
    /// contents at the parent and at the commit.
    public func load(_ file: CommittedFileChange) {
        let old: ContentsSource? = isAdded(file) ? nil : .blob(commitish: file.parentCommitish, path: getOldPathOrDefault(file))
        let new: ContentsSource? = file.status.kind == .deleted ? nil : .blob(commitish: file.commitish, path: file.path)
        load(fileID: file.id, source: "\(file.parentCommitish)..\(file.commitish)", old: old, new: new)
    }

    /// Loads a file changed in the working directory: its contents at HEAD
    /// and on disk.
    ///
    /// The old contents come from HEAD, not the index: the working
    /// directory's diff of a new file is made with `--no-index`, so what's
    /// committed is the right base.
    public func load(_ file: WorkingDirectoryFileChange) {
        guard let repository else {
            return
        }
        let old: ContentsSource? = isAdded(file) ? nil : .blob(commitish: "HEAD", path: getOldPathOrDefault(file))
        let new: ContentsSource? = file.status.kind == .deleted
            ? nil
            : .file(POSIXPath.join(repository.gitRepository.path, file.path))
        load(fileID: file.id, source: "working directory", old: old, new: new)
    }

    /// Forgets the contents and stops the load in flight.
    public func clear() {
        slot.cancel()
        if contents != .idle {
            contents = .idle
        }
    }

    /// Waits for the load in flight.
    public func idle() async {
        await slot.idle()
    }

    private func load(fileID: String, source: String, old: ContentsSource?, new: ContentsSource?) {
        guard let repository else {
            return
        }
        let gitRepository = repository.gitRepository
        let environment = repository.environment
        generation &+= 1
        contents = contents.reloading
        slot.run(
            Key(fileID: fileID, source: source, generation: generation),
            operation: {
                await environment.withRuntimes {
                    await loadFileContents(gitRepository, fileID: fileID, old: old, new: new)
                }
            },
            apply: { [weak self] result in
                guard let self, case .success(let loaded) = result else { return }
                self.contents = .loaded(loaded)
            }
        )
    }
}

/// Whether the file has no old contents (`new` or `untracked`).
private func isAdded(_ file: some FileChange) -> Bool {
    file.status.kind == .new || file.status.kind == .untracked
}

/// Where one side of a file comes from.
enum ContentsSource: Sendable, Equatable {
    /// `<commitish>:<path>` in the repository.
    case blob(commitish: String, path: String)
    /// A file on disk.
    case file(String)
}

/// Loads both sides of a file: each side up to `maxHighlightContentLength`
/// bytes, nil when it doesn't exist or can't be read (logged).
@concurrent
func loadFileContents(_ repository: Repository, fileID: String, old: ContentsSource?, new: ContentsSource?) async -> DiffFileContents {
    async let oldData = readContents(repository, old, side: "old")
    async let newData = readContents(repository, new, side: "new")
    let (oldContents, newContents) = await (oldData, newData)

    let isBinary = [oldContents, newContents].contains { $0.map(isBinaryData) ?? false }
    if isBinary {
        return DiffFileContents(fileID: fileID, oldLines: [], newLines: [], canBeExpanded: false, isBinary: true)
    }
    return DiffFileContents(
        fileID: fileID,
        oldLines: oldContents.map(splitLines) ?? [],
        newLines: newContents.map(splitLines) ?? [],
        canBeExpanded: newContents.map { $0.count <= maxDiffExpansionNewContentLength } ?? false,
        isBinary: false
    )
}

/// Reads one side, at most `maxHighlightContentLength` bytes.
@concurrent
private func readContents(_ repository: Repository, _ source: ContentsSource?, side: String) async -> Data? {
    guard let source else {
        return nil
    }
    do {
        switch source {
        case .blob(let commitish, let path):
            return try await getPartialBlobContents(repository, commitish, path, maxHighlightContentLength)
                .map { $0.prefix(maxHighlightContentLength) }
        case .file(let path):
            return try readFilePrefix(path, maxHighlightContentLength)
        }
    } catch {
        logger.error("Could not load \(side, privacy: .public) contents for syntax highlighting: \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

/// The first `length` bytes of the file at `path`. The path stays a
/// string, so a non-ASCII name keeps its exact bytes.
private func readFilePrefix(_ path: String, _ length: Int) throws -> Data {
    guard let handle = FileHandle(forReadingAtPath: path) else {
        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
    }
    defer { try? handle.close() }
    return try handle.read(upToCount: length) ?? Data()
}

/// Whether `data` looks binary: a NUL byte in its first 8,000 bytes.
private func isBinaryData(_ data: Data) -> Bool {
    data.prefix(binaryDetectionLength).contains(0)
}

/// Decodes UTF-8 (invalid sequences become U+FFFD) and splits on `\n` and
/// `\r\n`, keeping a trailing empty line. A newline byte is never part of
/// a longer UTF-8 sequence, so splitting the bytes first decodes the same.
func splitLines(_ data: Data) -> [String] {
    data.withUnsafeBytes { buffer -> [String] in
        let bytes = buffer.bindMemory(to: UInt8.self)
        var lines: [String] = []
        var start = 0
        for index in 0..<bytes.count where bytes[index] == UInt8(ascii: "\n") {
            var end = index
            if end > start, bytes[end - 1] == UInt8(ascii: "\r") {
                end -= 1
            }
            lines.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self))
            start = index + 1
        }
        lines.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<bytes.count]), as: UTF8.self))
        return lines
    }
}
