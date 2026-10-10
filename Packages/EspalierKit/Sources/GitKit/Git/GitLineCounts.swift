// The lines each changed file adds and removes, which Changes shows on its
// rows ("+10 −2").
//
// Read-only: git runs with `--no-optional-locks`, so it never refreshes the
// index behind an operation's back, and untracked files are read, never
// opened for writing.

import Darwin
import EspalierSupport
import Foundation

/// The most bytes an untracked file may have for its lines to be counted:
/// `MaxReasonableDiffSize`, past which its diff is too large to show anyway.
public let untrackedLineCountSizeLimit = MaxReasonableDiffSize

/// How many leading bytes decide that a file is binary: git's
/// `buffer_is_binary` looks for a NUL in the first 8,000.
let binaryDetectionLength = 8_000

/// Each changed file's lines added and removed against `commitish`, its
/// staged and unstaged changes together, by the file's ID.
///
/// - Tracked files: `git diff --numstat` of the working tree against
///   `commitish` (the empty tree when HEAD is unborn), without rename
///   detection, so every path counts on its own. A rename the status found
///   counts as git's rename of the old path to the new one (`-M`, only
///   among the renames), so a file moved without changes adds and removes
///   nothing; when git doesn't pair them (the content changed too much),
///   the new path's lines count as added and the old path's as removed.
/// - Untracked files: their lines, counted as `git diff --no-index`
///   would (a last line without a newline counts; a symbolic link is one
///   line), up to `untrackedLineCountSizeLimit` bytes.
///
/// Binary files, submodules, conflicted files, untracked files past the
/// size limit, and anything that isn't a regular file or a symbolic link
/// have no entry, nor do files git reports no change for.
///
/// - Parameter commitish: The commit to count against, HEAD's as the status
///   saw it; nil when HEAD is unborn.
public func getWorkingDirectoryLineCounts(
    _ repository: Repository,
    _ files: [WorkingDirectoryFileChange],
    against commitish: String?
) async throws -> [ExactString: FileLineCount] {
    var tracked: [WorkingDirectoryFileChange] = []
    var untracked: [WorkingDirectoryFileChange] = []
    for file in files where file.status.submoduleStatus == nil {
        switch file.status {
        case .conflicted:
            continue
        case .untracked:
            untracked.append(file)
        default:
            tracked.append(file)
        }
    }

    var counts: [ExactString: FileLineCount] = [:]
    if !tracked.isEmpty {
        let base: String
        if let commitish {
            base = commitish
        } else {
            base = try await getNullTreeSHA(repository)
        }
        try Task.checkCancellation()

        var paths: [String] = []
        var renames: [WorkingDirectoryFileChange] = []
        for file in tracked {
            paths.append(file.path)
            if case .renamed(let oldPath, _, _) = file.status {
                paths.append(oldPath)
                renames.append(file)
            }
        }
        let byPath = numstatByPath(try await diffNumstat(repository, base, paths: paths, detectsRenames: false))

        // The renames as git pairs them, by their new path.
        var pairs: [ExactString: NumstatEntry] = [:]
        if !renames.isEmpty {
            try Task.checkCancellation()
            let renamePaths = renames.flatMap { [$0.status.oldPath ?? $0.path, $0.path] }
            for entry in try await diffNumstat(repository, base, paths: renamePaths, detectsRenames: true) where entry.oldPath != nil {
                pairs[ExactString(entry.path)] = entry
            }
        }

        for file in tracked {
            let count: FileLineCount?
            if case .renamed(let oldPath, _, _) = file.status {
                if let pair = pairs[ExactString(file.path)], let pairedPath = pair.oldPath,
                   ExactString(pairedPath) == ExactString(oldPath) {
                    count = pair.lineCount
                } else {
                    count = combined(byPath[ExactString(file.path)], byPath[ExactString(oldPath)])
                }
            } else {
                count = byPath[ExactString(file.path)]?.lineCount
            }
            if let count {
                counts[ExactString(file.id)] = count
            }
        }
    }

    for file in untracked {
        try Task.checkCancellation()
        if let count = countUntrackedLines(POSIXPath.join(repository.path, file.path)) {
            counts[ExactString(file.id)] = count
        }
    }
    return counts
}

/// One entry of `git diff --numstat -z`: nil counts for a binary file
/// (`-`), and the old path of a rename or copy.
struct NumstatEntry: Equatable, Sendable {
    var added: Int?
    var deleted: Int?
    var path: String
    var oldPath: String?

    /// The counts, or nil for a binary file.
    var lineCount: FileLineCount? {
        guard let added, let deleted else {
            return nil
        }
        return FileLineCount(added: added, deleted: deleted)
    }
}

/// Runs `git diff --numstat -z` of the working tree against `base` for
/// `paths` (as literal pathspecs), with or without rename detection.
private func diffNumstat(_ repository: Repository, _ base: String, paths: [String], detectsRenames: Bool) async throws -> [NumstatEntry] {
    let args = [
        "--no-optional-locks",
        "diff",
        "--numstat",
        "-z",
        "--no-ext-diff",
        "--ignore-submodules=all",
        detectsRenames ? "-M" : "--no-renames",
        base,
        "--",
    ] + literalPathspecs(paths)
    let result = try await git(args, repository.path, "getWorkingDirectoryLineCounts")
    return parseNumstatEntries(result.stdoutData)
}

/// The entries of `git diff --numstat -z` output: `<added>\t<deleted>\t
/// <path>\0`, or for a rename or copy `<added>\t<deleted>\t\0<old path>\0
/// <new path>\0`; `-` counts for a binary file. A field that isn't an entry
/// is skipped.
func parseNumstatEntries(_ output: Data) -> [NumstatEntry] {
    let fields = splitBuffer(output, "\0")
    let tab = UInt8(ascii: "\t")

    /// A count field: digits, or nil for `-` and anything else.
    func count(_ bytes: Data) -> Int? {
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else {
            return nil
        }
        return Int(String(decoding: bytes, as: UTF8.self))
    }

    var entries: [NumstatEntry] = []
    var i = 0
    while i < fields.count {
        let field = fields[i]
        i += 1

        guard let firstTab = field.firstIndex(of: tab),
              let secondTab = field[(firstTab + 1)...].firstIndex(of: tab)
        else {
            continue
        }

        let added = Data(field[field.startIndex..<firstTab])
        let deleted = Data(field[(firstTab + 1)..<secondTab])
        let path = field[(secondTab + 1)...]
        var entry = NumstatEntry(added: count(added), deleted: count(deleted), path: String(decoding: path, as: UTF8.self))

        if path.isEmpty {
            // A rename or copy: the old and new paths are the next fields.
            guard i + 1 < fields.count else {
                break
            }
            entry.oldPath = String(decoding: fields[i], as: UTF8.self)
            entry.path = String(decoding: fields[i + 1], as: UTF8.self)
            i += 2
        }
        // A binary file's counts are both `-`; a count that isn't a number
        // makes the entry binary too, rather than a wrong count.
        if entry.added == nil || entry.deleted == nil {
            entry.added = nil
            entry.deleted = nil
        }
        entries.append(entry)
    }
    return entries
}

/// The entries by path, a path listed twice (a file turned into a
/// symbolic link, which git may report as a deletion and an addition)
/// counting both.
private func numstatByPath(_ entries: [NumstatEntry]) -> [ExactString: NumstatEntry] {
    var byPath: [ExactString: NumstatEntry] = [:]
    for entry in entries {
        let key = ExactString(entry.path)
        guard let existing = byPath[key] else {
            byPath[key] = entry
            continue
        }
        var merged = existing
        if let count = combined(existing, entry) {
            merged.added = count.added
            merged.deleted = count.deleted
        } else {
            merged.added = nil
            merged.deleted = nil
        }
        byPath[key] = merged
    }
    return byPath
}

/// Two entries' counts together: nil when either is binary or neither
/// exists.
private func combined(_ first: NumstatEntry?, _ second: NumstatEntry?) -> FileLineCount? {
    guard first != nil || second != nil else {
        return nil
    }
    var added = 0
    var deleted = 0
    for entry in [first, second].compactMap({ $0 }) {
        guard let count = entry.lineCount, let entryAdded = count.added, let entryDeleted = count.deleted else {
            return nil
        }
        added += entryAdded
        deleted += entryDeleted
    }
    return FileLineCount(added: added, deleted: deleted)
}

/// An untracked file's lines, all added, as `git diff --no-index` counts
/// them: the newlines, plus a last line without one. A symbolic link is one
/// line (its target). Nil for a binary file (a NUL in its first 8,000
/// bytes), a file over `limit` bytes, one that can't be read, and anything
/// that isn't a regular file or a symbolic link (a nested repository's
/// folder, a FIFO, which is never opened).
func countUntrackedLines(_ path: String, limit: Int = untrackedLineCountSizeLimit) -> FileLineCount? {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        return nil
    }
    switch info.st_mode & S_IFMT {
    case S_IFLNK:
        return FileLineCount(added: 1, deleted: 0)
    case S_IFREG:
        break
    default:
        return nil
    }
    guard info.st_size <= off_t(limit) else {
        return nil
    }

    // No following a link put in its place since, and no waiting on a FIFO.
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
        return nil
    }
    defer { close(descriptor) }
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= off_t(limit) else {
        return nil
    }

    var newlines = 0
    var total = 0
    var lastByte: UInt8?
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let bytesRead = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if bytesRead < 0 {
            if errno == EINTR {
                continue
            }
            return nil
        }
        if bytesRead == 0 {
            break
        }
        let chunk = buffer[0..<bytesRead]
        if total < binaryDetectionLength, chunk.prefix(binaryDetectionLength - total).contains(0) {
            return nil
        }
        total += bytesRead
        // The file grew past the limit while it was read.
        if total > limit {
            return nil
        }
        for byte in chunk where byte == UInt8(ascii: "\n") {
            newlines += 1
        }
        lastByte = chunk.last
    }
    let lines = newlines + (lastByte != nil && lastByte != UInt8(ascii: "\n") ? 1 : 0)
    return FileLineCount(added: lines, deleted: 0)
}
