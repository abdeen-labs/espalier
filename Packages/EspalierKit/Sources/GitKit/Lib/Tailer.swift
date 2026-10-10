// Ported from desktop/app/src/lib/tailer.ts
//
// The tailer reads each new region of the file and hands its listeners the
// bytes. The watcher, `stat`, and reads are behind `TailerFileSystem`, so
// tests can drive them.

import Foundation
import Synchronization

/// Something to dispose of.
public final class Disposable: Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>

    public init(_ dispose: @escaping @Sendable () -> Void) {
        action = Mutex(dispose)
    }

    /// Whether `dispose()` has been called.
    public var disposed: Bool {
        action.withLock { $0 == nil }
    }

    /// Disposes of the resource. Only the first call has an effect.
    public func dispose() {
        let action = action.withLock { action in
            defer { action = nil }
            return action
        }
        action?()
    }
}

/// An error from `Tailer.start()`.
public enum TailerError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning

    public var description: String { "Tailer already running" }
}

/// Tail a file and read changes as they happen.
public final class Tailer: Sendable {
    public let path: String

    private let fileSystem: any TailerFileSystem
    private let shared = Mutex(Shared())
    private let dataListeners = Listeners<Data>()
    private let errorListeners = Listeners<any Error>()

    /// One run of the tailer, from `start()` to `stop()`.
    private struct TailState {
        /// Identifies the run.
        let lifetime: UInt64

        /// The file system watcher, once `watch` returned it.
        var watcher: (any TailerWatcher)?

        /// The current read position in the file.
        var position = 0

        /// Whether a stat or read is in progress.
        var reading = false

        /// Whether a change arrived while a stat or read was in progress.
        var readPending = false

        /// The read in progress, which must finish before the next one.
        var read: ActiveRead?
    }

    private struct ActiveRead {
        let id: UInt64
        var operation: (any TailerRead)?
    }

    private struct Shared {
        var current: TailState?
        var nextID: UInt64 = 0

        mutating func makeID() -> UInt64 {
            nextID += 1
            return nextID
        }
    }

    /// Create a new instance for tailing the given file.
    public convenience init(_ path: String) {
        self.init(path, fileSystem: SystemTailerFileSystem())
    }

    init(_ path: String, fileSystem: any TailerFileSystem) {
        self.path = path
        self.fileSystem = fileSystem
    }

    deinit {
        // The watcher's handlers hold the tailer weakly, so a tailer dropped
        // without `stop()` would otherwise leave its watcher running.
        stop()
    }

    /// Register a function to be called with each region of the file that
    /// was appended since the last one.
    public func onDataAvailable(_ fn: @escaping @Sendable (Data) -> Void) -> Disposable {
        dataListeners.add(fn)
    }

    /// Register a function to be called whenever an error is reported by the
    /// filesystem watcher or while reading the file.
    public func onError(_ fn: @escaping @Sendable (any Error) -> Void) -> Disposable {
        errorListeners.add(fn)
    }

    /// Start tailing the file. This can only be called again after calling
    /// `stop`.
    public func start() throws(TailerError) {
        let lifetime = try shared.withLock { shared throws(TailerError) -> UInt64 in
            guard shared.current == nil else {
                throw .alreadyRunning
            }
            let lifetime = shared.makeID()
            shared.current = TailState(lifetime: lifetime)
            return lifetime
        }

        let watcher: any TailerWatcher
        do {
            watcher = try fileSystem.watch(path) { [weak self] event in
                self?.handleWatchEvent(event, lifetime)
            }
        } catch {
            handleError(error, lifetime)
            return
        }

        let isCurrent = shared.withLock { shared in
            guard shared.current?.lifetime == lifetime else {
                return false
            }
            shared.current?.watcher = watcher
            return true
        }
        if !isCurrent {
            // Stopped while the watcher was starting.
            watcher.close()
        }
    }

    /// Stop tailing the file and destroy any active read.
    public func stop() {
        let state = shared.withLock { shared in
            defer { shared.current = nil }
            return shared.current
        }
        if let state {
            state.watcher?.close()
            state.read?.operation?.destroy()
        }
    }

    // MARK: - Private

    private func handleWatchEvent(_ event: TailerWatchEvent, _ lifetime: UInt64) {
        switch event {
        case .change:
            requestRead(lifetime)
        case .rename:
            break
        case .error(let error):
            handleError(error, lifetime)
        }
    }

    /// Stops the run and reports `error`, if `lifetime` is still the current
    /// run.
    private func handleError(_ error: any Error, _ lifetime: UInt64) {
        let state = shared.withLock { shared -> TailState? in
            guard let current = shared.current, current.lifetime == lifetime else {
                return nil
            }
            shared.current = nil
            return current
        }
        guard let state else {
            return
        }
        state.watcher?.close()
        state.read?.operation?.destroy()
        errorListeners.emit(error)
    }

    /// Reads what the file gained since the last read, as a change event
    /// does. A write that lands before `start()` registers the watcher raises
    /// no event, so a caller tailing a file another process may already be
    /// writing calls this once after `start()`.
    func readNow() {
        guard let lifetime = shared.withLock({ $0.current?.lifetime }) else {
            return
        }
        requestRead(lifetime)
    }

    private func requestRead(_ lifetime: UInt64) {
        let isCurrent = shared.withLock { shared in
            guard shared.current?.lifetime == lifetime else {
                return false
            }
            shared.current?.readPending = true
            return true
        }
        if isCurrent {
            readNextChunk(lifetime)
        }
    }

    private func readNextChunk(_ lifetime: UInt64) {
        let shouldStat = shared.withLock { shared in
            guard var current = shared.current, current.lifetime == lifetime, !current.reading else {
                return false
            }
            current.reading = true
            current.readPending = false
            shared.current = current
            return true
        }
        guard shouldStat else {
            return
        }

        fileSystem.stat(path) { [weak self] result in
            self?.statCompleted(result, lifetime)
        }
    }

    private enum AfterStat {
        case ignore
        case fail(any Error)
        case finish
        case read(id: UInt64, start: Int, end: Int)
    }

    private func statCompleted(_ result: Result<Int, any Error>, _ lifetime: UInt64) {
        let next = shared.withLock { shared -> AfterStat in
            guard var current = shared.current, current.lifetime == lifetime else {
                return .ignore
            }
            switch result {
            case .failure(let error):
                return .fail(error)
            case .success(let size):
                if size <= current.position {
                    return .finish
                }
                let id = shared.makeID()
                let start = current.position
                current.position = size
                current.read = ActiveRead(id: id)
                shared.current = current
                return .read(id: id, start: start, end: size - 1)
            }
        }

        switch next {
        case .ignore:
            return
        case .fail(let error):
            handleError(error, lifetime)
        case .finish:
            finishRead(lifetime)
        case .read(let id, let start, let end):
            let operation = fileSystem.read(path, start: start, end: end) { [weak self] result in
                self?.readCompleted(result, id, lifetime)
            }
            let isCurrent = shared.withLock { shared in
                guard shared.current?.lifetime == lifetime, shared.current?.read?.id == id else {
                    return false
                }
                shared.current?.read?.operation = operation
                return true
            }
            if !isCurrent {
                operation.destroy()
            }
        }
    }

    private func readCompleted(_ result: Result<Data, any Error>, _ id: UInt64, _ lifetime: UInt64) {
        guard isCurrentRead(id, lifetime) else {
            return
        }

        switch result {
        case .failure(let error):
            handleError(error, lifetime)
        case .success(let data):
            dataListeners.emit(data)
            // A listener may have stopped or restarted the tailer.
            if isCurrentRead(id, lifetime) {
                finishRead(lifetime)
            }
        }
    }

    private func isCurrentRead(_ id: UInt64, _ lifetime: UInt64) -> Bool {
        shared.withLock { shared in
            shared.current?.lifetime == lifetime && shared.current?.read?.id == id
        }
    }

    private func finishRead(_ lifetime: UInt64) {
        let readPending = shared.withLock { shared -> Bool in
            guard var current = shared.current, current.lifetime == lifetime else {
                return false
            }
            let readPending = current.readPending
            current.read = nil
            current.reading = false
            shared.current = current
            return readPending
        }
        if readPending {
            readNextChunk(lifetime)
        }
    }
}

/// A list of listeners, called in the order they were added.
private final class Listeners<Value: Sendable>: Sendable {
    private struct State {
        var listeners: [(id: UInt64, fn: @Sendable (Value) -> Void)] = []
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    func add(_ fn: @escaping @Sendable (Value) -> Void) -> Disposable {
        let id = state.withLock { state in
            state.nextID += 1
            state.listeners.append((state.nextID, fn))
            return state.nextID
        }
        return Disposable { [weak self] in
            self?.state.withLock { state in
                state.listeners.removeAll { $0.id == id }
            }
        }
    }

    func emit(_ value: Value) {
        let listeners = state.withLock { $0.listeners }
        for listener in listeners {
            listener.fn(value)
        }
    }
}

// MARK: - File system

/// What a tailer's file system watcher reports.
enum TailerWatchEvent: Sendable {
    /// The file grew or its attributes changed.
    case change
    /// Anything else, such as an overwrite, rename, or deletion.
    case rename
    /// The watcher failed.
    case error(any Error)
}

/// A file system watcher.
protocol TailerWatcher: Sendable {
    func close()
}

/// A read in progress.
protocol TailerRead: Sendable {
    /// Abandons the read; its completion won't be called.
    func destroy()
}

/// The file system operations a `Tailer` performs: watching, `stat`, and
/// reading.
protocol TailerFileSystem: Sendable {
    /// Watches the file at `path`, calling `handler` for each event.
    func watch(_ path: String, _ handler: @escaping @Sendable (TailerWatchEvent) -> Void) throws -> any TailerWatcher

    /// Gets the size of the file at `path`.
    func stat(_ path: String, _ completion: @escaping @Sendable (Result<Int, any Error>) -> Void)

    /// Reads the file at `path` from byte `start` to byte `end` (inclusive),
    /// or to its end if it is shorter.
    func read(
        _ path: String,
        start: Int,
        end: Int,
        _ completion: @escaping @Sendable (Result<Data, any Error>) -> Void
    ) -> any TailerRead
}

/// The real file system. A tailer's watcher events, stats, and reads all run
/// on one serial queue, so they happen in order.
struct SystemTailerFileSystem: TailerFileSystem {
    private let queue = DispatchQueue(label: "dev.abdeen.espalier.tailer")

    func watch(_ path: String, _ handler: @escaping @Sendable (TailerWatchEvent) -> Void) throws -> any TailerWatcher {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.attrib, .write, .rename, .delete, .extend, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak source] in
            guard let source else { return }
            // `change` for attribute changes and growth, and `rename` for
            // everything else.
            let events = source.data
            handler(events.contains(.attrib) || events.contains(.extend) ? .change : .rename)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return DispatchSourceWatcher(source: source)
    }

    func stat(_ path: String, _ completion: @escaping @Sendable (Result<Int, any Error>) -> Void) {
        queue.async {
            var info = Darwin.stat()
            // `stat(2)`, which follows symbolic links.
            if fstatat(AT_FDCWD, path, &info, 0) == 0 {
                completion(.success(Int(info.st_size)))
            } else {
                completion(.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
            }
        }
    }

    func read(
        _ path: String,
        start: Int,
        end: Int,
        _ completion: @escaping @Sendable (Result<Data, any Error>) -> Void
    ) -> any TailerRead {
        let read = SystemTailerRead()
        queue.async {
            guard !read.isDestroyed else { return }
            let result = Result<Data, any Error> {
                try readRegion(path, start: start, end: end)
            }
            guard !read.isDestroyed else { return }
            completion(result)
        }
        return read
    }

    private func readRegion(_ path: String, start: Int, end: Int) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var data = Data()
        var offset = start
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset <= end {
            let wanted = min(buffer.count, end - offset + 1)
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, wanted, off_t(offset)) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                break
            }
            data.append(contentsOf: buffer[..<count])
            offset += count
        }
        return data
    }
}

private final class DispatchSourceWatcher: TailerWatcher {
    let source: any DispatchSourceFileSystemObject

    init(source: any DispatchSourceFileSystemObject) {
        self.source = source
    }

    func close() {
        source.cancel()
    }
}

private final class SystemTailerRead: TailerRead {
    private let destroyed = Atomic(false)

    var isDestroyed: Bool { destroyed.load(ordering: .acquiring) }

    func destroy() {
        destroyed.store(true, ordering: .releasing)
    }
}
