// Ported from desktop/app/src/lib/trampoline/trampoline-server.ts

import EspalierSupport
import Foundation
import os

private let logger = Log.logger(category: "trampoline")

/// The trampoline server could not start.
public struct TrampolineServerError: Error, CustomStringConvertible, LocalizedError {
    public let message: String

    public var description: String { message }
    public var errorDescription: String? { message }

    static func errno(_ operation: String) -> TrampolineServerError {
        TrampolineServerError(message: "Trampoline server: \(operation) failed: \(String(cString: strerror(Foundation.errno)))")
    }
}

/// This actor represents the "trampoline server". The trampoline is something
/// we'll hand to git in order to communicate with Espalier without noticing:
/// espalier-askpass, which git runs as `SSH_ASKPASS`, as a credential helper,
/// and in place of intercepted hooks.
///
/// The server listens on a Unix domain socket in a directory of its own,
/// created when the server starts: the directory has mode 0700 and the
/// socket 0600, so only the user can connect, and the server also rejects
/// connections whose peer is another user (`getpeereid`). Every request
/// must present a token handed to a git invocation that is still running,
/// and the token selects the handler, so each request maps back to its
/// invocation.
///
/// This server is designed so that it will start lazily when the app runs
/// git. At that point, the app will try to retrieve the server's socket path,
/// which will run the server first if needed. If the server fails, it will
/// stay closed until the next time the app needs it.
///
/// The app creates one server per launch and calls `stop()` when it quits,
/// which removes the directory.
public actor TrampolineServer {
    private let temporaryDirectory: String?
    let requestTimeout: Duration
    let maximumStandardInputLength: Int

    private var listener: TrampolineListener?
    private var handlers: [String: any TrampolineCommandHandler] = [:]
    private var connections: [UInt64: TrackedConnection] = [:]
    private var nextConnectionID: UInt64 = 0

    private struct TrackedConnection {
        let connection: TrampolineConnection
        var token: String?
    }

    /// - Parameter temporaryDirectory: Where to create the server's private
    ///   directory. Defaults to the user's temporary directory.
    public init(temporaryDirectory: String? = nil) {
        self.init(temporaryDirectory: temporaryDirectory, requestTimeout: .seconds(10))
    }

    /// - Parameters:
    ///   - requestTimeout: How long a new connection may take to send its
    ///     request before it is closed.
    ///   - maximumStandardInputLength: The most standard input one request
    ///     may forward.
    init(temporaryDirectory: String?, requestTimeout: Duration, maximumStandardInputLength: Int = 64 << 20) {
        self.temporaryDirectory = temporaryDirectory
        self.requestTimeout = requestTimeout
        self.maximumStandardInputLength = maximumStandardInputLength
    }

    /// This function will retrieve the path of the server's socket, starting
    /// the server first if it's not running.
    public func socketPath() throws -> String {
        if let listener {
            return listener.socketPath
        }

        let listener = try TrampolineListener.open(in: temporaryDirectory ?? Self.defaultTemporaryDirectory) { [weak self] descriptor in
            guard let self else {
                Darwin.close(descriptor)
                return
            }
            // Git waits on every connection, so its work goes ahead of the
            // app's background work.
            Task(priority: .userInitiated) {
                await self.accept(descriptor)
            }
        }
        self.listener = listener
        logger.info("Trampoline server listening")
        return listener.socketPath
    }

    /// The private directory holding the socket, while the server runs.
    public var directory: String? {
        listener?.directory
    }

    /// Stops the server: closes every connection, forgets every token, and
    /// removes the socket and its directory. A later `socketPath()` starts it
    /// again in a new directory.
    public func stop() {
        listener?.close()
        listener = nil
        handlers = [:]
        let open = connections.values.map(\.connection)
        connections = [:]
        for connection in open {
            connection.close()
        }
    }

    // MARK: - Tokens

    /// Registers a handler for the commands that present the returned token.
    func register(_ handler: any TrampolineCommandHandler) -> String {
        let token = TrampolineTokens.make()
        handlers[token] = handler
        return token
    }

    /// Revokes a token. Later commands presenting it are rejected, and the
    /// connections of commands in progress are closed, which cancels their
    /// handlers.
    func revoke(_ token: String) {
        handlers[token] = nil
        for tracked in connections.values where tracked.token == token {
            tracked.connection.close()
        }
    }

    /// Checks if a given trampoline token is valid.
    func isValidTrampolineToken(_ token: String) -> Bool {
        handlers[token] != nil
    }

    // MARK: - Connections

    private static var defaultTemporaryDirectory: String {
        var path = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private func accept(_ descriptor: Int32) {
        guard listener != nil else {
            Darwin.close(descriptor)
            return
        }
        nextConnectionID += 1
        let connection = TrampolineConnection(
            id: nextConnectionID,
            fileDescriptor: descriptor,
            maximumStandardInputLength: maximumStandardInputLength
        )
        connections[connection.id] = TrackedConnection(connection: connection, token: nil)
        connection.start()
        Task {
            await self.serve(connection)
        }
    }

    /// Reads the command, finds the handler for its token, and runs it.
    @concurrent
    private nonisolated func serve(_ connection: TrampolineConnection) async {
        guard let request = await connection.receivedRequest(timeout: requestTimeout) else {
            await finished(connection)
            return
        }

        guard request.version == TrampolineWire.version else {
            logger.error("Rejected a trampoline request in protocol version \(request.version)")
            connection.close()
            await finished(connection)
            return
        }

        guard let identifier = TrampolineWire.RequestKind(rawValue: request.kind) else {
            logger.error("Rejected a trampoline request of unknown kind \(request.kind, privacy: .public)")
            connection.close()
            await finished(connection)
            return
        }

        guard let handler = await claim(connection, token: request.token) else {
            logger.error("Tried to use invalid trampoline token")
            connection.close()
            await finished(connection)
            return
        }

        let command = TrampolineCommand(
            identifier: identifier,
            trampolineToken: request.token,
            parameters: request.arguments,
            environmentVariables: request.environment,
            workingDirectory: request.workingDirectory,
            forwardsStandardInput: request.forwardsStandardInput,
            parentProcessID: connection.parentProcessID
        )

        // The handler is cancelled when the connection closes: the helper
        // exited (git was cancelled, or killed it) or the token was revoked.
        let task = Task {
            await handler.handle(command, connection: connection)
        }
        connection.onClose {
            task.cancel()
        }
        await task.value

        connection.close()
        await finished(connection)
    }

    /// The handler for `token`, after associating the connection with it so
    /// that revoking the token closes the connection.
    private func claim(_ connection: TrampolineConnection, token: String) -> (any TrampolineCommandHandler)? {
        guard let handler = handlers[token], connections[connection.id] != nil else {
            return nil
        }
        connections[connection.id]?.token = token
        return handler
    }

    private func finished(_ connection: TrampolineConnection) {
        connections[connection.id] = nil
    }
}

/// A listening Unix domain socket in a private directory.
private final class TrampolineListener: Sendable {
    let directory: String
    let socketPath: String
    private let source: any DispatchSourceRead

    private init(directory: String, socketPath: String, source: any DispatchSourceRead) {
        self.directory = directory
        self.socketPath = socketPath
        self.source = source
    }

    /// Creates the directory (mode 0700) and the socket (mode 0600), and
    /// starts accepting connections, which go to `onAccept`.
    static func open(in temporaryDirectory: String, onAccept: @escaping @Sendable (Int32) -> Void) throws -> TrampolineListener {
        var address = sockaddr_un()
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        let socketName = "trampoline.sock"

        // The socket's path must fit in sockaddr_un. Fall back to /tmp for a
        // temporary directory with a very long path.
        var parent = temporaryDirectory
        if (parent + "/espalier-trampoline.XXXXXX/" + socketName).utf8.count > maximumPathLength {
            parent = "/tmp"
        }

        var template = Array("\(parent)/espalier-trampoline.XXXXXX".utf8CString)
        let created: String? = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
        guard let directory = created else {
            throw TrampolineServerError.errno("Creating the socket directory")
        }
        let socketPath = directory + "/" + socketName

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            let error = TrampolineServerError.errno("socket")
            try? FileManager.default.removeItem(atPath: directory)
            throw error
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        let pathBytes = Array(socketPath.utf8)
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }

        func fail(_ operation: String) -> TrampolineServerError {
            let error = TrampolineServerError.errno(operation)
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(atPath: directory)
            return error
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw fail("bind") }
        // The directory already keeps everyone else out; this is a second
        // lock on the socket itself.
        guard chmod(socketPath, 0o600) == 0 else { throw fail("chmod") }
        guard listen(descriptor, 128) == 0 else { throw fail("listen") }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "dev.abdeen.espalier.trampoline.listener", qos: .userInitiated)
        )
        source.setEventHandler {
            acceptPending(descriptor, onAccept)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        source.activate()

        return TrampolineListener(directory: directory, socketPath: socketPath, source: source)
    }

    /// Stops listening and removes the socket and its directory.
    func close() {
        source.cancel()
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// Accepts every pending connection from the user running the app.
    private static func acceptPending(_ listener: Int32, _ onAccept: @Sendable (Int32) -> Void) {
        while true {
            let descriptor = accept(listener, nil, nil)
            if descriptor < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN, errno != EWOULDBLOCK, errno != ECONNABORTED {
                    logger.error("Trampoline server: accept failed: \(String(cString: strerror(errno)), privacy: .public)")
                }
                return
            }

            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid() else {
                logger.error("Trampoline server: rejected a connection from another user")
                Darwin.close(descriptor)
                continue
            }

            onAccept(descriptor)
        }
    }
}
