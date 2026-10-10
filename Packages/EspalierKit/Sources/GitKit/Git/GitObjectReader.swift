// Reads objects through a long-lived `git cat-file --batch` instead of a
// process per read. GitShow.swift uses this reader where its answer is
// provably identical to `git show <rev>:<path>`.

import EspalierSupport
import Foundation
import Synchronization
import os

private let logger = Log.logger(category: "object-reader")

/// Reads objects from one repository through a long-lived
/// `git cat-file --batch` process.
///
/// - The process starts on the first read, and again after it dies.
/// - Reads are served one at a time, in the order they arrive.
/// - Cancelling a read discards the process, because its output is then at an
///   unknown position; the next read starts a new one.
/// - After `idleTimeout` without reads the process exits, and the shared
///   reader leaves the registry.
///
/// **Freshness.** A long-lived git process caches some repository state the
/// first time it needs it, while a new process (`git show`) always
/// sees the current state. The cached state that changes how a name resolves
/// or what an object contains: replace refs, grafts, the shallow file,
/// alternates, and configuration (all tracked below), the index, and the
/// loose-object listing used to expand abbreviated object IDs. Before every
/// read the reader compares a fingerprint (`stat` results) of the files
/// behind the tracked state with the one taken when its process started, and
/// starts a new process when they differ. It refuses names that read the
/// index or expand abbreviated IDs (see `isFreshName`). Refs themselves are
/// re-read by git on every lookup. Configuration pulled in through
/// `include.path` is not tracked; the idle timeout bounds how long such a
/// change can go unnoticed.
public actor GitObjectReader {
    /// An object's header and contents.
    public struct Object: Hashable, Sendable {
        /// The object ID git resolved the name to.
        public let oid: String
        /// `blob`, `tree`, `commit`, or `tag`.
        public let type: String
        /// The full size of the object in bytes.
        public let size: Int
        /// The object's contents, truncated to the requested limit.
        public let contents: Data
    }

    /// What `git cat-file --batch` reported for an object name.
    public enum Response: Hashable, Sendable {
        case object(Object)
        case missing
        case ambiguous
        /// A submodule commit that isn't in this repository's object database.
        case submodule(oid: String)
    }

    /// How long the process may sit unused before it exits.
    public static let defaultIdleTimeout: Duration = .seconds(15)

    /// Reading and dropping the rest of an object that a limited read
    /// doesn't need is cheaper than starting a new process only up to here.
    static let discardLimit = 1 << 20

    /// How long a failure to find the repository is remembered before the
    /// reader tries again.
    static let discoveryRetryInterval: Duration = .seconds(5)

    /// Environment for the reader's own git processes, on top of the
    /// runtime's. `TERM` is what `git()` sets. Lazy fetching is off: in a
    /// partial clone the reader reports a missing object instead of fetching
    /// it without the credential trampoline, and callers fall back to git.
    static let environmentOverrides: [String: String?] = [
        "TERM": "dumb",
        "GIT_NO_LAZY_FETCH": "1",
    ]

    /// The working directory cat-file runs in.
    public let repositoryPath: String
    let runtime: GitRuntime
    let idleTimeout: Duration
    let key: Key?

    private var session: Session?
    private var discovery: Discovery?
    private var discoveryFailedAt: ContinuousClock.Instant?

    private var isBusy = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextWaiterID: UInt64 = 0

    private var lastActivity = ContinuousClock.now
    private var idleTask: Task<Void, Never>?

    /// The repository state in which a `git show` last succeeded; see
    /// `attemptShow`.
    private var showValidatedState: RepositoryState?

    /// How many cat-file processes this reader has started.
    private(set) var processesStarted = 0

    /// What the reader is doing, for tests to wait on.
    enum Event: Sendable, Equatable {
        /// A read is queued behind the one in progress.
        case queued
        /// A read sent its name to cat-file and waits for the answer.
        case awaitingResponse
        /// The idle timer stopped the process.
        case idleShutdown
    }

    private var eventHandler: (@Sendable (Event) -> Void)?

    /// Calls `handler` on the reader for each event from now on (for tests).
    func observeEvents(_ handler: @escaping @Sendable (Event) -> Void) {
        eventHandler = handler
    }

    /// A reader outside the shared registry. Use `shared(for:)` instead,
    /// except in tests.
    init(
        repositoryPath: String,
        runtime: GitRuntime = .current,
        idleTimeout: Duration = defaultIdleTimeout,
        key: Key? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.runtime = runtime
        self.idleTimeout = idleTimeout
        self.key = key
    }

    deinit {
        session?.terminate()
    }

    /// The process identifier of the running cat-file, if any.
    var processIdentifier: Int32? {
        session?.isAlive == true ? session?.child.processIdentifier : nil
    }

    /// Reads the object `name` names, keeping at most `limit` bytes of its
    /// contents.
    ///
    /// - Parameter name: An object name `isFreshName` accepts: `HEAD` or a
    ///   full object ID, optionally followed by `~`/`^` steps and `:path`.
    /// - Returns: cat-file's answer, or nil when the reader can't answer
    ///   (the name isn't fresh, the path isn't a repository, or git failed);
    ///   run git instead.
    /// - Throws: `CancellationError` when the calling task is cancelled.
    public func read(_ name: String, limit: Int? = nil) async throws -> Response? {
        precondition((limit ?? 0) >= 0, "limit must not be negative")
        try await acquire()
        defer { release() }
        try Task.checkCancellation()

        guard let context = try await currentContext(),
              Self.isFreshName(name, objectIDLength: context.objectIDLength)
        else {
            return nil
        }
        return try await performRead(name, limit: limit, state: context.state)
    }

    /// Stops the process now. The next read starts a new one.
    public func shutDown() {
        if let session {
            discard(session)
        }
    }

    // MARK: - Reading

    private func performRead(_ name: String, limit: Int?, state: RepositoryState) async throws -> Response? {
        for attempt in 0..<2 {
            guard let (session, isNew) = sessionForRead(state: state) else {
                return nil
            }

            // A process that died since the last read looks alive until its
            // output closes; retry once with a new one.
            let mayRetry = !isNew && attempt == 0

            guard await session.send(name) else {
                discard(session)
                if mayRetry { continue }
                return nil
            }
            eventHandler?(.awaitingResponse)

            switch await session.output.readLine(maxLength: name.utf8.count + 128) {
            case .cancelled:
                discard(session)
                throw CancellationError()
            case .closed:
                discard(session)
                if mayRetry { continue }
                return nil
            case .data(let line):
                return try await readResponse(String(decoding: line, as: UTF8.self), for: name, limit: limit, from: session)
            }
        }
        return nil
    }

    private func readResponse(
        _ header: String,
        for name: String,
        limit: Int?,
        from session: Session
    ) async throws -> Response? {
        if JSCompat.strictEquals(header, "\(name) missing") {
            return .missing
        }
        if JSCompat.strictEquals(header, "\(name) ambiguous") {
            return .ambiguous
        }

        let fields = JSCompat.split(header, " ")
        if fields.count == 2, Self.isObjectID(fields[0]), fields[1] == "submodule" {
            return .submodule(oid: fields[0])
        }

        guard fields.count == 3,
              Self.isObjectID(fields[0]),
              ["blob", "tree", "commit", "tag"].contains(fields[1]),
              !fields[2].isEmpty, fields[2].utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let size = Int(fields[2])
        else {
            logger.error("Unexpected cat-file response; restarting it")
            discard(session)
            return nil
        }

        let kept = min(size, limit ?? size)
        let contents: Data
        switch await session.output.readBytes(kept) {
        case .data(let data):
            contents = data
        case .cancelled:
            discard(session)
            throw CancellationError()
        case .closed:
            discard(session)
            return nil
        }

        // The rest of the contents, then a newline.
        let remaining = size - kept + 1
        if remaining > Self.discardLimit {
            discard(session)
        } else {
            switch await session.output.readBytes(remaining) {
            case .data(let rest) where rest.last == 0x0A:
                break
            case .cancelled:
                discard(session)
                throw CancellationError()
            case .data, .closed:
                discard(session)
                return nil
            }
        }

        return .object(Object(oid: fields[0], type: fields[1], size: size, contents: contents))
    }

    /// The running session if it's alive and the repository state hasn't
    /// changed since it started; otherwise a new one.
    private func sessionForRead(state: RepositoryState) -> (Session, isNew: Bool)? {
        if let session, session.isAlive, session.state == state {
            return (session, false)
        }
        if let session {
            discard(session)
        }

        guard let session = Session.start(repositoryPath: repositoryPath, runtime: runtime, state: state) else {
            return nil
        }
        processesStarted += 1
        self.session = session
        return (session, true)
    }

    private func discard(_ session: Session) {
        session.terminate()
        if self.session === session {
            self.session = nil
        }
    }

    // MARK: - Names

    /// Whether a new git process would resolve `name` exactly as this
    /// reader's long-lived one does: `HEAD` or a full object ID, then any
    /// number of `~`/`^` steps (each optionally numbered), then the end or
    /// `:path`. A path with a line break or NUL can't be sent to cat-file.
    static func isFreshName(_ name: String, objectIDLength: Int) -> Bool {
        let bytes = Array(name.utf8)
        if bytes.contains(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x00 }) {
            return false
        }

        var index: Int
        if bytes.starts(with: "HEAD".utf8) {
            index = 4
        } else if bytes.count >= objectIDLength, bytes[..<objectIDLength].allSatisfy(isHexDigit) {
            index = objectIDLength
        } else {
            return false
        }

        while index < bytes.count, bytes[index] == UInt8(ascii: "~") || bytes[index] == UInt8(ascii: "^") {
            index += 1
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                index += 1
            }
        }

        return index == bytes.count || bytes[index] == UInt8(ascii: ":")
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    private static func isObjectID(_ string: String) -> Bool {
        let bytes = string.utf8
        return (bytes.count == 40 || bytes.count == 64)
            && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    // MARK: - Repository state

    struct Discovery: Sendable {
        /// Files whose contents a git process reads once; see `RepositoryState`.
        let statePaths: [String]
        /// 40 for SHA-1 repositories, 64 for SHA-256.
        let objectIDLength: Int
    }

    private func currentContext() async throws -> (state: RepositoryState, objectIDLength: Int)? {
        if discovery == nil {
            if let failedAt = discoveryFailedAt, ContinuousClock.now - failedAt < Self.discoveryRetryInterval {
                return nil
            }
            discovery = try await discover()
            discoveryFailedAt = discovery == nil ? .now : nil
        }
        guard let discovery else {
            return nil
        }
        return (RepositoryState(paths: discovery.statePaths), discovery.objectIDLength)
    }

    /// Asks git where the files it reads once live, and which object format
    /// the repository uses. One process per reader.
    private func discover() async throws -> Discovery? {
        let (environment, _) = Dugite.setupEnvironment(
            Self.environmentOverrides,
            processEnv: runtime.processEnvironment,
            gitDir: runtime.gitDirectory
        )
        let replaceRefBase = environment["GIT_REPLACE_REF_BASE"].flatMap { $0.isEmpty ? nil : $0 } ?? "refs/replace/"
        let gitPaths = [
            "config",
            "config.worktree",
            "packed-refs",
            replaceRefBase,
            "info/grafts",
            "shallow",
            "objects/info/alternates",
            "reftable/tables.list",
        ]

        var args = ["rev-parse", "--path-format=absolute", "--show-object-format"]
        for path in gitPaths {
            args.append(contentsOf: ["--git-path", path])
        }

        let result: Dugite.Result
        do {
            result = try await Dugite.exec(
                args,
                repositoryPath,
                options: Dugite.ExecutionOptions(env: Self.environmentOverrides),
                runtime: runtime
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }

        guard result.exitCode == 0 else {
            return nil
        }

        // A path with a line break can't be told apart; don't read then.
        let lines = JSCompat.split(String(decoding: result.stdout, as: UTF8.self), "\n")
        guard lines.count == gitPaths.count + 2, lines[lines.count - 1].isEmpty else {
            return nil
        }

        let objectIDLength: Int
        switch lines[0] {
        case "sha1": objectIDLength = 40
        case "sha256": objectIDLength = 64
        default: return nil
        }

        let statePaths = Array(lines[1...gitPaths.count]) + configurationPaths(environment)
        return Discovery(statePaths: statePaths, objectIDLength: objectIDLength)
    }

    /// The global and system configuration files git reads, from its
    /// environment.
    private func configurationPaths(_ environment: [String: String]) -> [String] {
        func value(_ name: String) -> String? {
            environment[name].flatMap { $0.isEmpty ? nil : $0 }
        }

        var paths: [String] = []
        if let global = value("GIT_CONFIG_GLOBAL") {
            paths.append(global)
        } else {
            if let home = value("HOME") {
                paths.append(POSIXPath.join(home, ".gitconfig"))
            }
            if let xdg = value("XDG_CONFIG_HOME") {
                paths.append(POSIXPath.join(xdg, "git", "config"))
            } else if let home = value("HOME") {
                paths.append(POSIXPath.join(home, ".config", "git", "config"))
            }
        }
        if let system = value("GIT_CONFIG_SYSTEM") {
            paths.append(system)
        }
        // The bundled system configuration includes this one.
        paths.append("/etc/gitconfig")

        return paths.map { POSIXPath.resolve(repositoryPath, $0) }
    }

    // MARK: - Serialization

    private func acquire() async throws {
        try Task.checkCancellation()
        guard isBusy else {
            isBusy = true
            return
        }

        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append((id, continuation))
                eventHandler?(.queued)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
        noteActivity()
    }

    // MARK: - Idle shutdown

    private func noteActivity() {
        lastActivity = .now
        if idleTask == nil {
            idleTask = Task { await self.runIdleTimer() }
        }
    }

    private func runIdleTimer() async {
        while true {
            let deadline = (isBusy ? ContinuousClock.now : lastActivity) + idleTimeout
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            if !isBusy, waiters.isEmpty, ContinuousClock.now - lastActivity >= idleTimeout {
                idleTask = nil
                shutDown()
                // Rediscover if this reader is used again.
                discovery = nil
                if let key {
                    Self.unregister(self, key: key)
                }
                eventHandler?(.idleShutdown)
                return
            }
        }
    }
}

// MARK: - The shared registry

extension GitObjectReader {
    /// Identifies a shared reader: the repository, and the git and
    /// environment its processes run with.
    struct Key: Hashable, Sendable {
        let repositoryPath: String
        let gitDirectory: String
        let environment: [String: String]
    }

    private static let registry = Mutex<[Key: GitObjectReader]>([:])

    /// The shared reader for `repository`, running git from the current
    /// `GitRuntime`.
    public static func shared(for repository: Repository) -> GitObjectReader {
        shared(for: repository, idleTimeout: defaultIdleTimeout)
    }

    /// The shared reader, created with `idleTimeout` if there is none yet.
    static func shared(for repository: Repository, idleTimeout: Duration) -> GitObjectReader {
        let runtime = GitRuntime.current
        let key = Key(
            repositoryPath: repository.path,
            gitDirectory: runtime.gitDirectory.path(percentEncoded: false),
            environment: runtime.processEnvironment
        )
        return registry.withLock { readers in
            if let reader = readers[key] {
                return reader
            }
            let reader = GitObjectReader(
                repositoryPath: repository.path,
                runtime: runtime,
                idleTimeout: idleTimeout,
                key: key
            )
            readers[key] = reader
            return reader
        }
    }

    private static func unregister(_ reader: GitObjectReader, key: Key) {
        registry.withLock { readers in
            if readers[key] === reader {
                readers[key] = nil
            }
        }
    }
}

// MARK: - Equivalence with git show

extension GitObjectReader {
    /// The outcome of trying to answer `git show <name>` from the reader.
    enum ShowAttempt: Sendable {
        /// The blob's contents, exactly what `git show` would print.
        case blob(Data)
        /// Run `git show`. If it exits with 0 and a state is given, report
        /// it with `showSucceeded(in:)`.
        case runShow(validating: RepositoryState?)
    }

    /// Answers `git show <name>` for a blob when the answer is provably the
    /// same bytes `git show` prints.
    ///
    /// `git show` streams a blob with the same function cat-file uses
    /// (`stream_blob_to_fd`): no textconv (only with `--textconv`), no
    /// filters, no end-of-line or encoding conversion, and no hash check. It
    /// differs from cat-file in three ways, all handled here:
    ///
    /// 1. It parses log, diff, color, and format configuration, and exits
    ///    with 128 on a bad value (`log.date=bogus`), which cat-file never
    ///    reads. So the reader only answers after a `git show` has
    ///    succeeded in the same repository state; until then callers run
    ///    `git show` and report success with `showSucceeded(in:)`.
    /// 2. It treats `..`, `^@`, `^!`, `^-`, and `@{` as revision syntax
    ///    anywhere in its argument; such names go to git.
    /// 3. It refuses an argument that also names a file in the working
    ///    directory ("ambiguous argument"); such names go to git.
    func attemptShow(_ name: String, limit: Int?) async throws -> ShowAttempt {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()

        guard let context = try await currentContext() else {
            return .runShow(validating: nil)
        }
        guard showValidatedState == context.state else {
            return .runShow(validating: context.state)
        }
        guard Self.isFreshName(name, objectIDLength: context.objectIDLength),
              Self.showResolvesLikeCatFile(name, repositoryPath: repositoryPath),
              let response = try await performRead(name, limit: limit, state: context.state),
              case .object(let object) = response,
              object.type == "blob"
        else {
            return .runShow(validating: nil)
        }
        return .blob(object.contents)
    }

    /// Records that `git show` exited with 0 in `state`.
    func showSucceeded(in state: RepositoryState) {
        showValidatedState = state
    }

    /// Whether `git show <name>`, run in `repositoryPath`, takes `name` as a
    /// single object name, as cat-file does. See `attemptShow`.
    static func showResolvesLikeCatFile(_ name: String, repositoryPath: String) -> Bool {
        // handle_revision_arg: ranges, parent shorthands, and reflog syntax.
        for marker in ["..", "^@", "^!", "^-", "@{"] where JSCompat.includes(name, marker) {
            return false
        }

        // verify_non_filename: a file of that name makes the argument
        // ambiguous. Git looks it up relative to its working directory, and
        // treats any error but "missing" as fatal.
        var info = stat()
        if lstat(repositoryPath + "/" + name, &info) == 0 {
            return false
        }
        return errno == ENOENT || errno == ENOTDIR
    }
}

// MARK: - Repository state fingerprint

/// A fingerprint of the files whose contents a git process reads only once,
/// taken with `stat`. Two fingerprints are equal only if none of the files
/// was created, removed, or written in between.
struct RepositoryState: Hashable, Sendable {
    private let stamps: [FileStamp]

    init(paths: [String]) {
        stamps = paths.map(FileStamp.init(path:))
    }
}

private enum FileStamp: Hashable, Sendable {
    case absent
    case unreadable(errno: Int32)
    case present(
        device: Int64,
        inode: UInt64,
        mode: UInt32,
        size: Int64,
        modified: Int,
        modifiedNanoseconds: Int,
        changed: Int,
        changedNanoseconds: Int
    )

    init(path: String) {
        var info = stat()
        if stat(path, &info) == 0 {
            self = .present(
                device: Int64(info.st_dev),
                inode: UInt64(info.st_ino),
                mode: UInt32(info.st_mode),
                size: Int64(info.st_size),
                modified: info.st_mtimespec.tv_sec,
                modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changed: info.st_ctimespec.tv_sec,
                changedNanoseconds: info.st_ctimespec.tv_nsec
            )
        } else if errno == ENOENT || errno == ENOTDIR {
            self = .absent
        } else {
            self = .unreadable(errno: errno)
        }
    }
}

// MARK: - The process

/// A running `git cat-file --batch` and its buffered output.
private final class Session: Sendable {
    let child: ChildProcess
    let output: BatchOutput
    /// The repository state when the process started.
    let state: RepositoryState

    private init(child: ChildProcess, output: BatchOutput, state: RepositoryState) {
        self.child = child
        self.output = output
        self.state = state
    }

    deinit {
        terminate()
    }

    var isAlive: Bool {
        !output.isClosed
    }

    static func start(repositoryPath: String, runtime: GitRuntime, state: RepositoryState) -> Session? {
        let output = BatchOutput()
        let child: ChildProcess
        do {
            child = try Dugite.spawn(
                ["cat-file", "--batch=%(objectname) %(objecttype) %(objectsize)"],
                repositoryPath,
                env: GitObjectReader.environmentOverrides,
                pipesStandardInput: true,
                runtime: runtime
            )
        } catch {
            logger.error("Could not start cat-file: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        child.observeStandardOutput { output.append($0) }
        // Standard error is read and dropped, so cat-file never blocks on it.
        child.startReading()
        Task.detached {
            _ = await child.waitUntilExit()
            output.close()
        }

        return Session(child: child, output: output, state: state)
    }

    /// Sends one object name. False if it couldn't be written.
    func send(_ name: String) async -> Bool {
        do {
            try await child.writeToStandardInput(Data((name + "\n").utf8))
            return true
        } catch {
            return false
        }
    }

    /// Stops the process at once. cat-file holds no locks and writes no
    /// files, so there's nothing to clean up, and SIGKILL also ends a process
    /// that is stopped or stuck.
    func terminate() {
        output.close()
        child.closeStandardInput()
        child.terminate(signal: SIGKILL)
    }
}

/// cat-file's standard output, buffered so that a reader can wait for a line
/// or for a number of bytes. One read at a time.
final class BatchOutput: Sendable {
    enum ReadResult: Sendable {
        case data(Data)
        /// The process exited (or was discarded) before enough output arrived,
        /// or the output can't be a response.
        case closed
        /// The waiting task was cancelled.
        case cancelled
    }

    private enum Need: Sendable {
        case line(maxLength: Int)
        case bytes(Int)
    }

    private struct State {
        var buffer = Data()
        var offset = 0
        var isClosed = false
        var waiter: (need: Need, continuation: CheckedContinuation<ReadResult, Never>)?

        mutating func take(_ need: Need) -> ReadResult? {
            let available = buffer.count - offset
            let start = buffer.startIndex + offset
            switch need {
            case .line(let maxLength):
                let searchEnd = start + min(available, maxLength + 1)
                if let newline = buffer[start..<searchEnd].firstIndex(of: 0x0A) {
                    let line = Data(buffer[start..<newline])
                    consume(newline - start + 1)
                    return .data(line)
                }
                if available > maxLength {
                    // No line break where a response's header must end.
                    return .closed
                }
            case .bytes(let count):
                if available >= count {
                    let data = Data(buffer[start..<start + count])
                    consume(count)
                    return .data(data)
                }
            }
            return isClosed ? .closed : nil
        }

        private mutating func consume(_ count: Int) {
            offset += count
            if offset == buffer.count {
                buffer.removeAll(keepingCapacity: buffer.count <= 1 << 20)
                offset = 0
            } else if offset >= 1 << 20 {
                buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + offset)
                offset = 0
            }
        }
    }

    private let state = Mutex(State())

    var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    func append(_ data: Data) {
        let resumption = state.withLock { state -> (CheckedContinuation<ReadResult, Never>, ReadResult)? in
            guard !state.isClosed else {
                return nil
            }
            state.buffer.append(data)
            guard let waiter = state.waiter, let result = state.take(waiter.need) else {
                return nil
            }
            state.waiter = nil
            return (waiter.continuation, result)
        }
        if let (continuation, result) = resumption {
            continuation.resume(returning: result)
        }
    }

    /// No more output will arrive. What's buffered can still be read.
    func close() {
        let resumption = state.withLock { state -> (CheckedContinuation<ReadResult, Never>, ReadResult)? in
            state.isClosed = true
            guard let waiter = state.waiter else {
                return nil
            }
            state.waiter = nil
            return (waiter.continuation, state.take(waiter.need) ?? .closed)
        }
        if let (continuation, result) = resumption {
            continuation.resume(returning: result)
        }
    }

    /// The next line, without its line break.
    func readLine(maxLength: Int) async -> ReadResult {
        await read(.line(maxLength: maxLength))
    }

    /// Exactly `count` bytes.
    func readBytes(_ count: Int) async -> ReadResult {
        await read(.bytes(count))
    }

    private func read(_ need: Need) async -> ReadResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ReadResult, Never>) in
                let immediate = state.withLock { state -> ReadResult? in
                    if Task.isCancelled {
                        return .cancelled
                    }
                    if let result = state.take(need) {
                        return result
                    }
                    precondition(state.waiter == nil, "BatchOutput serves one read at a time")
                    state.waiter = (need, continuation)
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<ReadResult, Never>? in
                defer { state.waiter = nil }
                return state.waiter?.continuation
            }
            continuation?.resume(returning: .cancelled)
        }
    }
}
