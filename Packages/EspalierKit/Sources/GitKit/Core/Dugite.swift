// Ported from dugite/lib/git-environment.ts, dugite/lib/exec.ts,
// dugite/lib/spawn.ts, dugite/lib/env-map.ts, and
// dugite/lib/ignore-closed-input-stream.ts

import EspalierSupport
import Foundation
import Synchronization

/// Runs the bundled git in its environment, with none of `git()`'s hooks,
/// trampoline, or error handling.
///
/// Almost everything should call `git(_:_:_:options:)` instead. `Dugite` is
/// called directly only where going through `git()` would recurse (finding
/// hooks, reading git's version) and in tests.
public enum Dugite {
    /// The result of shelling out to git.
    public struct Result: Sendable {
        /// The standard output from git.
        public let stdout: Data
        /// The standard error output from git.
        public let stderr: Data
        /// The exit code of the git process.
        public let exitCode: Int

        public init(stdout: Data, stderr: Data, exitCode: Int) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
        }
    }

    /// A set of configuration options that can be passed when executing a
    /// git command.
    public struct ExecutionOptions: Sendable {
        /// Environment variables to set before executing git. A `nil` value
        /// removes the variable.
        public var env: [String: String?]

        /// Written to the child's standard input immediately after spawning
        /// it, then closed. Without it, standard input reads `/dev/null`.
        public var stdin: Data?

        /// Largest number of bytes allowed on stdout or stderr. If exceeded,
        /// the child process is terminated and the output is truncated.
        /// `nil` means no limit.
        public var maxBuffer: Int?

        /// Invoked with the child process right after spawning it, before any
        /// output is read, so observers registered here see every chunk.
        public var processCallback: (@Sendable (ChildProcess) -> Void)?

        /// The signal sent to the child when the calling task is cancelled.
        /// Defaults to `SIGTERM`.
        public var killSignal: Int32

        /// Whether cancelling sends `killSignal` to the child's whole process
        /// group (the helpers git started too) rather than only to the child.
        public var killsProcessGroup: Bool

        /// Whether git gets the runtime's `defaultLocale` when its
        /// environment has no locale.
        public var addsDefaultLocale: Bool

        public init(
            env: [String: String?] = [:],
            stdin: Data? = nil,
            maxBuffer: Int? = nil,
            processCallback: (@Sendable (ChildProcess) -> Void)? = nil,
            killSignal: Int32 = SIGTERM,
            killsProcessGroup: Bool = false,
            addsDefaultLocale: Bool = true
        ) {
            self.env = env
            self.stdin = stdin
            self.maxBuffer = maxBuffer
            self.processCallback = processCallback
            self.killSignal = killSignal
            self.killsProcessGroup = killsProcessGroup
            self.addsDefaultLocale = addsDefaultLocale
        }
    }
}

/// Git could not be executed, its output exceeded `maxBuffer`, or a signal
/// terminated it.
public struct ExecError: Error, CustomStringConvertible, LocalizedError {
    /// The code identifying the kind of error, such as `ENOENT` or
    /// `ERR_CHILD_PROCESS_STDIO_MAXBUFFER`.
    public static let maxBufferExceededCode = "ERR_CHILD_PROCESS_STDIO_MAXBUFFER"

    public let message: String
    public let stdout: Data
    public let stderr: Data
    /// A string label identifying the kind of error, when known.
    public let code: String?
    /// The signal that terminated the process, if one did.
    public let signal: Int32?

    public init(message: String, stdout: Data = Data(), stderr: Data = Data(), code: String? = nil, signal: Int32? = nil) {
        self.message = message
        self.stdout = stdout
        self.stderr = stderr
        self.code = code
        self.signal = signal
    }

    public var isMaxBufferExceeded: Bool { code == Self.maxBufferExceededCode }
    public var description: String { message }
    public var errorDescription: String? { message }
}

// MARK: - Environment

extension Dugite {
    /// Find the path to the embedded git environment.
    public static func resolveGitDir(_ runtime: GitRuntime = .current) -> URL {
        runtime.gitDirectory
    }

    /// Find the path to the embedded git binary.
    public static func resolveGitBinary(_ runtime: GitRuntime = .current) -> URL {
        runtime.gitBinary
    }

    /// Find the path to the embedded git exec path.
    ///
    /// If a custom git exec path is given as the `GIT_EXEC_PATH` environment
    /// variable, then it returns with it after resolving it as a path.
    public static func resolveGitExecPath(gitDir: URL, gitExecPath: String?) -> String {
        if let gitExecPath, !gitExecPath.isEmpty {
            return POSIXPath.resolve(gitExecPath)
        }
        return gitDir.appending(path: "libexec/git-core").path(percentEncoded: false)
    }

    /// Setup the process environment before invoking git.
    ///
    /// Merges `environmentVariables` over `processEnv` (a `nil` value removes
    /// the variable), sets `LC_CTYPE` to `defaultLocale` when the result has
    /// no locale, then points git at the bundled distribution: its exec
    /// path, its own system-level gitconfig (unless `GIT_CONFIG_SYSTEM` is
    /// already set), and its templates for `git init`.
    public static func setupEnvironment(
        _ environmentVariables: [String: String?],
        processEnv: [String: String],
        gitDir: URL,
        defaultLocale: String? = nil
    ) -> (env: [String: String], gitLocation: URL) {
        var env = processEnv
        for (key, value) in environmentVariables {
            env[key] = value
        }

        // Without a locale, git and every program it runs work in ASCII:
        // Ruby in a hook reads files as US-ASCII, gpg reads its arguments as
        // Latin-1, and ssh-keygen escapes non-ASCII paths. `LC_CTYPE` sets
        // only the character set, so no program's messages change language:
        // `parseSigningFailure` reads gpg's.
        if let defaultLocale, !["LANG", "LC_ALL", "LC_CTYPE"].contains(where: { !(env[$0]?.isEmpty ?? true) }) {
            env["LC_CTYPE"] = defaultLocale
        }

        env["GIT_EXEC_PATH"] = resolveGitExecPath(gitDir: gitDir, gitExecPath: env["GIT_EXEC_PATH"])

        // On macOS /etc/gitconfig is the system-wide configuration file and we
        // can't modify it. To provide our own sane defaults that the user's
        // global and local configuration can override, git uses
        // desktop's git build's custom gitconfig, which includes /etc/gitconfig.
        if env["GIT_CONFIG_SYSTEM"]?.isEmpty ?? true {
            env["GIT_CONFIG_SYSTEM"] = gitDir.appending(path: "etc/gitconfig").path(percentEncoded: false)
        }

        // Templates are used to populate your .git folder when a repository
        // is initialized locally.
        env["GIT_TEMPLATE_DIR"] = gitDir.appending(path: "share/git-core/templates").path(percentEncoded: false)

        return (env, gitDir.appending(path: "bin/git"))
    }
}

// MARK: - exec and spawn

extension Dugite {
    /// Execute a command and read the output using the embedded git
    /// environment.
    ///
    /// Throws `ExecError` when git fails to launch (with a POSIX `code`),
    /// exceeds `maxBuffer`, or is killed by a signal, and `CancellationError`
    /// when the calling task is cancelled (git receives `killSignal`). Check
    /// the result's `stderr` and `exitCode` for git's own errors.
    public static func exec(
        _ args: [String],
        _ path: String,
        options: ExecutionOptions = ExecutionOptions(),
        runtime: GitRuntime = .current
    ) async throws -> Result {
        let (env, gitLocation) = setupEnvironment(
            options.env,
            processEnv: runtime.processEnvironment,
            gitDir: runtime.gitDirectory,
            defaultLocale: options.addsDefaultLocale ? runtime.defaultLocale : nil
        )

        let child: ChildProcess
        do {
            child = try ChildProcess(ChildProcess.Configuration(
                executablePath: gitLocation.path(percentEncoded: false),
                arguments: args,
                environment: env,
                currentDirectoryPath: path,
                pipesStandardInput: options.stdin != nil
            ))
        } catch {
            throw launchError(error, args: args)
        }

        let output = OutputCollector(maxBuffer: options.maxBuffer) { [weak child] in
            child?.terminate(signal: options.killSignal)
        }
        child.observeStandardOutput { output.append($0, to: .stdout) }
        child.observeStandardError { output.append($0, to: .stderr) }
        options.processCallback?(child)
        child.startReading()

        let termination = await withTaskCancellationHandler {
            if let stdin = options.stdin {
                // A child that exits without reading all of its input is not
                // an error here; its exit code reports what went wrong.
                try? await child.writeToStandardInput(stdin)
                child.closeStandardInput()
            }
            return await child.waitUntilExit()
        } onCancel: {
            // One signal for the whole group: signalling git first could let
            // it be reaped before the group is signalled, and a reaped
            // child's group is never signalled, so its helpers would live on.
            if options.killsProcessGroup {
                child.terminateProcessGroup(signal: options.killSignal)
            } else {
                child.terminate(signal: options.killSignal)
            }
        }

        let (stdout, stderr, exceeded) = output.snapshot()

        if Task.isCancelled {
            throw CancellationError()
        }

        if let exceeded {
            throw ExecError(
                message: "\(exceeded == .stdout ? "stdout" : "stderr") maxBuffer length exceeded",
                stdout: stdout,
                stderr: stderr,
                code: ExecError.maxBufferExceededCode
            )
        }

        switch termination {
        case .exit(let status):
            return Result(stdout: stdout, stderr: stderr, exitCode: Int(status))
        case .signal(let signal):
            throw ExecError(
                message: "Command failed: git \(args.joined(separator: " ")) (killed by signal \(signal))",
                stdout: stdout,
                stderr: stderr,
                signal: signal
            )
        }
    }

    /// Execute a command and interact with the process outputs directly.
    ///
    /// Output isn't read until you call `startReading()` or
    /// `waitUntilExit()`, so register observers first.
    public static func spawn(
        _ args: [String],
        _ path: String,
        env: [String: String?] = [:],
        pipesStandardInput: Bool = false,
        runtime: GitRuntime = .current
    ) throws -> ChildProcess {
        let (environment, gitLocation) = setupEnvironment(
            env,
            processEnv: runtime.processEnvironment,
            gitDir: runtime.gitDirectory,
            defaultLocale: runtime.defaultLocale
        )
        do {
            return try ChildProcess(ChildProcess.Configuration(
                executablePath: gitLocation.path(percentEncoded: false),
                arguments: args,
                environment: environment,
                currentDirectoryPath: path,
                pipesStandardInput: pipesStandardInput
            ))
        } catch {
            throw launchError(error, args: args)
        }
    }

    private static func launchError(_ error: ChildProcess.LaunchError, args: [String]) -> ExecError {
        var message = error.description
        if error.code == "ENOENT" {
            message =
                "ENOENT: Git failed to execute. This typically means that "
                + "the path provided doesn't exist or that the Git executable "
                + "could not be found which could indicate a problem with the "
                + "packaging of Espalier. Verify that the bundled git exists "
                + "at Contents/Resources/git."
        }
        return ExecError(message: message, code: error.code)
    }
}

/// Collects a child's output, enforcing `maxBuffer`: each stream is capped
/// separately, and exceeding it truncates that stream and terminates the
/// process.
private final class OutputCollector: Sendable {
    enum Stream { case stdout, stderr }

    private struct State {
        var stdout = Data()
        var stderr = Data()
        var exceeded: Stream?
    }

    private let state = Mutex(State())
    private let maxBuffer: Int?
    private let onExceeded: @Sendable () -> Void

    init(maxBuffer: Int?, onExceeded: @escaping @Sendable () -> Void) {
        self.maxBuffer = maxBuffer
        self.onExceeded = onExceeded
    }

    func append(_ chunk: Data, to stream: Stream) {
        let justExceeded = state.withLock { state -> Bool in
            guard state.exceeded == nil else { return false }
            let current = stream == .stdout ? state.stdout.count : state.stderr.count
            var accepted = chunk
            if let maxBuffer, current + chunk.count > maxBuffer {
                accepted = chunk.prefix(max(0, maxBuffer - current))
                state.exceeded = stream
            }
            switch stream {
            case .stdout: state.stdout.append(accepted)
            case .stderr: state.stderr.append(accepted)
            }
            return state.exceeded != nil
        }
        if justExceeded {
            onExceeded()
        }
    }

    /// The collected output, and the stream that exceeded `maxBuffer`, if any.
    func snapshot() -> (stdout: Data, stderr: Data, exceeded: Stream?) {
        state.withLock { ($0.stdout, $0.stderr, $0.exceeded) }
    }
}
