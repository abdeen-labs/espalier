import EspalierSupport
import Foundation
import os
import Synchronization

private let logger = Log.logger(category: "trampoline")

/// The connection closed before the helper finished sending standard input.
struct TrampolineConnectionClosedError: Error, CustomStringConvertible {
    var description: String { "the connection to espalier-askpass closed" }
}

/// One espalier-askpass process's connection to the trampoline server: a
/// Unix domain socket, read and written without blocking from dispatch
/// sources on the connection's own user-initiated queue, so that no thread
/// waits on it and heavy load can't starve it. (DispatchIO reads on
/// libdispatch's shared queues, where a busy machine can leave a helper's
/// request unread for over ten seconds; the server then closes the
/// connection unanswered, and git loses the credential it asked the helper
/// to store or erase. `ChildProcess` reads its pipes the same way as here.)
///
/// The helper's frames are parsed as they arrive. The request is available
/// from `receivedRequest(timeout:)`, standard input from `standardInput`.
/// Replies go out with `writeStandardOutput(_:)`, `writeStandardError(_:)`,
/// and finally `exit(_:)`.
final class TrampolineConnection: Sendable {
    /// Identifies the connection within its server.
    let id: UInt64

    /// The process that started the helper, its parent, or nil when it
    /// can't be found: for an askpass request, the ssh or ssh-keygen asking.
    let parentProcessID: pid_t?

    /// The helper's standard input, when its request forwards it. Finishes at
    /// the helper's end of input, and throws `TrampolineConnectionClosedError`
    /// if the connection closes first. Finishes immediately when the request
    /// doesn't forward standard input. Has a single consumer.
    let standardInput: AsyncThrowingStream<Data, any Error>

    private let standardInputContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let descriptor: Int32
    /// Reads, writes, and closes the socket, one event at a time.
    private let queue: DispatchQueue
    private let state: Mutex<State>

    private struct State {
        var parser: TrampolineCommandParser
        var request: TrampolineWire.Request?
        var requestWaiters: [CheckedContinuation<TrampolineWire.Request?, Never>] = []
        var isClosed = false
        var closeHandlers: [@Sendable () -> Void] = []
    }

    /// Frames waiting for room in the socket, in order.
    private struct PendingWrite {
        var bytes: [UInt8]
        var offset = 0
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// The most read in one go, so a long stream of standard input leaves room
    /// for the connection's writes.
    private static let maximumReadPerEvent = 1 << 20

    // Only used on `queue`.
    nonisolated(unsafe) private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16)
    nonisolated(unsafe) private var readSource: (any DispatchSourceRead)?
    nonisolated(unsafe) private var writeSource: (any DispatchSourceWrite)?
    nonisolated(unsafe) private var pendingWrites: [PendingWrite] = []
    /// Sources not yet through their cancel handlers: the socket closes when
    /// none are left.
    nonisolated(unsafe) private var liveSources = 0
    nonisolated(unsafe) private var isShutDown = false

    /// Takes ownership of `fileDescriptor`, which is closed with the
    /// connection.
    init(id: UInt64, fileDescriptor: Int32, maximumStandardInputLength: Int) {
        self.id = id
        descriptor = fileDescriptor
        parentProcessID = Self.parentProcessID(ofPeerOf: fileDescriptor)
        queue = DispatchQueue(label: "dev.abdeen.espalier.trampoline.connection", qos: .userInitiated)
        _ = fcntl(fileDescriptor, F_SETFL, fcntl(fileDescriptor, F_GETFL) | O_NONBLOCK)
        state = Mutex(State(parser: TrampolineCommandParser(maximumStandardInputLength: maximumStandardInputLength)))
        (standardInput, standardInputContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    /// The parent of the process that connected to the socket
    /// `descriptor`. The helper waits for its answer, so it's still running
    /// and its parent is the process that started it.
    private static func parentProcessID(ofPeerOf descriptor: Int32) -> pid_t? {
        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0, peer > 0 else {
            return nil
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(peer, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return pid_t(info.pbi_ppid)
    }

    deinit {
        // Sources keep the connection alive until they're cancelled, so one
        // that never started reading still owns its socket here.
        if !isShutDown, liveSources == 0 {
            Darwin.close(descriptor)
        }
        buffer.deallocate()
    }

    /// Starts reading the helper's frames.
    func start() {
        queue.async { [self] in
            guard !isShutDown else {
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [self] in
                readAvailable()
            }
            source.setCancelHandler { [self] in
                sourceDidCancel()
            }
            readSource = source
            liveSources += 1
            source.activate()
        }
    }

    /// The helper's request, or `nil` if the connection closes or `timeout`
    /// passes first. In both cases the connection is closed.
    func receivedRequest(timeout: Duration) async -> TrampolineWire.Request? {
        // On the connection's queue, like its reads: a `Task.sleep` waits
        // for a free thread of the shared pool, and under heavy load the
        // close comes seconds late.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let (seconds, attoseconds) = timeout.components
        timer.schedule(deadline: .now() + .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if state.withLock({ $0.request == nil }) {
                logger.error("Closing a trampoline connection that sent no request")
                close()
            }
        }
        timer.activate()
        defer { timer.cancel() }

        return await withCheckedContinuation { continuation in
            let ready: TrampolineWire.Request?? = state.withLock { state in
                if let request = state.request {
                    return .some(request)
                }
                if state.isClosed {
                    return .some(nil)
                }
                state.requestWaiters.append(continuation)
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }

    /// All of the helper's standard input, failing if it exceeds `limit`.
    func readStandardInput(limit: Int = 1 << 20) async throws -> Data {
        var data = Data()
        for try await chunk in standardInput {
            data.append(chunk)
            guard data.count <= limit else {
                throw TrampolineConnectionClosedError()
            }
        }
        return data
    }

    /// Writes to the helper's standard output.
    @discardableResult
    func writeStandardOutput(_ data: Data) async -> Bool {
        await send(.standardOutput, data)
    }

    /// Writes to the helper's standard error.
    @discardableResult
    func writeStandardError(_ data: Data) async -> Bool {
        await send(.standardError, data)
    }

    /// Makes the helper exit with `status`, then closes the connection.
    func exit(_ status: Int32) async {
        await send(.exit, TrampolineWire.encodeExitCode(status))
        close()
    }

    /// Closes the connection. The helper sees the end of the stream and
    /// fails, unless it already received its exit status. Writes not yet
    /// sent fail. Idempotent.
    func close() {
        let pending = state.withLock { state -> ([CheckedContinuation<TrampolineWire.Request?, Never>], [@Sendable () -> Void])? in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            defer {
                state.requestWaiters = []
                state.closeHandlers = []
            }
            return (state.requestWaiters, state.closeHandlers)
        }
        guard let (waiters, handlers) = pending else { return }

        // A no-op when the helper already sent the end of its input.
        standardInputContinuation.finish(throwing: TrampolineConnectionClosedError())
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        queue.async { [self] in
            shutDown()
        }
        for handler in handlers {
            handler()
        }
    }

    /// Whether the connection has closed.
    var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    /// Calls `handler` once when the connection closes, or right away if it
    /// already has.
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let isClosed = state.withLock { state in
            if !state.isClosed {
                state.closeHandlers.append(handler)
            }
            return state.isClosed
        }
        if isClosed {
            handler()
        }
    }

    // MARK: - Reading

    /// Reads and parses what the socket holds; closes the connection at end
    /// of file (the helper exited) or on an error. On `queue`.
    private func readAvailable() {
        var total = 0
        while total < Self.maximumReadPerEvent, !isClosed {
            let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            if count > 0 {
                total += count
                received(Array(buffer[..<count]))
            } else if count == 0 {
                close()
                return
            } else {
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    return
                default:
                    close()
                    return
                }
            }
        }
    }

    private func received(_ bytes: [UInt8]) {
        let outcome = state.withLock { state -> Result<([TrampolineCommandParser.Event], [CheckedContinuation<TrampolineWire.Request?, Never>]), TrampolineCommandParser.ParseError>? in
            guard !state.isClosed else { return nil }
            do throws(TrampolineCommandParser.ParseError) {
                let events = try state.parser.process(bytes)
                var waiters: [CheckedContinuation<TrampolineWire.Request?, Never>] = []
                for case .request(let request) in events {
                    state.request = request
                    waiters = state.requestWaiters
                    state.requestWaiters = []
                }
                return .success((events, waiters))
            } catch {
                return .failure(error)
            }
        }

        switch outcome {
        case nil:
            return
        case .failure(let error):
            logger.error("Closing a trampoline connection: \(error.description, privacy: .public)")
            close()
        case .success(let (events, waiters)):
            for event in events {
                switch event {
                case .request(let request):
                    if !request.forwardsStandardInput {
                        standardInputContinuation.finish()
                    }
                    for waiter in waiters {
                        waiter.resume(returning: request)
                    }
                case .standardInput(let chunk):
                    standardInputContinuation.yield(Data(chunk))
                case .standardInputEnd:
                    standardInputContinuation.finish()
                }
            }
        }
    }

    // MARK: - Writing

    /// Sends `payload` as frames of at most 64 KiB, in order with earlier
    /// sends. Returns once the socket has taken all of it, or false when the
    /// connection is closed or the write fails.
    @discardableResult
    private func send(_ type: TrampolineWire.FrameType, _ payload: some Collection<UInt8>) async -> Bool {
        let chunkLength = 64 * 1024
        var bytes: [UInt8] = []
        var start = payload.startIndex
        repeat {
            let end = payload.index(start, offsetBy: chunkLength, limitedBy: payload.endIndex) ?? payload.endIndex
            bytes.append(contentsOf: TrampolineWire.encode(type, payload[start..<end]))
            start = end
        } while start != payload.endIndex

        guard !isClosed else { return false }
        let frames = bytes
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !isShutDown else {
                    continuation.resume(returning: false)
                    return
                }
                pendingWrites.append(PendingWrite(bytes: frames, continuation: continuation))
                // With earlier frames still waiting for room, the write
                // source sends this one after them.
                if pendingWrites.count == 1 {
                    writePending()
                }
            }
        }
    }

    /// Writes pending frames in order until the socket is full, then waits
    /// for room. On `queue`.
    private func writePending() {
        while !pendingWrites.isEmpty {
            let write = pendingWrites[0]
            let written = write.bytes.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress! + write.offset, bytes.count - write.offset)
            }
            if written > 0 {
                pendingWrites[0].offset += written
                if pendingWrites[0].offset == write.bytes.count {
                    pendingWrites.removeFirst().continuation.resume(returning: true)
                }
            } else if written < 0, errno == EINTR {
                continue
            } else if written == 0 || errno == EAGAIN {
                waitForRoom()
                return
            } else {
                // The helper is gone (EPIPE) or the socket failed: the
                // pending writes fail as the connection shuts down.
                close()
                return
            }
        }
        if let writeSource {
            writeSource.cancel()
            self.writeSource = nil
        }
    }

    /// Watches for room in the socket, then writes. On `queue`.
    private func waitForRoom() {
        guard writeSource == nil else {
            return
        }
        let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [self] in
            writePending()
        }
        source.setCancelHandler { [self] in
            sourceDidCancel()
        }
        writeSource = source
        liveSources += 1
        source.activate()
    }

    // MARK: - Shutting down

    /// Stops reading and writing: writes not yet sent fail, and the socket
    /// closes once every source has stopped. On `queue`.
    private func shutDown() {
        guard !isShutDown else {
            return
        }
        isShutDown = true
        let unsent = pendingWrites
        pendingWrites = []
        for write in unsent {
            write.continuation.resume(returning: false)
        }
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        if liveSources == 0 {
            Darwin.close(descriptor)
        }
    }

    /// A source finished cancelling; the last one after shutting down closes
    /// the socket. On `queue`.
    private func sourceDidCancel() {
        liveSources -= 1
        if isShutDown, liveSources == 0 {
            Darwin.close(descriptor)
        }
    }
}
