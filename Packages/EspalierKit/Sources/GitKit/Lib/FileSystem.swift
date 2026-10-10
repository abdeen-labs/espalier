// Ported from desktop/app/src/lib/file-system.ts

import EspalierSupport
import Foundation
import os
import Synchronization

private let logger = Log.logger(category: "file-system")

/// Get a path to a temp file using the given name. Note that the file itself
/// will not be created.
public func getTempFilePath(_ name: String) -> String {
    var generator = SystemRandomNumberGenerator()
    let suffix = (0..<8)
        .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
        .joined()
    return POSIXPath.join(temporaryDirectory(), "\(name)-\(suffix)")
}

/// `TMPDIR`, `TMP`, or `TEMP` without a trailing slash, else `/tmp`.
private func temporaryDirectory() -> String {
    let environment = ProcessInfo.processInfo.environment
    var path = ["TMPDIR", "TMP", "TEMP"].lazy.compactMap { environment[$0] }.first { !$0.isEmpty } ?? "/tmp"
    if path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return path
}

/// Tail the file and call the callback on every line.
///
/// Note that this will not stop tailing until the returned `Disposable` is
/// disposed of.
///
/// A partial line waits for the rest of it, and is dropped if the tail is
/// disposed first. Lines already in the file when tailing starts are
/// reported too.
public func tailByLine(_ path: String, _ cb: @escaping @Sendable (String) -> Void) -> Disposable {
    tailByLine(
        path,
        fileSystem: SystemTailerFileSystem(),
        onWarning: { error in
            logger.warning("Unable to tail path: \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        },
        cb
    )
}

/// `tailByLine` with the tailer's file system and the warning log as seams
/// for tests.
func tailByLine(
    _ path: String,
    fileSystem: any TailerFileSystem,
    onWarning: @escaping @Sendable (any Error) -> Void,
    _ cb: @escaping @Sendable (String) -> Void
) -> Disposable {
    let tailer = Tailer(path, fileSystem: fileSystem)

    let onErrorDisposable = tailer.onError { error in
        onWarning(error)
    }

    let lines = Mutex(LineSplitter())
    let disposed = Atomic(false)
    let onDataDisposable = tailer.onDataAvailable { data in
        for line in lines.withLock({ $0.push(data) }) {
            if disposed.load(ordering: .acquiring) {
                return
            }
            cb(line)
        }
    }

    // A new tailer is never already running.
    try? tailer.start()

    // The process may have written to the file before the watcher was
    // registered, which raises no event, so Git LFS progress written that
    // early would wait for the next write.
    tailer.readNow()

    return Disposable {
        disposed.store(true, ordering: .releasing)
        onDataDisposable.dispose()
        onErrorDisposable.dispose()
        tailer.stop()
    }
}

/// Read a specific region from a file.
///
/// - Parameters:
///   - path: Path to the file
///   - start: First index relative to the start of the file to read from
///   - end: Last index (inclusive) relative to the start of the file to read
///     to. A region past the end of the file is cut short.
public func readPartialFile(_ path: String, _ start: Int, _ end: Int) async throws -> Data {
    guard start >= 0, start <= end else {
        throw POSIXError(.EINVAL)
    }
    let handle = try FileHandle(forReadingFrom: URL(filePath: path))
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(start))
    return try handle.read(upToCount: end - start + 1) ?? Data()
}
