// Helpers for tests that check text reaches a process byte for byte.

import Darwin
import Foundation

/// "café" spelled with a precomposed "é" (NFC) and with "e" and a combining
/// acute accent (NFD). Foundation's `Process` and `URL(filePath:)` turn the
/// first into the second.
public enum Cafe {
    public static let precomposed = "caf\u{E9}"
    public static let decomposed = "cafe\u{301}"
}

/// Nested directories whose path fits in `PATH_MAX` (1,024 bytes) only while
/// it stays precomposed. A process launched in it, or from it, with the path
/// decomposed fails with `ENAMETOOLONG`, which makes the bytes a child
/// receives observable even on APFS, which finds a file by either spelling.
///
/// Created and removed with system calls, because `FileManager` decomposes
/// paths too.
public struct LongPrecomposedPath: Sendable {
    /// The deepest directory.
    public let path: String
    private let directories: [String]

    /// Creates the directories in a new temporary directory.
    public init() throws {
        // 90 "é" are 180 bytes precomposed and 270 decomposed.
        let component = String(repeating: "\u{E9}", count: 90)
        var path = try createTempDirectory()
        var directories: [String] = []
        for _ in 0..<4 {
            path += "/" + component
            guard mkdir(path, 0o700) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            directories.append(path)
        }
        self.path = path
        self.directories = directories
    }

    /// The length of the path in bytes, as given and decomposed.
    public var byteCounts: (precomposed: Int, decomposed: Int) {
        (path.utf8.count, path.decomposedStringWithCanonicalMapping.utf8.count)
    }

    /// Creates a symbolic link named `name` to `destination` in the deepest
    /// directory and returns its path. (The kernel kills a `#!` script whose
    /// own path is this long, so link to a binary instead.)
    public func link(named name: String, to destination: String) throws -> String {
        let linkPath = path + "/" + name
        guard symlink(destination, linkPath) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return linkPath
    }

    /// Removes everything the test put in the deepest directory, then the
    /// directories.
    public func remove() {
        removeContents(of: path)
        for directory in directories.reversed() {
            rmdir(directory)
        }
    }

    private func removeContents(of directory: String) {
        guard let stream = opendir(directory) else {
            return
        }
        var entries: [(name: String, isDirectory: Bool)] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." {
                entries.append((name, Int32(entry.pointee.d_type) == DT_DIR))
            }
        }
        closedir(stream)

        for entry in entries {
            let child = directory + "/" + entry.name
            if entry.isDirectory {
                removeContents(of: child)
                rmdir(child)
            } else {
                unlink(child)
            }
        }
    }
}
