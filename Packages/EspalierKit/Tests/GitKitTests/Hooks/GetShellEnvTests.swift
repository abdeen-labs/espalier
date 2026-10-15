// Ported from desktop/app/test/unit/get-shell-env-test.ts

import EspalierSupport
import Foundation
@testable import GitKit
import Testing
import TestSupport

@Suite("getShellEnv")
struct GetShellEnvTests {
    // The default shell is zsh, which runs here with an empty home directory,
    // so the developer's own shell and startup files stay out of the test.
    @Test("returns an env containing PATH (default shell)")
    func returnsEnvContainingPath() async throws {
        var runtime = TestEnvironment.runtime
        runtime.processEnvironment = ["SHELL": "/bin/zsh", "HOME": try createTempDirectory()]
        let result = try await GitRuntime.withRuntime(runtime) {
            try await getShellEnv(nil, printenvzPath: try getPrintenvzPath())
        }

        guard case .success(let env) = result else {
            Issue.record("Expected success but got \(result)")
            return
        }

        let pathKey = env.keys.first { $0.lowercased() == "path" }

        #expect(
            pathKey != nil,
            "Expected env to contain a PATH key but got keys: \(env.keys.joined(separator: ", "))"
        )
    }

    /// A stand-in replaces the login shell, so these don't depend on the
    /// developer's shell setup.
    @Suite("with a stand-in shell")
    struct StandInShell {
        /// The environment in `result`, which must be a success.
        func successEnv(_ result: ShellEnvResult) throws -> [String: String] {
            var env: [String: String]?
            if case .success(let value) = result {
                env = value
            }
            return try #require(env, "Expected success but got \(result)")
        }

        @Test("runs printenvz in the shell and ignores its startup output")
        func runsPrintenvz() async throws {
            let shell = try makeStandInShell(#"""
                [ "$1" = -ilc ] || exit 64
                echo 'Last login: today'
                printf 'motd=hello\0\n--printenvz--end\n'
                export ESPALIER_FROM_LOGIN='set by a startup file'
                eval "$2"
                """#)

            let env = try successEnv(try await withShell(shell) { try await getShellEnv() })

            #expect(env["ESPALIER_FROM_LOGIN"] == "set by a startup file")
            #expect(env["motd"] == nil)
        }

        @Test("quotes the printenvz path for the shell")
        func quotesPrintenvzPath() async throws {
            let directory = POSIXPath.join(try createTempDirectory(), "it's a $dir")
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            let printenvzPath = try getPrintenvzPath(in: directory)
            let shell = try makeStandInShell(#"""
                export ESPALIER_FROM_LOGIN=1
                eval "$2"
                """#)

            let env = try successEnv(try await withShell(shell) {
                try await getShellEnv(printenvzPath: printenvzPath)
            })

            #expect(env["ESPALIER_FROM_LOGIN"] == "1")
        }

        @Test("starts the shell as a terminal does: the login session's variables and launchd's PATH")
        func sessionEnvironment() async throws {
            // Not with an empty environment, which a terminal never has.
            let shell = try makeStandInShell(#"""
                echo "$PATH" > "$TMPDIR/start-path"
                eval "$2"
                """#)
            let tmp = try createTempDirectory()
            var runtime = TestEnvironment.runtime
            runtime.processEnvironment = [
                "SHELL": shell,
                "HOME": "/Users/joe",
                "USER": "joe",
                "LOGNAME": "joe",
                "TMPDIR": tmp,
                "SSH_AUTH_SOCK": "/private/tmp/com.apple.launchd.x/Listeners",
                "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
                "LANG": "en_US.UTF-8",
                "PATH": "/app/specific/bin:/usr/bin:/bin",
                "ESPALIER_SENTINEL": "1",
                "GIT_EXEC_PATH": "/espalier/git",
                "XPC_SERVICE_NAME": "application.espalier",
                "DYLD_LIBRARY_PATH": "/xcode/debug",
            ]

            let env = try successEnv(try await GitRuntime.withRuntime(runtime) { try await getShellEnv() })

            for name in ["SHELL", "HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "LANG"] {
                #expect(env[name] == runtime.processEnvironment[name], "\(name)")
            }
            for name in ["ESPALIER_SENTINEL", "GIT_EXEC_PATH", "XPC_SERVICE_NAME", "DYLD_LIBRARY_PATH"] {
                #expect(env[name] == nil, "\(name)")
            }
            #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
            #expect(try String(contentsOfFile: tmp + "/start-path", encoding: .utf8) == "/usr/bin:/bin:/usr/sbin:/sbin\n")
        }

        @Test("leaves out empty session variables")
        func emptySessionVariables() async throws {
            let shell = try makeStandInShell(#"eval "$2""#)
            var runtime = TestEnvironment.runtime
            runtime.processEnvironment = ["SHELL": shell, "HOME": "", "TMPDIR": ""]

            let env = try successEnv(try await GitRuntime.withRuntime(runtime) { try await getShellEnv() })

            #expect(env["HOME"] == nil)
            #expect(env["TMPDIR"] == nil)
        }

        @Test(
            "starts the shell with a terminal's UTF-8 LANG when the session has no locale",
            arguments: [
                NamedCase("no locale variables", [String: String]()),
                NamedCase("empty ones", ["LANG": "", "LC_ALL": "", "LC_CTYPE": ""]),
                NamedCase("only categories other than LC_CTYPE", ["LC_MESSAGES": "fr_FR.UTF-8", "LC_TIME": "de_DE.UTF-8"]),
            ]
        )
        func defaultLocale(_ testCase: NamedCase<[String: String]>) async throws {
            let shell = try makeStandInShell(#"""
                echo "$LANG" > "$TMPDIR/start-lang"
                eval "$2"
                """#)
            let tmp = try createTempDirectory()
            var runtime = TestEnvironment.runtime
            runtime.processEnvironment = testCase.value.merging(["SHELL": shell, "TMPDIR": tmp]) { $1 }

            let env = try successEnv(try await GitRuntime.withRuntime(runtime) { try await getShellEnv() })

            let expected = defaultTerminalLocale()
            #expect(expected.hasSuffix(".UTF-8"))
            #expect(env["LANG"] == expected)
            // The startup files see it, as in a terminal.
            #expect(try String(contentsOfFile: tmp + "/start-lang", encoding: .utf8) == expected + "\n")
            #expect(env["LC_ALL"] == nil)
            #expect(env["LC_CTYPE"] == nil)
            for name in ["LC_MESSAGES", "LC_TIME"] {
                #expect(env[name] == testCase.value[name], "\(name)")
            }
        }

        @Test(
            "keeps the session's locale",
            arguments: [
                NamedCase("LANG", ["LANG": "fr_FR.UTF-8"]),
                NamedCase("LC_ALL", ["LC_ALL": "de_DE.UTF-8"]),
                NamedCase("LC_CTYPE", ["LC_CTYPE": "UTF-8"]),
            ]
        )
        func sessionLocale(_ testCase: NamedCase<[String: String]>) async throws {
            let shell = try makeStandInShell(#"eval "$2""#)
            var runtime = TestEnvironment.runtime
            runtime.processEnvironment = testCase.value.merging(["SHELL": shell]) { $1 }

            let env = try successEnv(try await GitRuntime.withRuntime(runtime) { try await getShellEnv() })

            for name in ["LANG", "LC_ALL", "LC_CTYPE"] {
                #expect(env[name] == testCase.value[name], "\(name)")
            }
        }

        @Test("leaves the locale to the shell's startup files when they set one")
        func startupFilesLocale() async throws {
            let shell = try makeStandInShell(#"""
                export LANG=de_DE.UTF-8
                eval "$2"
                """#)
            var runtime = TestEnvironment.runtime
            runtime.processEnvironment = ["SHELL": shell]

            let env = try successEnv(try await GitRuntime.withRuntime(runtime) { try await getShellEnv() })

            #expect(env["LANG"] == "de_DE.UTF-8")
        }

        @Test("doesn't take the locale the app's own login shell loaded, which the startup files set again if they mean to")
        func shellLoadedLocale() async throws {
            let shell = try makeStandInShell(#"eval "$2""#)
            // As macOS's /etc/zprofile leaves a shell started without LANG.
            let loaded = ShellEnvironment { ["LANG": "C.UTF-8", "LC_ALL": "C"] }
            await loaded.waitUntilLoaded()
            let runtime = GitRuntime(
                gitDirectory: TestEnvironment.gitDirectory,
                processEnvironment: ["SHELL": shell, "HOME": "/Users/joe"],
                shellEnvironment: loaded
            )
            #expect(runtime.processEnvironment["LANG"] == "C.UTF-8")

            let env = try successEnv(try await GitRuntime.withRuntime(runtime) { try await getShellEnv() })

            #expect(env["LANG"] == defaultTerminalLocale())
            #expect(env["LC_ALL"] == nil)
            #expect(env["HOME"] == "/Users/joe")
        }

        @Test("runs the shell in the given directory")
        func runsInDirectory() async throws {
            let directory = try createTempDirectory()
            let shell = try makeStandInShell(#"eval "$2""#)

            let env = try successEnv(try await withShell(shell) { try await getShellEnv(directory) })

            #expect(env["PWD"] == directory)
        }

        @Test("returns the environment even when the shell then fails")
        func ignoresExitStatus() async throws {
            let shell = try makeStandInShell(#"""
                export ESPALIER_FROM_LOGIN=1
                eval "$2"
                exit 3
                """#)

            let env = try successEnv(try await withShell(shell) { try await getShellEnv() })

            #expect(env["ESPALIER_FROM_LOGIN"] == "1")
        }

        @Test("throws when the shell prints no environment")
        func throwsWithoutEnvironment() async throws {
            let shell = try makeStandInShell("echo 'the command never ran'")

            await #expect(throws: ShellEnvError.missingStartMarker) {
                try await withShell(shell) { try await getShellEnv() }
            }
        }

        @Test("throws when the shell can't be launched")
        func throwsForMissingShell() async throws {
            let error = await #expect(throws: ChildProcess.LaunchError.self) {
                try await withShell("/nonexistent/shell") { try await getShellEnv() }
            }
            #expect(error?.code == "ENOENT")
        }

        @Test("kills the shell when the task is cancelled", .hangGuard(minutes: 5))
        func cancellation() async throws {
            // Like an interactive shell, the stand-in ignores SIGTERM, and it
            // never ends on its own: the task ends only if the shell is
            // killed. It writes to a FIFO, and the test cancels once it has.
            let ready = POSIXPath.join(try createTempDirectory(), "ready")
            try #require(mkfifo(ready, 0o600) == 0)
            let shell = try makeStandInShell("""
                trap '' TERM
                printf x > '\(ready)'
                while :; do sleep 0.1; done
                """)
            let task = Task {
                try await withShell(shell) { try await getShellEnv() }
            }
            await waitForFIFOWriter(ready)
            task.cancel()

            let result = try await task.resultUnlessCancelled
            #expect(throws: CancellationError.self) {
                try result.get()
            }
        }
    }

    @Suite("terminalLocale")
    struct TerminalLocale {
        @Test(
            "is the language and region as a UTF-8 locale the system has, else en_US.UTF-8",
            arguments: [
                NamedCase("English in the United Kingdom", (language: "en", region: "GB", expected: "en_GB.UTF-8")),
                // macOS has no en_DE locale.
                NamedCase("English in Germany", (language: "en", region: "DE", expected: "en_US.UTF-8")),
                NamedCase("no region", (language: "fr", region: nil, expected: "en_US.UTF-8")),
                NamedCase("no language", (language: nil, region: "FR", expected: "en_US.UTF-8")),
            ] as [NamedCase<(language: String?, region: String?, expected: String)>]
        )
        func locale(_ testCase: NamedCase<(language: String?, region: String?, expected: String)>) {
            #expect(terminalLocale(language: testCase.value.language, region: testCase.value.region) == testCase.value.expected)
        }
    }
}
