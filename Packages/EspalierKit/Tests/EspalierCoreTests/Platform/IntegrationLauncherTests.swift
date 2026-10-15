@testable import EspalierCore
import EspalierSupport
import Foundation
import GitKit
import Synchronization
import Testing
import TestSupport

/// These run `/bin/sh`, never an application.
@Suite("Integration launcher")
struct IntegrationLauncherTests {
    /// What a traced process reported.
    private final class Trace: Sendable {
        private let standardError = Mutex(Data())
        private let exits: AsyncStream<ChildProcess.Termination>
        private let exitContinuation: AsyncStream<ChildProcess.Termination>.Continuation

        init() {
            (exits, exitContinuation) = AsyncStream.makeStream()
        }

        var tracing: LaunchTracing {
            LaunchTracing(
                onStandardError: { data in self.standardError.withLock { $0.append(data) } },
                onExit: { termination in
                    self.exitContinuation.yield(termination)
                    self.exitContinuation.finish()
                }
            )
        }

        /// Waits for the process to exit; all of its output has arrived by then.
        func termination() async -> ChildProcess.Termination? {
            for await termination in exits {
                return termination
            }
            return nil
        }

        var standardErrorText: String {
            standardError.withLock { String(decoding: $0, as: UTF8.self) }
        }
    }

    private let environment = ["PATH": "/usr/bin:/bin"]

    private func shell(_ script: String, isDetached: Bool = false) -> LaunchCommand {
        LaunchCommand(executable: "/bin/sh", arguments: ["-c", script], isDetached: isDetached)
    }

    @Test("starts a process and traces its standard error and exit")
    func traces() async throws {
        let trace = Trace()
        try ChildProcessLauncher(environment: environment).spawn(shell("printf oops >&2; exit 3"), tracing: trace.tracing)

        #expect(await trace.termination() == .exit(3))
        #expect(trace.standardErrorText == "oops")
    }

    @Test("ignores a detached process's output but traces its exit")
    func detached() async throws {
        let trace = Trace()
        // Exits with 0 only if all three standard streams are /dev/null.
        try ChildProcessLauncher(environment: environment).spawn(
            shell(
                "printf oops >&2; printf out; [ /dev/fd/0 -ef /dev/null ] && [ /dev/fd/1 -ef /dev/null ] && [ /dev/fd/2 -ef /dev/null ]",
                isDetached: true
            ),
            tracing: trace.tracing
        )

        #expect(await trace.termination() == .exit(0))
        #expect(trace.standardErrorText == "")
    }

    @Test("passes its environment")
    func environmentIsPassed() async throws {
        let trace = Trace()
        try ChildProcessLauncher(environment: ["GREETING": "hello"]).spawn(
            shell(#"printf "$GREETING" >&2"#),
            tracing: trace.tracing
        )

        #expect(await trace.termination() == .exit(0))
        #expect(trace.standardErrorText == "hello")
    }

    @Test("uses the git runtime's process environment by default")
    func defaultEnvironment() async throws {
        let trace = Trace()
        var runtime = GitRuntime.current
        runtime.processEnvironment = ["GREETING": "from the runtime"]
        try await GitRuntime.withRuntime(runtime) {
            try ChildProcessLauncher().spawn(shell(#"printf "$GREETING" >&2"#), tracing: trace.tracing)
        }

        #expect(await trace.termination() == .exit(0))
        #expect(trace.standardErrorText == "from the runtime")
    }

    @Test("reports an executable that doesn't exist")
    func missingExecutable() throws {
        let directory = try createTempDirectory()
        let error = #expect(throws: SpawnError.self) {
            try ChildProcessLauncher(environment: environment).spawn(
                LaunchCommand(executable: "\(directory)/missing", arguments: [], isDetached: true),
                tracing: nil
            )
        }
        #expect(error == SpawnError(path: "\(directory)/missing", code: "ENOENT"))
    }

    @Test("reports a file or folder it may not execute as Node does")
    func notExecutable() throws {
        let directory = try createTempDirectory()
        try makeFile("\(directory)/notes", permissions: 0o644)
        try FileManager.default.createDirectory(atPath: "\(directory)/folder", withIntermediateDirectories: true)

        for path in ["\(directory)/notes", "\(directory)/folder"] {
            for isDetached in [true, false] {
                let error = #expect(throws: SpawnError.self) {
                    try ChildProcessLauncher(environment: environment).spawn(
                        LaunchCommand(executable: path, arguments: [], isDetached: isDetached),
                        tracing: nil
                    )
                }
                #expect(error == SpawnError(path: path, code: "EACCES"))
            }
        }
    }

    @Suite("Launch Services locator")
    struct Locator {
        @Test("returns an application's path without a trailing slash")
        func terminal() throws {
            // Terminal ships with macOS.
            let path = try #require(LaunchServicesApplicationLocator().appPath("com.apple.Terminal"))
            #expect(path.hasSuffix("/Terminal.app"))
        }
    }
}
