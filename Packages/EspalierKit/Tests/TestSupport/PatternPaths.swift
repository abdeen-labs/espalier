// File names that git reads as patterns or as pathspec magic when they're
// passed as pathspecs, for the tests that check every path Espalier passes
// git is read literally (as a pattern, `git rm -- 'a*.txt'` also deletes
// ab.txt).

import Darwin
import EspalierSupport
import Foundation
import Testing

/// A file whose name, read as a pathspec, also names another file: the
/// decoy.
public struct PatternPath: Sendable, CustomTestStringConvertible {
    /// The file's name.
    public let name: String
    /// A file the name, read as a pathspec, names too.
    public let decoy: String

    public init(_ name: String, decoy: String) {
        self.name = name
        self.decoy = decoy
    }

    public var testDescription: String {
        "\(name) next to \(decoy)"
    }

    /// A glob star, a question mark, a bracket expression, long and short
    /// magic (`:!` excludes the rest, so it names every other file), and a
    /// colon that isn't leading, which was never special.
    public static let all: [PatternPath] = [
        PatternPath("a*.txt", decoy: "ab.txt"),
        PatternPath("a?.txt", decoy: "ac.txt"),
        PatternPath("[ab].txt", decoy: "a.txt"),
        PatternPath(":(top)c.txt", decoy: "c.txt"),
        PatternPath(":d.txt", decoy: "d.txt"),
        PatternPath(":!e.txt", decoy: "other.txt"),
        PatternPath("f:g.txt", decoy: "g.txt"),
    ]

    /// The cases whose names were read as something else: a glob, and
    /// both kinds of magic.
    public static let representative: [PatternPath] = [
        PatternPath("a*.txt", decoy: "ab.txt"),
        PatternPath(":d.txt", decoy: "d.txt"),
        PatternPath(":!e.txt", decoy: "other.txt"),
    ]
}

/// Writes `contents` to the file at `path` (relative to `directory`) with
/// `open(2)`, so the name is exactly the one given.
public func writeFileExactly(_ path: String, _ contents: String, in directory: String) throws {
    let fd = open(POSIXPath.join(directory, path), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }
    let bytes = Array(contents.utf8)
    let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    guard written == bytes.count else {
        throw POSIXError(.EIO)
    }
}

/// The contents of the file at `path` (relative to `directory`), or nil
/// when there's none.
public func readFileExactly(_ path: String, in directory: String) -> String? {
    let fd = open(POSIXPath.join(directory, path), O_RDONLY)
    guard fd >= 0 else {
        return nil
    }
    defer { close(fd) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else {
            break
        }
        bytes += buffer[..<count]
    }
    return String(decoding: bytes, as: UTF8.self)
}
