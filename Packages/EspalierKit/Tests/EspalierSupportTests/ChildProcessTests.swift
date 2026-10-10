// Covers `ChildProcess`, which starts processes with `posix_spawn`.

import Darwin
import EspalierSupport
import Foundation
import Synchronization
import Testing
import TestSupport

@Suite("ChildProcess")
struct ChildProcessTests {
    /// How a process ended and what it wrote.
    struct Output {
        let termination: ChildProcess.Termination
        let stdout: Data
        let stderr: Data

        var text: String {
            String(decoding: stdout, as: UTF8.self)
        }
    }

    /// Runs a process to completion.
    static func run(
        _ executablePath: String,
        _ arguments: [String] = [],
        environment: [String: String] = ["PATH": "/usr/bin:/bin"],
        currentDirectoryPath: String? = nil
    ) async throws -> Output {
        final class Buffers: Sendable {
            let stdout = Mutex(Data())
            let stderr = Mutex(Data())
        }
        let buffers = Buffers()
        let child = try ChildProcess(ChildProcess.Configuration(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            currentDirectoryPath: currentDirectoryPath
        ))
        child.observeStandardOutput { chunk in buffers.stdout.withLock { $0.append(chunk) } }
        child.observeStandardError { chunk in buffers.stderr.withLock { $0.append(chunk) } }
        let termination = await child.waitUntilExit()
        return Output(
            termination: termination,
            stdout: buffers.stdout.withLock { $0 },
            stderr: buffers.stderr.withLock { $0 }
        )
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Polls `condition` for up to ten seconds.
    static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Whether `pid` has been reaped. Doesn't reap it (`WNOWAIT`).
    static func isReaped(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1 && errno == ECHILD
    }

    /// The signals the kernel says `pid` ignores.
    static func ignoredSignals(_ pid: pid_t) throws -> Set<Int32> {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        try #require(sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0)
        let ignored = info.kp_proc.p_sigignore
        return Set((1..<32).filter { ignored & (1 << ($0 - 1)) != 0 })
    }

    // MARK: - Bytes reach the child unchanged

    @Test("passes arguments byte for byte")
    func arguments() async throws {
        let arguments = [Cafe.precomposed, Cafe.decomposed, "a \(Cafe.precomposed) b", ""]
        let output = try await Self.run("/usr/bin/printf", ["%s\\0"] + arguments)

        let expected = Data(arguments.map { $0 + "\0" }.joined().utf8)
        #expect(output.termination == .exit(0))
        #expect(output.stdout == expected, "\(Self.hex(output.stdout)) != \(Self.hex(expected))")
    }

    @Test("passes exactly the configured environment, byte for byte")
    func environment() async throws {
        let environment = [
            "PRECOMPOSED": Cafe.precomposed,
            "DECOMPOSED": Cafe.decomposed,
            "KEY_\(Cafe.precomposed)": "value",
        ]
        let output = try await Self.run("/usr/bin/env", ["-0"], environment: environment)

        let entries = Set(output.stdout.split(separator: 0).map { Data($0) })
        #expect(entries == Set(environment.map { Data("\($0.key)=\($0.value)".utf8) }))

        let empty = try await Self.run("/usr/bin/env", ["-0"], environment: [:])
        #expect(empty.stdout.isEmpty, "inherited \(empty.text)")
    }

    @Test("runs the child in its working directory", arguments: [Cafe.precomposed, Cafe.decomposed])
    func workingDirectory(_ name: String) async throws {
        let directory = try createTempDirectory() + "/" + name
        try #require(mkdir(directory, 0o700) == 0)

        let output = try await Self.run("/bin/pwd", ["-P"], currentDirectoryPath: directory)
        #expect(output.stdout == Data((directory + "\n").utf8), "\(Self.hex(output.stdout))")
    }

    @Test("passes a working directory and an executable path that only fit undecomposed")
    func longPaths() async throws {
        // APFS finds a directory by either spelling, so a decomposed path
        // only shows when it no longer fits in PATH_MAX.
        let long = try LongPrecomposedPath()
        defer { long.remove() }
        try #require(long.byteCounts.precomposed < Int(PATH_MAX) - 32)
        try #require(long.byteCounts.decomposed > Int(PATH_MAX))
        let pwd = try long.link(named: "pwd", to: "/bin/pwd")

        let output = try await Self.run(pwd, ["-P"], currentDirectoryPath: long.path)
        #expect(output.termination == .exit(0))
        #expect(output.stdout == Data((long.path + "\n").utf8))
    }

    // MARK: - Standard streams and descriptors

    @Test("reads standard input from /dev/null and leaves the child no other descriptors")
    func descriptors() async throws {
        // An inheritable descriptor, so that there is something to leak.
        let inheritable = open("/dev/null", O_RDONLY)
        try #require(inheritable > STDERR_FILENO)
        defer { close(inheritable) }

        let output = try await Self.run("/bin/sh", ["-c", """
            [ /dev/fd/0 -ef /dev/null ] && echo "stdin is /dev/null"
            fd=3
            while [ $fd -lt 256 ]; do
              [ -e /dev/fd/$fd ] && echo "descriptor $fd is open"
              fd=$((fd + 1))
            done
            exit 0
            """])
        #expect(output.termination == .exit(0))
        #expect(output.text == "stdin is /dev/null\n")
    }

    @Test("pipes standard input in order and closes it")
    func standardInput() async throws {
        final class Buffer: Sendable {
            let data = Mutex(Data())
        }
        let stdout = Buffer()
        let child = try ChildProcess(ChildProcess.Configuration(executablePath: "/bin/cat", pipesStandardInput: true))
        child.observeStandardOutput { chunk in stdout.data.withLock { $0.append(chunk) } }
        child.startReading()
        let large = Data((0..<(3 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 % 253) })
        try await child.writeToStandardInput(Data("one ".utf8))
        try await child.writeToStandardInput(large)
        try await child.writeToStandardInput(Data(" two".utf8))
        child.closeStandardInput()

        #expect(await child.waitUntilExit() == .exit(0))
        #expect(stdout.data.withLock { $0 } == Data("one ".utf8) + large + Data(" two".utf8))
        await #expect(throws: (any Error).self) {
            try await child.writeToStandardInput(Data("late".utf8))
        }
    }

    @Test("writing to a child that has stopped reading is not an error")
    func writeAfterExit() async throws {
        let child = try ChildProcess(ChildProcess.Configuration(executablePath: "/usr/bin/true", pipesStandardInput: true))
        #expect(await child.waitUntilExit() == .exit(0))

        // EPIPE, not SIGPIPE, which would end the test process.
        try await child.writeToStandardInput(Data(count: 1024 * 1024))
        child.closeStandardInput()
    }

    @Test("waits for room in the pipe while the child doesn't read, then delivers everything in order", .hangGuard(minutes: 5))
    func standardInputLateReader() async throws {
        final class Buffer: Sendable {
            let data = Mutex(Data())
        }
        let stdout = Buffer()
        // Reads nothing at first, so the pipe fills long before the input ends.
        let child = try ChildProcess(ChildProcess.Configuration(
            executablePath: "/bin/sh",
            arguments: ["-c", "/bin/sleep 0.3; exec /bin/cat"],
            pipesStandardInput: true
        ))
        child.observeStandardOutput { chunk in stdout.data.withLock { $0.append(chunk) } }
        child.startReading()
        let large = Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 % 251) })
        try await child.writeToStandardInput(Data("first ".utf8))
        try await child.writeToStandardInput(large)
        try await child.writeToStandardInput(Data(" last".utf8))
        child.closeStandardInput()

        #expect(await child.waitUntilExit() == .exit(0))
        #expect(stdout.data.withLock { $0 } == Data("first ".utf8) + large + Data(" last".utf8))
    }

    @Test("a child that exits while a write waits for room ends the write, and later ones, without an error", .hangGuard(minutes: 5))
    func standardInputReaderExits() async throws {
        // Never reads: the write fills the pipe, then waits until the exit
        // closes the pipe's other end.
        let child = try ChildProcess(ChildProcess.Configuration(
            executablePath: "/bin/sh",
            arguments: ["-c", "/bin/sleep 0.3; exit 3"],
            pipesStandardInput: true
        ))
        child.startReading()
        try await child.writeToStandardInput(Data(count: 2 * 1024 * 1024))
        try await child.writeToStandardInput(Data("more".utf8))
        child.closeStandardInput()

        #expect(await child.waitUntilExit() == .exit(3))
    }

    @Test("a child that stops reading partway ends the write without an error", .hangGuard(minutes: 5))
    func standardInputReaderStops() async throws {
        final class Count: Sendable {
            let bytes = Mutex(0)
        }
        let stdout = Count()
        // Reads one megabyte in small blocks, then exits with the rest unread.
        let child = try ChildProcess(ChildProcess.Configuration(
            executablePath: "/bin/dd",
            arguments: ["bs=4096", "count=256", "iflag=fullblock"],
            pipesStandardInput: true
        ))
        child.observeStandardOutput { chunk in stdout.bytes.withLock { $0 += chunk.count } }
        child.startReading()
        try await child.writeToStandardInput(Data(count: 8 * 1024 * 1024))
        child.closeStandardInput()

        #expect(await child.waitUntilExit() == .exit(0))
        #expect(stdout.bytes.withLock { $0 } == 1024 * 1024)
    }

    // MARK: - Process groups and signals

    @Test("starts the child in a process group of its own, in Espalier's session")
    func processGroup() async throws {
        let child = try ChildProcess(ChildProcess.Configuration(executablePath: "/bin/cat", pipesStandardInput: true))
        let pid = child.processIdentifier

        #expect(getpgid(pid) == pid)
        #expect(getsid(pid) == getsid(0))

        child.closeStandardInput()
        #expect(await child.waitUntilExit() == .exit(0))
    }

    @Test("gives the child an empty signal mask")
    func signalMask() async throws {
        // Launch while this thread blocks SIGUSR1, restoring the mask before
        // any suspension point. The shell signals itself, which kills it
        // unless it inherited the blocked signal.
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGUSR1)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        let launched = Result { () throws(ChildProcess.LaunchError) in
            try ChildProcess(ChildProcess.Configuration(
                executablePath: "/bin/sh",
                arguments: ["-c", "kill -USR1 $$; echo survived"]
            ))
        }
        pthread_sigmask(SIG_SETMASK, &previous, nil)

        let child = try launched.get()
        #expect(await child.waitUntilExit() == .signal(SIGUSR1))
    }

    @Test("gives the child default signal dispositions")
    func signalDispositions() async throws {
        let child = try ChildProcess(ChildProcess.Configuration(executablePath: "/bin/cat", pipesStandardInput: true))

        // What every process ignores by default, and nothing Espalier ignores.
        let ignored = try Self.ignoredSignals(child.processIdentifier)
        #expect(ignored.isSubset(of: [SIGURG, SIGCHLD, SIGIO, SIGWINCH, SIGINFO]), "\(ignored.sorted())")

        child.closeStandardInput()
        #expect(await child.waitUntilExit() == .exit(0))
    }

    @Test("reports termination by a signal")
    func signalTermination() async throws {
        let selfTerminated = try await Self.run("/bin/sh", ["-c", "kill -TERM $$"])
        #expect(selfTerminated.termination == .signal(SIGTERM))

        let child = try ChildProcess(ChildProcess.Configuration(executablePath: "/bin/sleep", arguments: ["60"]))
        child.terminate(signal: SIGKILL)
        #expect(await child.waitUntilExit() == .signal(SIGKILL))
        // Does nothing once the child is gone.
        child.terminate()
    }

    @Test("terminates the child's process group, the processes it started too", .hangGuard(minutes: 5))
    func processGroupTermination() async throws {
        // The shell's background sleep holds a named pipe open for writing:
        // reading it reaches the end only once the sleep is gone.
        let pipe = try createTempDirectory() + "/held"
        try #require(mkfifo(pipe, 0o600) == 0)
        let child = try ChildProcess(ChildProcess.Configuration(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 600 > '\(pipe)' & wait"]
        ))
        // Opening for reading waits until the sleep has the pipe open.
        let descriptor = await Self.onThread { Darwin.open(pipe, O_RDONLY) }
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }

        child.terminateProcessGroup()

        #expect(await child.waitUntilExit() == .signal(SIGTERM))
        let count = await Self.onThread { () -> Int in
            var byte: UInt8 = 0
            return Darwin.read(descriptor, &byte, 1)
        }
        #expect(count == 0)
        // Does nothing once the child is gone.
        child.terminateProcessGroup()
    }

    /// Runs a blocking call on a thread of its own.
    static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: body())
            }
        }
    }

    // MARK: - Launch errors

    @Test("reports a missing executable or directory as ENOENT and one it may not run as EACCES")
    func launchErrors() throws {
        let directory = try createTempDirectory()
        let notes = directory + "/notes"
        try Data("not a program\n".utf8).write(to: URL(filePath: notes))
        try FileManager.default.createDirectory(atPath: directory + "/folder", withIntermediateDirectories: false)

        let cases = [
            (ChildProcess.Configuration(executablePath: directory + "/missing"), "ENOENT"),
            (ChildProcess.Configuration(executablePath: notes), "EACCES"),
            (ChildProcess.Configuration(executablePath: directory + "/folder"), "EACCES"),
            (ChildProcess.Configuration(executablePath: "/usr/bin/true", currentDirectoryPath: directory + "/missing"), "ENOENT"),
        ]
        for (configuration, code) in cases {
            let error = #expect(throws: ChildProcess.LaunchError.self) {
                try ChildProcess(configuration)
            }
            #expect(error?.code == code, "\(configuration.executablePath)")

            let detachedError = #expect(throws: ChildProcess.LaunchError.self) {
                try ChildProcess.spawnDetached(configuration)
            }
            #expect(detachedError?.code == code, "\(configuration.executablePath)")
        }
    }

    // MARK: - Reaping

    @Test("reaps the child, leaving no zombie")
    func reaping() async throws {
        let child = try ChildProcess(ChildProcess.Configuration(executablePath: "/bin/cat", pipesStandardInput: true))
        let pid = child.processIdentifier
        var status: Int32 = 0

        // Still running, so there is nothing to wait for.
        #expect(waitpid(pid, &status, WNOHANG) == 0)

        child.closeStandardInput()
        #expect(await child.waitUntilExit() == .exit(0))
        // Reaped already.
        #expect(waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("runs many children at once and reaps them all")
    func concurrency() async throws {
        let results = try await withThrowingTaskGroup(of: (Int, Output, pid_t).self) { group in
            for index in 0..<64 {
                group.addTask {
                    let child = try ChildProcess(ChildProcess.Configuration(
                        executablePath: "/bin/sh",
                        arguments: ["-c", "echo $1; echo $1 >&2; exit $(($1 % 3))", "sh", "\(index)"]
                    ))
                    final class Buffer: Sendable {
                        let data = Mutex(Data())
                    }
                    let stdout = Buffer()
                    child.observeStandardOutput { chunk in stdout.data.withLock { $0.append(chunk) } }
                    let termination = await child.waitUntilExit()
                    let output = Output(termination: termination, stdout: stdout.data.withLock { $0 }, stderr: Data())
                    return (index, output, child.processIdentifier)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.count == 64)
        for (index, output, pid) in results {
            #expect(output.termination == .exit(Int32(index % 3)))
            #expect(output.text == "\(index)\n")
            #expect(Self.isReaped(pid))
        }
    }

    @Test("reaps a child nobody waits for")
    func reapingUnobserved() async throws {
        var pid: pid_t = 0
        do {
            let child = try ChildProcess(ChildProcess.Configuration(executablePath: "/bin/sh", arguments: ["-c", "echo output; echo errors >&2"]))
            pid = child.processIdentifier
        }
        #expect(await Self.eventually { Self.isReaped(pid) })
    }

    // MARK: - Detached processes

    @Test("starts a detached child in a session of its own, with its standard streams on /dev/null")
    func detached() async throws {
        let marker = try createTempDirectory() + "/streams"
        let (exits, exited) = AsyncStream.makeStream(of: ChildProcess.Termination.self)
        let pid = try ChildProcess.spawnDetached(
            ChildProcess.Configuration(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    #"[ /dev/fd/0 -ef /dev/null ] && [ /dev/fd/1 -ef /dev/null ] && [ /dev/fd/2 -ef /dev/null ] && : > "$1"; exec /bin/sleep 60"#,
                    "sh",
                    marker,
                ],
                environment: ["PATH": "/usr/bin:/bin"],
                pipesStandardInput: true
            ),
            onExit: { termination in
                exited.yield(termination)
                exited.finish()
            }
        )

        #expect(getsid(pid) == pid)
        #expect(getpgid(pid) == pid)
        #expect(await Self.eventually { access(marker, F_OK) == 0 })

        kill(pid, SIGTERM)
        var terminations = exits.makeAsyncIterator()
        #expect(await terminations.next() == .signal(SIGTERM))
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("reports a detached child's exit status")
    func detachedExit() async throws {
        let (exits, exited) = AsyncStream.makeStream(of: ChildProcess.Termination.self)
        try ChildProcess.spawnDetached(
            ChildProcess.Configuration(executablePath: "/bin/sh", arguments: ["-c", "exit 7"]),
            onExit: { termination in
                exited.yield(termination)
                exited.finish()
            }
        )
        var terminations = exits.makeAsyncIterator()
        #expect(await terminations.next() == .exit(7))
    }
}
