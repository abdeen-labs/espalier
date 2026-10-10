// Ported from desktop/app/test/helpers/temp.ts

import Foundation
import Synchronization

/// Temporary directories for tests.
///
/// Swift Testing runs every test in one process, so each directory lives
/// under a per-process root that is removed when the process exits.
public enum TemporaryDirectory {
    private static let root: URL = {
        let base = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "espalier-tests-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        atexit {
            let path = NSTemporaryDirectory() + "espalier-tests-\(getpid())"
            try? FileManager.default.removeItem(atPath: path)
        }
        // Git reports real paths (/private/var/...), so tests must too.
        // `resolvingSymlinksInPath()` strips `/private`, so use realpath(3).
        guard let resolved = realpath(base.path(percentEncoded: false), nil) else {
            fatalError("Could not resolve the temporary directory \(base.path)")
        }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }()

    /// Creates a new, empty directory and installs the hermetic test git
    /// environment.
    public static func make(prefix: String = "espalier-test-") throws -> URL {
        TestEnvironment.bootstrap()
        // Eight hex digits keep paths short (sockets and long-path tests
        // depend on it), but a process makes thousands of directories, so a
        // name is taken now and then: pick another one.
        while true {
            let url = root.appending(path: prefix + UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
    }
}

/// Creates a new, empty temporary directory and returns its real path.
public func createTempDirectory(prefix: String = "espalier-test-") throws -> String {
    try TemporaryDirectory.make(prefix: prefix).path(percentEncoded: false).trimmingSuffix("/")
}

/// The short directories `createShortTempDirectory()` made, removed when
/// the process exits.
private let shortDirectories = Mutex<[String]>([])

private let shortDirectoriesCleanup: Void = {
    atexit {
        for path in shortDirectories.withLock({ $0 }) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}()

/// Creates a new, empty directory with a short path (in `/tmp`) and returns
/// its real path: for Unix domain sockets (gpg-agent's, ssh-agent's), whose
/// paths must fit in 104 bytes. `createTempDirectory()`'s paths are about
/// 100 bytes long. Removed when the process exits.
public func createShortTempDirectory() throws -> String {
    TestEnvironment.bootstrap()
    _ = shortDirectoriesCleanup
    var template = Array("/tmp/espalier-XXXXXX".utf8CString)
    let created: String? = template.withUnsafeMutableBufferPointer { buffer in
        mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
    }
    guard let created, let resolved = realpath(created, nil) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { free(resolved) }
    let path = String(cString: resolved)
    shortDirectories.withLock { $0.append(path) }
    return path
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}
