import Darwin
import Dispatch
import Foundation
import os
import Synchronization

/// A child process with piped standard output and standard error, started
/// with `posix_spawn`.
///
/// The executable path, arguments, environment, and working directory reach
/// the child as their exact UTF-8 bytes.
/// `Foundation.Process` passes all of them through `fileSystemRepresentation`,
/// which decomposes "café" into "cafe\u{301}", and `URL(filePath:)` decomposes
/// paths the same way, so the configuration holds paths as strings.
///
/// As `Foundation.Process` does, the child starts in a process group of its
/// own, with default signal dispositions, an empty signal mask, and no open
/// descriptors besides its standard streams. It is reaped as soon as it
/// exits, through a dispatch process source, whether or not anyone waits.
///
/// Output arrives in chunks on a background queue and is handed to observers.
/// Register observers before calling `startReading()` so that no output is
/// missed; until then, output waits in the pipes.
///
/// `waitUntilExit()` returns once the process has terminated *and* both output
/// streams have reached end of file, so every chunk has been delivered by then.
public final class ChildProcess: Sendable {
    /// How to launch a child process.
    public struct Configuration: Sendable {
        /// The executable, passed to `posix_spawn` byte for byte.
        public var executablePath: String
        public var arguments: [String]
        /// The complete environment of the child. Nothing is inherited.
        public var environment: [String: String]
        /// The child's working directory, byte for byte, or `nil` for
        /// Espalier's own.
        public var currentDirectoryPath: String?
        /// When true, standard input is a pipe that the caller writes to with
        /// `writeToStandardInput(_:)` and closes with `closeStandardInput()`.
        /// Otherwise standard input reads from `/dev/null`.
        public var pipesStandardInput: Bool

        public init(
            executablePath: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            currentDirectoryPath: String? = nil,
            pipesStandardInput: Bool = false
        ) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.environment = environment
            self.currentDirectoryPath = currentDirectoryPath
            self.pipesStandardInput = pipesStandardInput
        }

        /// A configuration with file URLs. `URL(filePath:)` decomposes
        /// non-ASCII characters, so a path that may contain them should be
        /// passed as a string, with `init(executablePath:...)`.
        public init(
            executableURL: URL,
            arguments: [String] = [],
            environment: [String: String] = [:],
            currentDirectoryURL: URL? = nil,
            pipesStandardInput: Bool = false
        ) {
            self.init(
                executablePath: executableURL.path(percentEncoded: false),
                arguments: arguments,
                environment: environment,
                currentDirectoryPath: currentDirectoryURL?.path(percentEncoded: false),
                pipesStandardInput: pipesStandardInput
            )
        }

        public var executableURL: URL {
            get { URL(filePath: executablePath) }
            set { executablePath = newValue.path(percentEncoded: false) }
        }

        public var currentDirectoryURL: URL? {
            get { currentDirectoryPath.map { URL(filePath: $0, directoryHint: .isDirectory) } }
            set { currentDirectoryPath = newValue?.path(percentEncoded: false) }
        }
    }

    /// How a child process ended.
    public enum Termination: Sendable, Hashable {
        /// The process exited with this status code.
        case exit(Int32)
        /// The process was terminated by this signal.
        case signal(Int32)
    }

    /// The process could not be launched.
    public struct LaunchError: Error, CustomStringConvertible {
        /// The POSIX error name, such as `ENOENT` or `EACCES`, when known.
        public let code: String?
        public let underlying: any Error

        /// The error `posix_spawn` (or the pipe it needed) failed with.
        init(errno number: Int32) {
            code = Self.posixName(number)
            if let posixCode = POSIXErrorCode(rawValue: number) {
                underlying = POSIXError(posixCode)
            } else {
                underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(number))
            }
        }

        public var description: String {
            "Failed to launch process\(code.map { " (\($0))" } ?? ""): \(underlying.localizedDescription)"
        }

        private static func posixName(_ number: Int32) -> String? {
            switch number {
            case ENOENT: "ENOENT"
            case EACCES: "EACCES"
            case EPERM: "EPERM"
            case ENOTDIR: "ENOTDIR"
            case ENOEXEC: "ENOEXEC"
            case ENAMETOOLONG: "ENAMETOOLONG"
            case ELOOP: "ELOOP"
            case ETXTBSY: "ETXTBSY"
            case EAGAIN: "EAGAIN"
            case ENOMEM: "ENOMEM"
            case EMFILE: "EMFILE"
            case ENFILE: "ENFILE"
            case E2BIG: "E2BIG"
            default: nil
            }
        }
    }

    /// Identifies an observer so it can be removed.
    public struct ObserverToken: Sendable, Hashable {
        fileprivate let value: UInt64
        fileprivate let stream: Stream
    }

    fileprivate enum Stream: Sendable {
        case stdout
        case stderr
    }

    public typealias Observer = @Sendable (Data) -> Void

    /// How long to keep reading output after the process exits.
    static let outputGracePeriod: DispatchTimeInterval = .seconds(2)

    private let core: Core

    /// The process identifier of the running child.
    public let processIdentifier: Int32

    /// Launches a process. Output is not read until `startReading()`.
    public init(_ configuration: Configuration) throws(LaunchError) {
        var descriptors = Descriptors()
        do {
            let stdout = try descriptors.makePipe()
            let stderr = try descriptors.makePipe()
            let stdin = configuration.pipesStandardInput ? try descriptors.makePipe() : nil

            // Espalier's ends: output is read without blocking, and writing to
            // a child that stopped reading fails with EPIPE rather than
            // raising SIGPIPE, which would kill the app.
            _ = fcntl(stdout.read, F_SETFL, O_NONBLOCK)
            _ = fcntl(stderr.read, F_SETFL, O_NONBLOCK)
            if let stdin {
                _ = fcntl(stdin.write, F_SETNOSIGPIPE, 1)
            }

            let pid = try Spawn.launch(
                configuration,
                standardInput: stdin?.read,
                standardOutput: stdout.write,
                standardError: stderr.write,
                newSession: false
            )

            // The child has its own copies of these.
            descriptors.close(stdout.write)
            descriptors.close(stderr.write)
            if let stdin {
                descriptors.close(stdin.read)
            }
            descriptors.keepAll()

            core = Core(pid: pid, stdout: stdout.read, stderr: stderr.read, stdin: stdin?.write)
            processIdentifier = pid
        } catch {
            descriptors.closeAll()
            throw error
        }
        core.watchForExit()
    }

    deinit {
        // Nobody can observe the output any more, so drain it to keep the
        // child from blocking on a full pipe, and close its standard input so
        // that it reads end of file. The child is still reaped when it exits.
        core.startReading()
        core.closeStandardInput()
    }

    /// Calls `observer` with every chunk of standard output.
    @discardableResult
    public func observeStandardOutput(_ observer: @escaping Observer) -> ObserverToken {
        core.addObserver(observer, to: .stdout)
    }

    /// Calls `observer` with every chunk of standard error.
    @discardableResult
    public func observeStandardError(_ observer: @escaping Observer) -> ObserverToken {
        core.addObserver(observer, to: .stderr)
    }

    public func removeObserver(_ token: ObserverToken) {
        core.removeObserver(token)
    }

    /// Starts delivering output to observers. Safe to call more than once.
    public func startReading() {
        core.startReading()
    }

    /// Writes `data` to the child's standard input. Requires
    /// `pipesStandardInput`. A child that has stopped reading (EPIPE) is not
    /// an error; its exit status tells the real story.
    public func writeToStandardInput(_ data: Data) async throws {
        try await core.stdin?.write(data)
    }

    /// Calls `handler` once the process has terminated and both output streams
    /// have closed, after the last chunk has reached the observers and before
    /// `waitUntilExit()` returns. If that has already happened, calls it right
    /// away.
    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        core.onClose(handler)
    }

    /// Closes the child's standard input so it reads end of file, once what
    /// was written before has been delivered.
    public func closeStandardInput() {
        core.closeStandardInput()
    }

    /// Sends `signal` to the child if it is still running.
    public func terminate(signal: Int32 = SIGTERM) {
        core.signal(signal)
    }

    /// Sends `signal` to the child's process group, the child and the
    /// processes it started (which stay in its group unless they leave), if
    /// the child is still running. Use it to stop helpers that would outlive
    /// the child, such as git's transport and submodule processes.
    public func terminateProcessGroup(signal: Int32 = SIGTERM) {
        core.signalGroup(signal)
    }

    /// Waits until the process has terminated and all of its output has been
    /// delivered. Starts reading if nobody has yet.
    public func waitUntilExit() async -> Termination {
        core.startReading()
        return await core.waitUntilClosed()
    }
}

// MARK: - Detached processes

extension ChildProcess {
    /// Starts a process that runs on its own: in a new session, with all
    /// three standard streams on `/dev/null`, so it is unaffected when
    /// Espalier quits. Espalier still reaps it when it exits.
    ///
    /// `configuration.pipesStandardInput` is ignored.
    ///
    /// - Parameter onExit: Called on a background queue once the process has
    ///   exited.
    /// - Returns: The process identifier.
    @discardableResult
    public static func spawnDetached(
        _ configuration: Configuration,
        onExit: (@Sendable (Termination) -> Void)? = nil
    ) throws(LaunchError) -> Int32 {
        let pid = try Spawn.launch(configuration, standardInput: nil, standardOutput: nil, standardError: nil, newSession: true)
        Reaper.watch(pid, on: .global(qos: .utility)) {
            guard let termination = Reaper.reap(pid) else {
                return false
            }
            onExit?(termination)
            return true
        }
        return pid
    }
}

// MARK: - Launching

/// The descriptors `ChildProcess.init` opens, so that a failed launch closes
/// all of them.
private struct Descriptors {
    struct Pipe {
        let read: Int32
        let write: Int32
    }

    private var open: [Int32] = []

    /// A pipe whose ends are close-on-exec and above the standard streams, so
    /// a `dup2` onto 0, 1, or 2 in the child never targets its own source.
    mutating func makePipe() throws(ChildProcess.LaunchError) -> Pipe {
        var ends: (Int32, Int32) = (-1, -1)
        let result = withUnsafeMutableBytes(of: &ends) { bytes in
            Darwin.pipe(bytes.baseAddress!.assumingMemoryBound(to: Int32.self))
        }
        guard result == 0 else {
            throw ChildProcess.LaunchError(errno: errno)
        }
        open += [ends.0, ends.1]
        let read = try closeOnExec(ends.0)
        let write = try closeOnExec(ends.1)
        return Pipe(read: read, write: write)
    }

    mutating func close(_ descriptor: Int32) {
        if let index = open.firstIndex(of: descriptor) {
            open.remove(at: index)
        }
        _ = Darwin.close(descriptor)
    }

    /// The remaining descriptors now belong to the caller.
    mutating func keepAll() {
        open = []
    }

    mutating func closeAll() {
        for descriptor in open {
            _ = Darwin.close(descriptor)
        }
        open = []
    }

    /// Makes `descriptor` close-on-exec, first moving it above the standard
    /// streams when it is one of them (when Espalier's own are closed).
    private mutating func closeOnExec(_ descriptor: Int32) throws(ChildProcess.LaunchError) -> Int32 {
        guard descriptor <= STDERR_FILENO else {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            return descriptor
        }
        let moved = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard moved >= 0 else {
            throw ChildProcess.LaunchError(errno: errno)
        }
        open.append(moved)
        close(descriptor)
        return moved
    }
}

private enum Spawn {
    /// Starts the child and returns its process identifier. Each standard
    /// stream is the given descriptor, or `/dev/null` when it is `nil`.
    static func launch(
        _ configuration: ChildProcess.Configuration,
        standardInput: Int32?,
        standardOutput: Int32?,
        standardError: Int32?,
        newSession: Bool
    ) throws(ChildProcess.LaunchError) -> pid_t {
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        // As Foundation.Process: no descriptor is inherited unless a file
        // action names it, every signal has its default disposition, and none
        // is blocked. A detached child gets a session of its own (and so a
        // process group); any other child gets a process group of its own.
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        flags |= newSession ? POSIX_SPAWN_SETSID : POSIX_SPAWN_SETPGROUP
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var signals = sigset_t()
        sigfillset(&signals)
        try check(posix_spawnattr_setsigdefault(&attributes, &signals))
        sigemptyset(&signals)
        try check(posix_spawnattr_setsigmask(&attributes, &signals))

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }

        let streams = [
            (STDIN_FILENO, standardInput, O_RDONLY),
            (STDOUT_FILENO, standardOutput, O_WRONLY),
            (STDERR_FILENO, standardError, O_WRONLY),
        ]
        for (target, source, nullMode) in streams {
            if let source {
                try check(posix_spawn_file_actions_adddup2(&actions, source, target))
            } else {
                try check(posix_spawn_file_actions_addopen(&actions, target, "/dev/null", nullMode, 0))
            }
        }
        if let directory = configuration.currentDirectoryPath {
            try check(posix_spawn_file_actions_addchdir(&actions, directory))
        }

        var pid: pid_t = 0
        let environment = configuration.environment.map { "\($0.key)=\($0.value)" }
        let result = withCStrings([configuration.executablePath] + configuration.arguments) { argv in
            withCStrings(environment) { envp in
                posix_spawn(&pid, configuration.executablePath, &actions, &attributes, argv, envp)
            }
        }
        try check(result)
        return pid
    }

    private static func check(_ result: Int32) throws(ChildProcess.LaunchError) {
        if result != 0 {
            throw ChildProcess.LaunchError(errno: result)
        }
    }

    /// Calls `body` with `strings` as a NULL-terminated array of C strings
    /// holding their exact UTF-8 bytes, all in one allocation.
    private static func withCStrings<Result>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var byteCount = 0
        for string in strings {
            byteCount += string.utf8.count + 1
        }
        let bytes = UnsafeMutablePointer<CChar>.allocate(capacity: max(byteCount, 1))
        defer { bytes.deallocate() }
        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        defer { pointers.deallocate() }

        var offset = 0
        for (index, string) in strings.enumerated() {
            var string = string
            let start = bytes + offset
            pointers[index] = start
            string.withUTF8 { utf8 in
                if let base = utf8.baseAddress {
                    UnsafeMutableRawPointer(start).copyMemory(from: base, byteCount: utf8.count)
                }
                offset += utf8.count
            }
            bytes[offset] = 0
            offset += 1
        }
        pointers[strings.count] = nil
        return body(pointers)
    }
}

// MARK: - Reaping

private enum Reaper {
    private static let logger = Log.logger(category: "ChildProcess")

    /// Calls `reap` on `queue` when `pid` exits, and again after growing
    /// delays until it returns true: the exit event can arrive a moment
    /// before the child can be waited for (about once in a thousand exits).
    static func watch(_ pid: pid_t, on queue: DispatchQueue, reap: @escaping @Sendable () -> Bool) {
        // libdispatch reports a child that has already exited (a zombie) as
        // exited at once.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler {
            source.cancel()
            retry(reap, on: queue, microseconds: 50)
        }
        source.activate()
    }

    private static func retry(_ reap: @escaping @Sendable () -> Bool, on queue: DispatchQueue, microseconds: Int) {
        guard !reap() else {
            return
        }
        queue.asyncAfter(deadline: .now() + .microseconds(microseconds)) {
            retry(reap, on: queue, microseconds: min(microseconds * 2, 100_000))
        }
    }

    /// Reaps `pid` without blocking: how it ended, or `nil` while it can't
    /// be waited for yet.
    static func reap(_ pid: pid_t) -> ChildProcess.Termination? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                let signal = status & 0x7F
                return signal == 0 ? .exit((status >> 8) & 0xFF) : .signal(signal)
            }
            if result == 0 {
                return nil
            }
            let error = errno
            if error == EINTR {
                continue
            }
            // Something else reaped the child (or SIGCHLD is ignored), so its
            // status is lost. Report a failure rather than wait forever.
            logger.error("Could not wait for process \(pid, privacy: .public): \(String(cString: strerror(error)), privacy: .public)")
            return .exit(-1)
        }
    }
}

// MARK: - The running process

/// What a `ChildProcess`, its dispatch sources, and the tasks waiting for it
/// share. The sources keep it alive until the child has been reaped and its
/// output has ended, so dropping the `ChildProcess` leaves no zombie and no
/// child blocked on a full pipe.
private final class Core: Sendable {
    enum Phase {
        case running
        /// The close handlers are running; waiters resume after them.
        case closing
        case closed
    }

    struct State {
        var stdoutObservers: [(token: UInt64, observer: ChildProcess.Observer)] = []
        var stderrObservers: [(token: UInt64, observer: ChildProcess.Observer)] = []
        var nextToken: UInt64 = 0
        var isReading = false
        var openStreams = 2
        var termination: ChildProcess.Termination?
        var phase = Phase.running
        var waiters: [CheckedContinuation<ChildProcess.Termination, Never>] = []
        var closeHandlers: [@Sendable () -> Void] = []
    }

    /// The largest chunk delivered at once.
    private static let maximumChunkSize = 1 << 20

    let pid: pid_t
    let stdin: InputPipe?
    private let state = Mutex(State())
    /// Delivers output and reaps the child, one event at a time.
    private let queue: DispatchQueue
    private let stdout: OutputPipe
    private let stderr: OutputPipe

    // Only used on `queue`.
    nonisolated(unsafe) private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16)
    nonisolated(unsafe) private var hasStartedReading = false
    nonisolated(unsafe) private var isGracePeriodScheduled = false

    init(pid: pid_t, stdout: Int32, stderr: Int32, stdin: Int32?) {
        let queue = DispatchQueue(label: "dev.abdeen.espalier.ChildProcess", qos: .userInitiated)
        self.pid = pid
        self.queue = queue
        self.stdout = OutputPipe(descriptor: stdout, stream: .stdout)
        self.stderr = OutputPipe(descriptor: stderr, stream: .stderr)
        self.stdin = stdin.map { InputPipe(descriptor: $0, queue: queue) }
    }

    deinit {
        buffer.deallocate()
    }

    func watchForExit() {
        Reaper.watch(pid, on: queue) { [self] in
            reapIfExited()
        }
    }

    // MARK: Observers and waiters

    func addObserver(_ observer: @escaping ChildProcess.Observer, to stream: ChildProcess.Stream) -> ChildProcess.ObserverToken {
        state.withLock { state in
            let value = state.nextToken
            state.nextToken += 1
            switch stream {
            case .stdout: state.stdoutObservers.append((value, observer))
            case .stderr: state.stderrObservers.append((value, observer))
            }
            return ChildProcess.ObserverToken(value: value, stream: stream)
        }
    }

    func removeObserver(_ token: ChildProcess.ObserverToken) {
        state.withLock { state in
            switch token.stream {
            case .stdout: state.stdoutObservers.removeAll { $0.token == token.value }
            case .stderr: state.stderrObservers.removeAll { $0.token == token.value }
            }
        }
    }

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let isClosed = state.withLock { state in
            if state.phase != .closed {
                state.closeHandlers.append(handler)
            }
            return state.phase == .closed
        }
        if isClosed {
            handler()
        }
    }

    func waitUntilClosed() async -> ChildProcess.Termination {
        await withCheckedContinuation { continuation in
            let termination: ChildProcess.Termination? = state.withLock { state in
                if state.phase == .closed {
                    return state.termination
                }
                state.waiters.append(continuation)
                return nil
            }
            if let termination {
                continuation.resume(returning: termination)
            }
        }
    }

    func signal(_ signal: Int32) {
        // Under the lock, so the child can't be reaped (and its identifier
        // reused) in between.
        state.withLock { state in
            if state.termination == nil {
                _ = kill(pid, signal)
            }
        }
    }

    func signalGroup(_ signal: Int32) {
        // The child leads its process group, whose identifier is its own.
        // While the child hasn't been reaped, that identifier can't be
        // reused, so the signal reaches only the child's group.
        state.withLock { state in
            if state.termination == nil {
                _ = killpg(pid, signal)
            }
        }
    }

    func closeStandardInput() {
        stdin?.close()
    }

    // MARK: Output

    func startReading() {
        let shouldStart = state.withLock { state in
            defer { state.isReading = true }
            return !state.isReading
        }
        guard shouldStart else {
            return
        }
        queue.async { [self] in
            start(stdout)
            start(stderr)
            hasStartedReading = true
            if state.withLock({ $0.termination != nil }) {
                scheduleGracePeriod()
            }
        }
    }

    /// On `queue`.
    private func start(_ pipe: OutputPipe) {
        pipe.start(on: queue) { [self] in
            readAvailable(from: pipe)
        }
    }

    /// Reads and delivers what `pipe` holds, and closes it at end of file. On
    /// `queue`.
    private func readAvailable(from pipe: OutputPipe) {
        var chunk = Data()
        var isAtEnd = false
        reading: while chunk.count < Self.maximumChunkSize {
            let count = Darwin.read(pipe.descriptor, buffer.baseAddress, buffer.count)
            if count > 0 {
                chunk.append(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count)
            } else if count == 0 {
                isAtEnd = true
                break
            } else {
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    break reading
                default:
                    isAtEnd = true
                    break reading
                }
            }
        }

        if !chunk.isEmpty {
            let observers = state.withLock { state in
                switch pipe.stream {
                case .stdout: state.stdoutObservers.map(\.observer)
                case .stderr: state.stderrObservers.map(\.observer)
                }
            }
            for observer in observers {
                observer(chunk)
            }
        }

        if isAtEnd {
            close(pipe)
        }
    }

    /// On `queue`.
    private func close(_ pipe: OutputPipe) {
        guard pipe.isOpen else {
            return
        }
        pipe.close()
        update { $0.openStreams -= 1 }
    }

    /// A grandchild that inherited the child's output (a backgrounded hook,
    /// a shell alias) can hold it open long after the child exits. Once the
    /// child is gone, read for a little longer, then stop waiting for end of
    /// file. On `queue`.
    private func scheduleGracePeriod() {
        guard !isGracePeriodScheduled, stdout.isOpen || stderr.isOpen else {
            return
        }
        isGracePeriodScheduled = true
        queue.asyncAfter(deadline: .now() + ChildProcess.outputGracePeriod) { [self] in
            for pipe in [stdout, stderr] where pipe.isOpen {
                readAvailable(from: pipe)
                close(pipe)
            }
        }
    }

    // MARK: Exit

    /// True once the child has been reaped. On `queue`.
    private func reapIfExited() -> Bool {
        var isReaped = false
        update { state in
            // Under the lock, so `signal(_:)` never targets a reaped child.
            if let termination = Reaper.reap(pid) {
                state.termination = termination
                isReaped = true
            }
        }
        if isReaped, hasStartedReading {
            scheduleGracePeriod()
        }
        return isReaped
    }

    /// Applies `change`. Once the child has been reaped and both streams have
    /// closed, runs the close handlers, then resumes the waiters.
    private func update(_ change: (inout State) -> Void) {
        let closeHandlers: [@Sendable () -> Void]? = state.withLock { state in
            change(&state)
            guard state.phase == .running, state.termination != nil, state.openStreams == 0 else {
                return nil
            }
            state.phase = .closing
            defer { state.closeHandlers = [] }
            return state.closeHandlers
        }
        guard var handlers = closeHandlers else {
            return
        }

        while true {
            for handler in handlers {
                handler()
            }
            // Handlers added while those ran come next, then the waiters.
            let next: (handlers: [@Sendable () -> Void], waiters: [CheckedContinuation<ChildProcess.Termination, Never>], termination: ChildProcess.Termination?) = state.withLock { state in
                if !state.closeHandlers.isEmpty {
                    defer { state.closeHandlers = [] }
                    return (state.closeHandlers, [], nil)
                }
                state.phase = .closed
                defer { state.waiters = [] }
                return ([], state.waiters, state.termination)
            }
            guard let termination = next.termination else {
                handlers = next.handlers
                continue
            }
            for waiter in next.waiters {
                waiter.resume(returning: termination)
            }
            return
        }
    }
}

/// Espalier's end of one of the child's output pipes. Only used on the
/// child's queue.
private final class OutputPipe: Sendable {
    let descriptor: Int32
    let stream: ChildProcess.Stream

    nonisolated(unsafe) private var source: (any DispatchSourceRead)?
    nonisolated(unsafe) private(set) var isOpen = true

    init(descriptor: Int32, stream: ChildProcess.Stream) {
        self.descriptor = descriptor
        self.stream = stream
    }

    /// Calls `onReadable` on `queue` whenever the pipe has data or reaches
    /// end of file.
    func start(on queue: DispatchQueue, onReadable: @escaping () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler(handler: onReadable)
        let descriptor = descriptor
        source.setCancelHandler {
            _ = Darwin.close(descriptor)
        }
        self.source = source
        source.activate()
    }

    /// Stops reading; the descriptor closes once the source has stopped.
    func close() {
        isOpen = false
        if let source {
            source.cancel()
            self.source = nil
        } else {
            _ = Darwin.close(descriptor)
        }
    }
}

/// Espalier's end of the child's standard input, written without blocking
/// on the child's queue, from a write source while the pipe is full, so that
/// no thread waits on a slow reader and heavy load can't starve the writes.
/// (DispatchIO writes a pipe from libdispatch's shared queues at default
/// priority.)
private final class InputPipe: Sendable {
    /// Data waiting for room in the pipe, in order.
    private struct PendingWrite {
        let data: Data
        var offset = 0
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let descriptor: Int32
    private let queue: DispatchQueue
    /// Set by `close()`, so that later writes fail at once.
    private let isClosed = Atomic(false)

    // Only used on `queue`.
    nonisolated(unsafe) private var pendingWrites: [PendingWrite] = []
    nonisolated(unsafe) private var source: (any DispatchSourceWrite)?
    /// Sources not yet through their cancel handlers: the descriptor closes
    /// when none are left.
    nonisolated(unsafe) private var liveSources = 0
    /// `close()` was called: the pipe shuts down once the pending writes end.
    nonisolated(unsafe) private var isClosing = false
    nonisolated(unsafe) private var isShutDown = false
    /// How writing ended early: nil for a child that stopped reading (EPIPE),
    /// whose later writes succeed without writing, or the error that later
    /// writes fail with.
    nonisolated(unsafe) private var ending: (any Error)??

    init(descriptor: Int32, queue: DispatchQueue) {
        self.descriptor = descriptor
        self.queue = queue
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }

    deinit {
        // `close()` shuts the pipe down before the last reference goes; this
        // covers a pipe released without it.
        if !isShutDown, liveSources == 0 {
            _ = Darwin.close(descriptor)
        }
    }

    /// Writes `data` in order with earlier writes, returning once the pipe
    /// has taken all of it. EPIPE, from a child that stopped reading, is not
    /// an error.
    func write(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        guard !isClosed.load(ordering: .acquiring) else {
            throw POSIXError(.EBADF)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                enqueue(PendingWrite(data: data, continuation: continuation))
            }
        }
    }

    /// Closes the pipe once earlier writes have finished.
    func close() {
        guard !isClosed.exchange(true, ordering: .acquiringAndReleasing) else {
            return
        }
        queue.async { [self] in
            isClosing = true
            if pendingWrites.isEmpty {
                shutDown()
            }
        }
    }

    /// On `queue`.
    private func enqueue(_ write: PendingWrite) {
        if isClosing {
            // `close()` came first.
            write.continuation.resume(throwing: POSIXError(.EBADF))
            return
        }
        switch ending {
        case .some(nil):
            write.continuation.resume()
            return
        case .some(let error?):
            write.continuation.resume(throwing: error)
            return
        case nil:
            break
        }
        pendingWrites.append(write)
        // With earlier writes still waiting for room, the write source sends
        // this one after them.
        if pendingWrites.count == 1 {
            writePending()
        }
    }

    /// Writes the pending data in order until the pipe is full, then waits
    /// for room. On `queue`.
    private func writePending() {
        while let write = pendingWrites.first {
            let written = write.data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress! + write.offset, bytes.count - write.offset)
            }
            let error = errno
            if written > 0 {
                pendingWrites[0].offset += written
                if pendingWrites[0].offset == write.data.count {
                    pendingWrites.removeFirst().continuation.resume()
                }
            } else if written < 0, error == EINTR {
                continue
            } else if written == 0 || error == EAGAIN {
                waitForRoom()
                return
            } else if error == EPIPE {
                // A child that stopped reading isn't an error: its exit
                // status tells what went wrong.
                end(nil)
            } else {
                end(POSIXErrorCode(rawValue: error).map { POSIXError($0) } ?? POSIXError(.EIO))
            }
        }
        if let source {
            source.cancel()
            self.source = nil
        }
        if isClosing {
            shutDown()
        }
    }

    /// Ends every pending write and every later one: successfully for nil,
    /// or with `error`. On `queue`.
    private func end(_ error: (any Error)?) {
        ending = .some(error)
        let ended = pendingWrites
        pendingWrites = []
        for write in ended {
            if let error {
                write.continuation.resume(throwing: error)
            } else {
                write.continuation.resume()
            }
        }
    }

    /// Watches for room in the pipe, then writes. On `queue`.
    private func waitForRoom() {
        guard source == nil else {
            return
        }
        let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [self] in
            writePending()
        }
        source.setCancelHandler { [self] in
            sourceDidCancel()
        }
        self.source = source
        liveSources += 1
        source.activate()
    }

    /// A source finished cancelling; the last one after shutting down closes
    /// the descriptor. On `queue`.
    private func sourceDidCancel() {
        liveSources -= 1
        if isShutDown, liveSources == 0 {
            _ = Darwin.close(descriptor)
        }
    }

    /// Closes the descriptor once every source has stopped. On `queue`.
    private func shutDown() {
        guard !isShutDown else {
            return
        }
        isShutDown = true
        if let source {
            source.cancel()
            self.source = nil
        }
        if liveSources == 0 {
            _ = Darwin.close(descriptor)
        }
    }
}
