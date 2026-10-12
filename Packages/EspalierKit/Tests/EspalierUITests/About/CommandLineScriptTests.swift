// The command line tool's arguments (Espalier/espalier.sh): options anywhere
// and in each of minimist's forms, `--`, help, and what it opens. The script
// runs for real with ESPALIER_CLI_DRY_RUN, which prints the `open` command
// instead of running it, one run at a time, without the developer's zsh
// startup files.

import EspalierSupport
import Foundation
import Synchronization
import Testing
import TestSupport

@Suite("Command line script", .serialized, .hangGuard(minutes: 5))
struct CommandLineScriptTests {
    /// Espalier/espalier.sh in this checkout.
    private static let script: String = {
        var path = POSIXPath.dirname(#filePath)
        while path != "/", !FileManager.default.fileExists(atPath: POSIXPath.join(path, "Espalier", "espalier.sh")) {
            path = POSIXPath.dirname(path)
        }
        return POSIXPath.join(path, "Espalier", "espalier.sh")
    }()

    /// The bundle the script opens: three folders up from it.
    private static var app: String {
        POSIXPath.dirname(POSIXPath.dirname(POSIXPath.dirname(script)))
    }

    private struct Output {
        let status: Int32
        /// What `open` would have been run with, one argument per line.
        let stdout: [String]
        let stderr: String
    }

    private func run(_ arguments: [String], in directory: String? = nil) async throws -> Output {
        final class Buffer: Sendable {
            let data = Mutex(Data())
        }
        let stdout = Buffer()
        let stderr = Buffer()
        let child = try ChildProcess(ChildProcess.Configuration(
            executablePath: "/bin/zsh",
            // -f: no startup files (the developer's ~/.zshenv).
            arguments: ["-f", Self.script] + arguments,
            environment: ["PATH": "/usr/bin:/bin", "ESPALIER_CLI_DRY_RUN": "1", "HOME": NSTemporaryDirectory()],
            currentDirectoryPath: directory
        ))
        child.observeStandardOutput { chunk in stdout.data.withLock { $0.append(chunk) } }
        child.observeStandardError { chunk in stderr.data.withLock { $0.append(chunk) } }
        child.startReading()
        let termination = await child.waitUntilExit()
        let status: Int32 = switch termination {
        case .exit(let code): code
        case .signal: -1
        }
        let text = String(decoding: stdout.data.withLock { $0 }, as: UTF8.self)
        return Output(
            status: status,
            stdout: text.split(separator: "\n").map(String.init),
            stderr: String(decoding: stderr.data.withLock { $0 }, as: UTF8.self)
        )
    }

    @Test("clone takes -b and --branch in every form, before or after the URL", arguments: [
        ["clone", "-b", "main", "owner/name"],
        ["clone", "owner/name", "-b", "main"],
        ["clone", "--branch", "main", "owner/name"],
        ["clone", "--branch=main", "owner/name"],
        ["clone", "-bmain", "owner/name"],
        ["-b", "main", "clone", "owner/name"],
    ])
    func cloneBranch(_ arguments: [String]) async throws {
        let output = try await run(arguments)
        #expect(output.status == 0, "\(output.stderr)")
        #expect(output.stdout == ["open", "-a", Self.app, "espalier://openRepo/https://github.com/owner/name?branch=main"])
    }

    @Test("clone: a URL as given, a branch encoded, no branch without one")
    func cloneURL() async throws {
        let plain = try await run(["clone", "https://example.com/team/app.git"])
        #expect(plain.stdout == ["open", "-a", Self.app, "espalier://openRepo/https://example.com/team/app.git"])
        let encoded = try await run(["clone", "owner/name", "-b", "feature/x y"])
        #expect(encoded.stdout.last == "espalier://openRepo/https://github.com/owner/name?branch=feature%2Fx%20y")
    }

    @Test("-h and --help anywhere, and help, open nothing and succeed", arguments: [
        ["-h"], ["help"], ["clone", "owner/name", "-h"], ["open", "--help"],
    ])
    func help(_ arguments: [String]) async throws {
        let output = try await run(arguments)
        #expect(output.status == 0)
        #expect(output.stdout.isEmpty)
    }

    @Test("a missing URL or branch, an extra word, or an unknown option is an error", arguments: [
        ["clone"], ["clone", "owner/name", "-b"], ["clone", "-x", "owner/name"], ["open", "a", "b"],
    ])
    func errors(_ arguments: [String]) async throws {
        let output = try await run(arguments)
        #expect(output.status == 1)
        #expect(output.stdout.isEmpty)
    }

    @Test("open, a bare path, and nothing open a folder by its absolute path; `--` ends the options")
    func open() async throws {
        let directory = try createTempDirectory()
        let folder = POSIXPath.join(directory, "-dash")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        // The script resolves symbolic links (/var is /private/var).
        let resolved = try #require(realpath(folder, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })

        #expect(try await run(["open", folder]).stdout == ["open", "-a", Self.app, resolved])
        // A relative path that looks like an option, after `--`.
        #expect(try await run(["--", "-dash"], in: directory).stdout == ["open", "-a", Self.app, resolved])
        #expect(try await run(["open", "--", "-dash"], in: directory).stdout == ["open", "-a", Self.app, resolved])
        #expect(try await run([], in: folder).stdout == ["open", "-a", Self.app, resolved])
        #expect(try await run(["open"], in: folder).stdout == ["open", "-a", Self.app, resolved])

        let missing = try await run(["open", POSIXPath.join(directory, "missing")])
        #expect(missing.status == 1)
    }
}
