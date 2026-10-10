// Ported from desktop/vendor/desktop-trampoline/src/desktop-trampoline.c (the
// askpass and credential helper trampolines) and the client side of desktop's
// process-proxy package (the hook proxy).

import Foundation

/// espalier-askpass, the one program git runs to call back into Espalier.
///
/// It is git's askpass program, credential helper, and hook proxy, and picks
/// its mode from how it was invoked:
///
/// - Through a symbolic link named after a git hook: the hook proxy.
/// - As `git-credential-<name> <action>`, or with `--credential-helper
///   <action>` (from `credential.helper=!'<helper>' --credential-helper`): a
///   git credential helper, with the credential on standard input.
/// - Otherwise, as `SSH_ASKPASS`: one argument, ssh's prompt.
///
/// When Espalier can't be reached, as askpass and as a credential helper it
/// prints nothing (and a message on standard error), and as a hook proxy it
/// exits with status 1 and a message on standard error, so git stops the
/// operation instead of skipping the hook.
enum Helper {
    enum Mode: Equatable {
        /// `SSH_ASKPASS`. The arguments are ssh's (one: the prompt).
        case askpass(arguments: [String])
        /// A git credential helper. The arguments are git's (one: the
        /// action).
        case credential(arguments: [String])
        /// A hook proxy for the hook with this name.
        case hook(name: String)
    }

    /// Picks the mode from the arguments, including the program name.
    static func mode(arguments: [String]) -> Mode {
        let invokedAs = basename(arguments.first ?? "")
        if TrampolineWire.hookNames.contains(invokedAs) {
            return .hook(name: invokedAs)
        }
        if invokedAs.hasPrefix(TrampolineWire.credentialHelperProgramPrefix) {
            return .credential(arguments: Array(arguments.dropFirst()))
        }
        if arguments.count >= 2, arguments[1] == TrampolineWire.credentialHelperArgument {
            return .credential(arguments: Array(arguments.dropFirst(2)))
        }
        return .askpass(arguments: Array(arguments.dropFirst()))
    }

    /// Runs the helper and returns its exit status.
    static func run(arguments: [String], environment: [String: String]) -> Int32 {
        let mode = Self.mode(arguments: arguments)

        let socketVariable: String
        let tokenVariable: String
        if case .hook = mode {
            socketVariable = TrampolineWire.hooksSocketVariable
            tokenVariable = TrampolineWire.hooksTokenVariable
        } else {
            socketVariable = TrampolineWire.socketVariable
            tokenVariable = TrampolineWire.tokenVariable
        }

        guard let socketPath = environment[socketVariable], !socketPath.isEmpty else {
            return fail(mode, "\(socketVariable) is not set. Espalier sets it when it runs git.")
        }
        guard let token = environment[tokenVariable], !token.isEmpty else {
            return fail(mode, "\(tokenVariable) is not set. Espalier sets it when it runs git.")
        }

        let workingDirectory = FileManager.default.currentDirectoryPath
        let request: TrampolineWire.Request
        switch mode {
        case .askpass(let parameters):
            // Never read standard input: ssh runs askpass with its own
            // standard input, which carries the git protocol.
            request = TrampolineWire.Request(
                kind: TrampolineWire.RequestKind.askpass.rawValue,
                token: token,
                workingDirectory: workingDirectory,
                arguments: parameters,
                environment: [:],
                forwardsStandardInput: false
            )
        case .credential(let parameters):
            request = TrampolineWire.Request(
                kind: TrampolineWire.RequestKind.credential.rawValue,
                token: token,
                workingDirectory: workingDirectory,
                arguments: parameters,
                environment: [:],
                forwardsStandardInput: true
            )
        case .hook:
            // Only git's variables: the app decides which of them reach the
            // hook.
            let gitEnvironment = environment.filter { key, _ in
                key.hasPrefix("GIT_") || key.hasPrefix("GITHEAD_")
            }
            request = TrampolineWire.Request(
                kind: TrampolineWire.RequestKind.hook.rawValue,
                token: token,
                workingDirectory: workingDirectory,
                arguments: arguments,
                environment: gitEnvironment,
                forwardsStandardInput: isStandardInputConnected()
            )
        }

        let socket: Int32
        switch connect(to: socketPath) {
        case .success(let descriptor):
            socket = descriptor
        case .failure(let error):
            return fail(mode, "Couldn't connect to Espalier: \(error.message).")
        }
        defer { close(socket) }

        switch session(socket: socket, request: request) {
        case .success(let status):
            return status
        case .failure(let error):
            return fail(mode, error.message)
        }
    }

    // MARK: - Failure

    struct Failure: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        /// The current `errno`, described.
        static func errno(_ context: String) -> Failure {
            Failure("\(context): \(String(cString: strerror(Foundation.errno)))")
        }
    }

    /// Reports a failure on standard error and returns the exit status.
    /// Standard output stays empty, so neither ssh nor git mistakes the
    /// message for an answer.
    static func fail(_ mode: Mode, _ message: String) -> Int32 {
        let text: String
        if case .hook(let name) = mode {
            text = "The \(name) hook could not run: \(message)\n"
        } else {
            text = "espalier-askpass: \(message)\n"
        }
        _ = writeAll(STDERR_FILENO, Array(text.utf8))
        return 1
    }

    // MARK: - The session

    /// Sends the request, forwards standard input when the request says so,
    /// and copies the app's output to standard output and standard error
    /// until it sends an exit status.
    static func session(socket: Int32, request: TrampolineWire.Request) -> Result<Int32, Failure> {
        var outgoing = TrampolineWire.encode(.request, TrampolineWire.encodeRequest(request))
        var outgoingOffset = 0
        var readsStandardInput = request.forwardsStandardInput
        var decoder = TrampolineWire.FrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        // When the process that ran the helper (git or ssh) goes away, nobody
        // is waiting for the answer: exit, which closes the connection, so
        // the app stops waiting too (it cancels the prompt or stops the
        // hook), and git's pipes close promptly.
        let parent = getppid()

        while true {
            if getppid() != parent {
                return .failure(Failure("The program that ran espalier-askpass exited."))
            }
            let pendingOutgoing = outgoing.count - outgoingOffset
            var descriptors = [
                pollfd(
                    fd: socket,
                    events: Int16(POLLIN) | (pendingOutgoing > 0 ? Int16(POLLOUT) : 0),
                    revents: 0
                ),
            ]
            // Stop reading standard input while a lot is waiting to be sent,
            // so a slow app can't make the helper buffer without bound.
            if readsStandardInput, pendingOutgoing < TrampolineWire.maximumPayloadLength {
                descriptors.append(pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0))
            }

            // Wake up every second to check on the parent.
            let ready = poll(&descriptors, nfds_t(descriptors.count), 1000)
            if ready < 0 {
                if errno == EINTR { continue }
                return .failure(.errno("Couldn't wait for Espalier"))
            }
            if ready == 0 {
                continue
            }

            let socketEvents = descriptors[0].revents
            if socketEvents & Int16(POLLOUT) != 0, pendingOutgoing > 0 {
                let written = outgoing.withUnsafeBytes { bytes in
                    write(socket, bytes.baseAddress! + outgoingOffset, pendingOutgoing)
                }
                if written > 0 {
                    outgoingOffset += written
                    if outgoingOffset == outgoing.count {
                        outgoing.removeAll(keepingCapacity: true)
                        outgoingOffset = 0
                    } else if outgoingOffset >= TrampolineWire.maximumPayloadLength {
                        // Drop what was sent, so a long stream stays bounded.
                        outgoing.removeFirst(outgoingOffset)
                        outgoingOffset = 0
                    }
                } else if written < 0, errno != EAGAIN, errno != EINTR {
                    return .failure(.errno("Lost the connection to Espalier"))
                }
            }

            if socketEvents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = read(socket, &buffer, buffer.count)
                if count > 0 {
                    decoder.append(buffer[0..<count])
                    do {
                        while let frame = try decoder.next() {
                            switch frame.type {
                            case .standardOutput:
                                guard writeAll(STDOUT_FILENO, frame.payload) else {
                                    return .failure(.errno("Couldn't write to standard output"))
                                }
                            case .standardError:
                                guard writeAll(STDERR_FILENO, frame.payload) else {
                                    return .failure(.errno("Couldn't write to standard error"))
                                }
                            case .exit:
                                return .success(try TrampolineWire.decodeExitCode(frame.payload))
                            case .request, .standardInput, .standardInputEnd:
                                return .failure(Failure("Espalier sent an invalid reply."))
                            }
                        }
                    } catch {
                        return .failure(Failure("Espalier sent an invalid reply (\(error))."))
                    }
                } else if count == 0 {
                    return .failure(Failure("Espalier closed the connection without answering."))
                } else if errno != EAGAIN, errno != EINTR {
                    return .failure(.errno("Lost the connection to Espalier"))
                }
            }

            if descriptors.count > 1, descriptors[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 {
                    outgoing.append(contentsOf: TrampolineWire.encode(.standardInput, buffer[0..<count]))
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    outgoing.append(contentsOf: TrampolineWire.encode(.standardInputEnd))
                    readsStandardInput = false
                }
            }
        }
    }

    // MARK: - System calls

    /// Connects to the app's Unix domain socket. The socket doesn't raise
    /// SIGPIPE, isn't inherited by child processes, and doesn't block.
    static func connect(to path: String) -> Result<Int32, Failure> {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return .failure(Failure("the socket path is too long"))
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return .failure(.errno("socket"))
        }
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let failure = Failure.errno(path)
            close(descriptor)
            return .failure(Failure(failure.message))
        }

        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        return .success(descriptor)
    }

    /// Whether standard input carries data, as when git pipes a hook's input
    /// (pre-push, post-rewrite, reference-transaction) to it. Git runs every
    /// other hook with standard input reading `/dev/null`.
    static func isStandardInputConnected() -> Bool {
        var info = stat()
        guard fstat(STDIN_FILENO, &info) == 0 else { return false }
        let type = info.st_mode & S_IFMT
        return type == S_IFIFO || type == S_IFREG || type == S_IFSOCK
    }

    /// Writes every byte, waiting while the descriptor isn't writable.
    static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress! + offset, bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN {
                var descriptors = [pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)]
                _ = poll(&descriptors, 1, -1)
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// The last component of a path, like `basename(1)`.
    static func basename(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }
}
