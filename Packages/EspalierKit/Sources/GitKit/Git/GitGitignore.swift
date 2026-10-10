// Ported from desktop/app/src/lib/git/gitignore.ts

import EspalierSupport
import Foundation

private let symbolicLinkErrorMessage = "Cannot use a symbolic link as the root .gitignore file"

private func createSymbolicLinkError() -> GitLibError {
    GitLibError(symbolicLinkErrorMessage)
}

/// The error for the current `errno`.
private func currentErrnoError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private func ensureGitIgnoreIsNotSymbolicLink(_ ignorePath: String) throws {
    var stats = stat()
    if lstat(ignorePath, &stats) == 0 {
        if (stats.st_mode & S_IFMT) == S_IFLNK {
            throw createSymbolicLinkError()
        }
    } else if errno != ENOENT {
        throw currentErrnoError()
    }
}

/// An open file descriptor, closed when the value goes away.
private final class OpenFile {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    func readAll() throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw currentErrnoError()
            }
            if count == 0 {
                return data
            }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    func truncateAndWrite(_ data: Data) throws {
        guard ftruncate(descriptor, 0) == 0 else {
            throw currentErrnoError()
        }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw currentErrnoError()
                }
                offset += written
            }
        }
    }
}

private func openExistingGitIgnore(_ ignorePath: String, _ flags: Int32) throws -> OpenFile? {
    let descriptor = open(ignorePath, flags | O_NOFOLLOW)
    if descriptor < 0 {
        let code = errno
        if code == ENOENT {
            try ensureGitIgnoreIsNotSymbolicLink(ignorePath)
            return nil
        }

        if code == ELOOP {
            throw createSymbolicLinkError()
        }

        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    // Closed when this function throws.
    let file = OpenFile(descriptor)

    var fileStats = stat()
    guard fstat(descriptor, &fileStats) == 0 else {
        throw currentErrnoError()
    }
    var pathStats = stat()
    guard lstat(ignorePath, &pathStats) == 0 else {
        throw currentErrnoError()
    }

    if (pathStats.st_mode & S_IFMT) == S_IFLNK
        || fileStats.st_dev != pathStats.st_dev
        || fileStats.st_ino != pathStats.st_ino {
        throw createSymbolicLinkError()
    }

    return file
}

/// Read the contents of the repository .gitignore.
///
/// Returns the contents of the file, or nil if there's no .gitignore
/// file in the repository root.
public func readGitIgnoreAtRoot(_ repository: Repository) async throws -> String? {
    let ignorePath = POSIXPath.join(repository.path, ".gitignore")
    guard let file = try openExistingGitIgnore(ignorePath, O_RDONLY) else {
        return nil
    }

    return String(decoding: try file.readAll(), as: UTF8.self)
}

/// Persist the given content to the repository root .gitignore.
///
/// If the repository root doesn't contain a .gitignore file one
/// will be created, otherwise the current file will be overwritten.
public func saveGitIgnore(_ repository: Repository, _ text: String) async throws {
    let ignorePath = POSIXPath.join(repository.path, ".gitignore")

    if text.isEmpty {
        try ensureGitIgnoreIsNotSymbolicLink(ignorePath)

        // When there is no .gitignore to delete, saving empty contents
        // already has the result the caller asked for, so a missing file is
        // not an error here.
        guard unlink(ignorePath) == 0 || errno == ENOENT else {
            throw currentErrnoError()
        }
        return
    }

    let fileContents = try await formatGitIgnoreContents(text, repository)
    let file: OpenFile
    if let existing = try openExistingGitIgnore(ignorePath, O_WRONLY) {
        file = existing
    } else {
        let descriptor = open(ignorePath, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o666)
        guard descriptor >= 0 else {
            throw currentErrnoError()
        }
        file = OpenFile(descriptor)
    }

    try file.truncateAndWrite(Data(fileContents.utf8))
}

/// Add the given pattern or patterns to the root gitignore file
public func appendIgnoreRule(_ repository: Repository, _ patterns: [String]) async throws {
    try await appendIgnoreRule(repository, patternText: patterns.joined(separator: "\n"))
}

/// Add the given pattern to the root gitignore file
public func appendIgnoreRule(_ repository: Repository, _ pattern: String) async throws {
    try await appendIgnoreRule(repository, patternText: pattern)
}

private func appendIgnoreRule(_ repository: Repository, patternText newPatternText: String) async throws {
    let text = try await readGitIgnoreAtRoot(repository) ?? ""

    let currentContents = try await formatGitIgnoreContents(text, repository)

    let newText = try await formatGitIgnoreContents("\(currentContents)\(newPatternText)", repository)

    try await saveGitIgnore(repository, newText)
}

/// Convenience method to add the given file paths to the repository's gitignore.
///
/// The file paths will be escaped before adding.
///
/// - Throws: `GitLibError` for a path with a line break, which no rule can
///   hold; nothing is added then.
public func appendIgnoreFile(_ repository: Repository, _ filePaths: [String]) async throws {
    try requireNoLineBreaks(filePaths)
    let escapedFilePaths = filePaths.map { escapeGitSpecialCharacters($0) }

    try await appendIgnoreRule(repository, escapedFilePaths)
}

/// Convenience method to add the given file path to the repository's gitignore.
///
/// The file path will be escaped before adding.
///
/// - Throws: `GitLibError` for a path with a line break.
public func appendIgnoreFile(_ repository: Repository, _ filePath: String) async throws {
    try requireNoLineBreaks([filePath])
    let escapedFilePath = escapeGitSpecialCharacters(filePath)
    try await appendIgnoreRule(repository, escapedFilePath)
}

/// Throws when a path has a line break, which ends a gitignore rule.
private func requireNoLineBreaks(_ filePaths: [String]) throws {
    if filePaths.contains(where: { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } }) {
        throw GitLibError("A file whose name has a line break can't be added to .gitignore.")
    }
}

/// Escapes a string from special characters used in a gitignore file
///
/// Also escapes backslashes, which would otherwise escape the character
/// after them (`a\b` would ignore ab, not itself), and trailing spaces,
/// which git drops from a rule.
public func escapeGitSpecialCharacters(_ pattern: String) -> String {
    let specialCharacters: Set<Unicode.Scalar> = ["[", "]", "!", "*", "#", "?", "\\"]

    let scalars = Array(pattern.unicodeScalars)
    var trailingSpaces = scalars.endIndex
    while trailingSpaces > scalars.startIndex, scalars[trailingSpaces - 1] == " " {
        trailingSpaces -= 1
    }

    var result = String.UnicodeScalarView()
    for (index, scalar) in scalars.enumerated() {
        if specialCharacters.contains(scalar) || index >= trailingSpaces {
            result.append("\\")
        }
        result.append(scalar)
    }
    return String(result)
}

/// Replaces every `\r\n`, `\n\r`, `\n`, and `\r` with `\r\n`.
private func normalizeToCRLF(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var result = String.UnicodeScalarView()
    var i = 0
    while i < scalars.count {
        let scalar = scalars[i]
        let next = i + 1 < scalars.count ? scalars[i + 1] : nil
        if (scalar == "\r" && next == "\n") || (scalar == "\n" && next == "\r") {
            result.append(contentsOf: "\r\n".unicodeScalars)
            i += 2
        } else if scalar == "\n" || scalar == "\r" {
            result.append(contentsOf: "\r\n".unicodeScalars)
            i += 1
        } else {
            result.append(scalar)
            i += 1
        }
    }
    return String(result)
}

/// Format the gitignore text based on the current config settings.
///
/// This setting looks at core.autocrlf to decide which line endings to use
/// when updating the .gitignore file.
///
/// If core.safecrlf is also set, adding this file to the index may cause
/// Git to return a non-zero exit code, leaving the working directory in a
/// confusing state for the user. So we should reformat the file in that
/// case.
///
/// - Parameters:
///   - text: The text to format.
///   - repository: The repository associated with the gitignore file.
private func formatGitIgnoreContents(_ text: String, _ repository: Repository) async throws -> String {
    let autocrlf = try await getConfigValue(repository, "core.autocrlf")
    let safecrlf = try await getConfigValue(repository, "core.safecrlf")

    if autocrlf == "true" && safecrlf == "true" {
        // based off https://stackoverflow.com/a/141069/1363815
        let normalizedText = normalizeToCRLF(text)

        // The contents are formatted up to three times per change
        // (appendIgnoreRule formats the current and the new text, then
        // saveGitIgnore formats again), so appending CRLF unconditionally
        // would add blank lines with every change. Only terminate the last
        // line.
        if normalizedText.isEmpty || JSCompat.endsWith(normalizedText, "\r\n") {
            return normalizedText
        }
        return normalizedText + "\r\n"
    }

    if text.isEmpty || JSCompat.endsWith(text, "\n") {
        return text
    }

    guard let autocrlf else {
        // fallback to Git default behaviour
        return "\(text)\n"
    }

    // Lines end in CRLF with core.autocrlf=true; with false or input they
    // end in LF.
    let linesEndInCRLF = autocrlf == "true"
    if linesEndInCRLF {
        return "\(text)\r\n"
    } else {
        return "\(text)\n"
    }
}
