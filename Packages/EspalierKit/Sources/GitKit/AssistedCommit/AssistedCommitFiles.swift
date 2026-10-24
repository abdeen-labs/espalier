// The file system work of an assisted commit: exact-byte paths through
// POSIX calls (`URL(filePath:)` decomposes non-ASCII names), file
// identities, and lock files Espalier owns.

import Darwin
import EspalierSupport
import Foundation
import Synchronization

/// A POSIX error from `errno`.
func assistedPOSIXError(_ code: Int32 = errno) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

/// A file's time with nanoseconds.
struct AssistedTimestamp: Sendable, Hashable {
    let seconds: Int
    let nanoseconds: Int

    init(_ time: Darwin.timespec) {
        seconds = time.tv_sec
        nanoseconds = time.tv_nsec
    }

    var value: Darwin.timespec {
        Darwin.timespec(tv_sec: seconds, tv_nsec: nanoseconds)
    }
}

/// A file's identity and metadata: any change to its contents changes at
/// least its change time.
struct AssistedFileIdentity: Sendable, Hashable {
    let device: Int64
    let inode: UInt64
    let mode: mode_t
    let size: Int64
    let modified: AssistedTimestamp
    let changed: AssistedTimestamp

    init(_ info: stat) {
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        mode = info.st_mode
        size = Int64(info.st_size)
        modified = AssistedTimestamp(info.st_mtimespec)
        changed = AssistedTimestamp(info.st_ctimespec)
    }

    var fileType: mode_t {
        mode & S_IFMT
    }

    var isRegularFile: Bool {
        fileType == S_IFREG
    }

    var isDirectory: Bool {
        fileType == S_IFDIR
    }

    var isSymbolicLink: Bool {
        fileType == S_IFLNK
    }

    /// The same file, not just the same metadata: device and inode.
    func isSameFile(as other: AssistedFileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

/// `lstat` of `path`, or nil when nothing is there (an ancestor that isn't
/// a directory included).
func assistedLstat(_ path: String) throws -> AssistedFileIdentity? {
    var info = stat()
    if lstat(path, &info) == 0 {
        return AssistedFileIdentity(info)
    }
    let error = errno
    if error == ENOENT || error == ENOTDIR {
        return nil
    }
    throw assistedPOSIXError(error)
}

/// The bytes of the regular file at `path`, without following a symbolic
/// link there; nil when there's no file.
func assistedReadFile(_ path: String) throws -> Data? {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
        let error = errno
        if error == ENOENT || error == ENOTDIR {
            return nil
        }
        throw assistedPOSIXError(error)
    }
    defer { close(descriptor) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            data.append(contentsOf: buffer[0..<count])
        } else if count == 0 {
            return data
        } else if errno != EINTR {
            throw assistedPOSIXError()
        }
    }
}

/// The target of the symbolic link at `path`, as its bytes.
func assistedReadLink(_ path: String) throws -> Data {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlink(path, &buffer, buffer.count)
    guard count >= 0 else {
        throw assistedPOSIXError()
    }
    return Data(buffer[0..<count].map { UInt8(bitPattern: $0) })
}

/// Writes `data` to a new file at `path`, readable only by the user.
func assistedWriteNewFile(_ path: String, _ data: Data) throws {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
        throw assistedPOSIXError()
    }
    defer { close(descriptor) }
    try assistedWriteAll(descriptor, data)
}

/// Writes all of `data` to `descriptor`.
func assistedWriteAll(_ descriptor: Int32, _ data: Data) throws {
    var offset = 0
    try data.withUnsafeBytes { bytes in
        while offset < bytes.count {
            let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw assistedPOSIXError()
            }
        }
    }
}

/// Creates the directory at `path` and its parents, user-only.
func assistedMakeDirectories(_ path: String) throws {
    var info = stat()
    if lstat(path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw assistedPOSIXError(ENOTDIR)
        }
        return
    }
    let parent = POSIXPath.dirname(path)
    if parent != path {
        try assistedMakeDirectories(parent)
    }
    if mkdir(path, 0o700) != 0, errno != EEXIST {
        throw assistedPOSIXError()
    }
}

/// A new temporary directory, user-only, and its identity.
func assistedMakeTemporaryDirectory(prefix: String) throws -> (path: String, identity: AssistedFileIdentity) {
    var parent = FileManager.default.temporaryDirectory.path(percentEncoded: false)
    while parent.count > 1, parent.hasSuffix("/") {
        parent.removeLast()
    }
    var template = Array("\(parent)/\(prefix)XXXXXX".utf8CString)
    let created: String? = template.withUnsafeMutableBufferPointer { buffer in
        mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
    }
    guard let created else {
        throw assistedPOSIXError()
    }
    // The real path, so git's paths for it compare equal.
    let path = (try? assistedRealPath(created)) ?? created
    guard let identity = try assistedLstat(path), identity.isDirectory else {
        throw AssistedCommitError(.cleanupFailed, "The temporary directory was replaced as it was made.")
    }
    return (path, identity)
}

/// The real path of `path`: symbolic links resolved.
func assistedRealPath(_ path: String) throws -> String {
    guard let resolved = realpath(path, nil) else {
        throw assistedPOSIXError()
    }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Removes the directory Espalier made at `path`, only while it's still the
/// same directory. A directory that's gone is removed already.
func assistedRemoveOwnedDirectory(_ path: String, identity: AssistedFileIdentity) throws {
    guard let current = try assistedLstat(path) else {
        return
    }
    guard current.isDirectory, current.isSameFile(as: identity) else {
        throw AssistedCommitError(.cleanupFailed, "The temporary directory was replaced, so it wasn't removed.")
    }
    try FileManager.default.removeItem(atPath: path)
}

/// A lock file Espalier created exclusively, as git creates `<file>.lock`:
/// while it exists, git won't write the file. Removed only while it's still
/// the file Espalier created.
final class AssistedLockFile: Sendable {
    private struct State {
        var descriptor: Int32?
        /// Renamed onto its target.
        var isConsumed = false
        var isReleased = false
    }

    let path: String
    let identity: AssistedFileIdentity
    private let state: Mutex<State>

    private init(path: String, descriptor: Int32, identity: AssistedFileIdentity) {
        self.path = path
        self.identity = identity
        state = Mutex(State(descriptor: descriptor))
    }

    /// Creates the lock, failing when it exists.
    static func acquire(_ path: String, mode: mode_t = 0o666) throws -> AssistedLockFile {
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else {
            let error = errno
            if error == EEXIST {
                throw AssistedCommitError(
                    .indexChanged,
                    "Another Git process is using the repository (\(POSIXPath.basename(path)) exists)."
                )
            }
            throw assistedPOSIXError(error)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let error = errno
            // Removed only while it's the file just created.
            var current = stat()
            if lstat(path, &current) == 0 {
                _ = unlink(path)
            }
            close(descriptor)
            throw assistedPOSIXError(error)
        }
        return AssistedLockFile(path: path, descriptor: descriptor, identity: AssistedFileIdentity(info))
    }

    var isConsumed: Bool {
        state.withLock { $0.isConsumed }
    }

    var isReleased: Bool {
        state.withLock { $0.isReleased }
    }

    /// Throws unless the lock is still the file Espalier created.
    func verifyOwned() throws {
        guard let current = try assistedLstat(path), current.isRegularFile, current.isSameFile(as: identity) else {
            throw AssistedCommitError(.indexChanged, "Another Git process removed or replaced \(POSIXPath.basename(path)).")
        }
    }

    /// Writes `data` into the lock and renames it onto `target`, as git
    /// commits a lock file: `target` changes in one step.
    ///
    /// - Parameters:
    ///   - mode: The file's permissions.
    ///   - times: Access and modification times to give it, so a restored
    ///     index keeps its timestamp (git compares entries' stat data with
    ///     it to tell racily clean files).
    ///   - beforeRename: Last checks, right before the rename.
    func commit(
        _ data: Data,
        mode: mode_t,
        times: (access: AssistedTimestamp, modification: AssistedTimestamp)?,
        to target: String,
        beforeRename: () throws -> Void
    ) throws {
        try state.withLock { state in
            guard let descriptor = state.descriptor, !state.isConsumed, !state.isReleased else {
                throw AssistedCommitError(.indexChanged, "\(POSIXPath.basename(path)) is no longer held.")
            }
            guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw assistedPOSIXError()
            }
            try assistedWriteAll(descriptor, data)
            guard fchmod(descriptor, mode) == 0 else {
                throw assistedPOSIXError()
            }
            if let times {
                var values = [times.access.value, times.modification.value]
                guard futimens(descriptor, &values) == 0 else {
                    throw assistedPOSIXError()
                }
            }
            guard fsync(descriptor) == 0 else {
                throw assistedPOSIXError()
            }
            try verifyOwned()
            try beforeRename()
            close(descriptor)
            state.descriptor = nil
            guard rename(path, target) == 0 else {
                throw assistedPOSIXError()
            }
            state.isConsumed = true
        }
    }

    /// Removes the lock unless it was renamed onto its target, and closes
    /// it. Safe to call again; a failure leaves it to retry.
    func release() throws {
        try state.withLock { state in
            if state.isReleased {
                return
            }
            if !state.isConsumed {
                if let current = try assistedLstat(path) {
                    guard current.isSameFile(as: identity) else {
                        throw AssistedCommitError(
                            .cleanupFailed,
                            "\(POSIXPath.basename(path)) was replaced by another process, so it wasn't removed."
                        )
                    }
                    guard unlink(path) == 0 || errno == ENOENT else {
                        throw assistedPOSIXError()
                    }
                }
            }
            if let descriptor = state.descriptor {
                close(descriptor)
                state.descriptor = nil
            }
            state.isReleased = true
        }
    }
}
