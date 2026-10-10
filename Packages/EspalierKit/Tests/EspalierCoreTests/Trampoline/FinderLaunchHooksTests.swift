// These run real git, real hooks, the real espalier-askpass, and the
// user's real login shell (zsh, bash, and fish when installed) on startup
// files written as Homebrew's, nvm's, and mise's installers write them, and
// check that hooks behave as they do when the user commits in a terminal.
// husky, lint-staged, and the pre-commit framework are stand-ins (see
// LoginSession.swift) that need what the real tools need: their own path,
// node or Python on PATH, `core.hooksPath`.

@testable import EspalierCore
import EspalierCoreTestSupport
import EspalierSupport
import Foundation
@testable import GitKit
import Synchronization
import Testing
import TestSupport

@Suite("Hooks in a Finder-launched app", .offline)
struct FinderLaunchHooksTests {
    /// The variables a hook must see as it would in a terminal.
    static let sessionVariables = ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "NVM_BIN", "HOMEBREW_PREFIX"]

    @Test(
        "hooks see the login shell's tools and the session as in a terminal, whether the hooks proxy or git runs them",
        arguments: LoginShellKind.installed
    )
    func environment(_ kind: LoginShellKind) async throws {
        let session = try LoginSession.make(kind)
        let repository = try setupEmptyRepository("main")
        let hooks = POSIXPath.join(repository.path, ".git/hooks")
        // pre-commit is intercepted: the hooks proxy runs it in a login
        // shell of its own. Git runs reference-transaction itself (through
        // Espalier's temporary hooks directory) and post-checkout directly.
        for hook in ["pre-commit", "reference-transaction", "post-checkout"] {
            try writeScript(POSIXPath.join(hooks, hook), """
                #!/bin/sh
                \(session.recordEnvironment(hook))
                command -v node > '\(session.output)/\(hook)-node'
                [ "\(hook)" = reference-transaction ] && cat > /dev/null
                exit 0
                """)
        }
        try Data("one\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "file.txt")))

        try await withLoginSession(session) { runtime in
            // As every operation does, wait for the shell's variables.
            await runtime.shellEnvironment?.waitUntilLoaded()
            let files = try #require(try await getStatus(repository)).workingDirectory.files
            _ = try await createCommit(repository, "First\n", files)
            _ = try await git(["checkout", "-b", "topic"], repository.path, "checkout")
        }

        let terminal = try await session.terminalEnvironment(in: repository.path)
        let terminalPath = pathWithoutGitAndHusky(terminal["PATH"])
        // The startup files did what their installers meant them to.
        #expect(Array(terminalPath.prefix(4)) == [
            session.miseShims,
            session.nodeBin,
            POSIXPath.join(session.homebrewPrefix, "bin"),
            POSIXPath.join(session.homebrewPrefix, "sbin"),
        ])

        for hook in ["pre-commit", "reference-transaction", "post-checkout"] {
            let seen = try session.hookEnvironment(hook)
            #expect(pathWithoutGitAndHusky(seen["PATH"]) == terminalPath, "\(hook)")
            for name in Self.sessionVariables {
                #expect(seen[name] == terminal[name], "\(hook): \(name)")
            }
            #expect(seen["ESPALIER"] == (hook == "pre-commit" ? "1" : nil), "\(hook)")
            let node = try String(contentsOfFile: POSIXPath.join(session.output, "\(hook)-node"), encoding: .utf8)
            #expect(node == POSIXPath.join(session.nodeBin, "node") + "\n", "\(hook)")
        }
    }

    @Test(
        "hooks get a terminal's UTF-8 locale and a terminal type when the session has neither: Ruby reads UTF-8 and tput works",
        arguments: LoginShellKind.installed
    )
    func localeAndTerminalType(_ kind: LoginShellKind) async throws {
        let session = try LoginSession.make(kind)
        #expect(session.launchEnvironment["LANG"] == nil && session.launchEnvironment["TERM"] == nil)
        let repository = try setupEmptyRepository("main")
        // 13 characters, 14 bytes.
        try Data("puts \"h\u{E9}llo\"\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "greeting.rb")))
        try writeScript(POSIXPath.join(repository.path, ".git/hooks/pre-commit"), """
            #!/bin/sh
            \(session.recordEnvironment("pre-commit"))
            wc -m < greeting.rb | tr -d ' ' > '\(session.output)/characters'
            tput cols > /dev/null 2>&1
            echo $? > '\(session.output)/tput'
            if [ -x /usr/bin/ruby ]; then
              /usr/bin/ruby -e 'print File.read("greeting.rb").scan(/\\u00e9/).length' > '\(session.output)/ruby' 2> '\(session.output)/ruby-errors'
            fi
            exit 0
            """)

        // What the login shell's startup files do without a LANG (macOS's
        // /etc/zprofile sets C.UTF-8 for zsh), which the app's own shell
        // environment then has.
        let startupLanguage = try await session.loginShellLanguage()

        try await withLoginSession(session) { runtime in
            await runtime.shellEnvironment?.waitUntilLoaded()
            #expect(runtime.processEnvironment["LANG"] == startupLanguage)
            let files = try #require(try await getStatus(repository)).workingDirectory.files
            _ = try await createCommit(repository, "First\n", files)
        }

        // The hooks' shell starts with a terminal's LANG all the same, which
        // a default in the startup files leaves alone.
        let seen = try session.hookEnvironment("pre-commit")
        #expect(seen["LANG"] == defaultTerminalLocale())
        #expect(seen["LANG"]?.hasSuffix(".UTF-8") == true)
        // Not the LC_CTYPE git itself may get.
        #expect(seen["LC_CTYPE"] == nil)
        #expect(seen["TERM"] == "dumb")
        func output(_ name: String) throws -> String {
            try String(contentsOfFile: POSIXPath.join(session.output, name), encoding: .utf8)
        }
        #expect(try output("characters") == "13\n")
        #expect(try output("tput") == "0\n")
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/ruby") {
            // Without a locale, Ruby reads the file as US-ASCII and fails
            // with "invalid byte sequence in US-ASCII".
            #expect(try output("ruby") == "1", "\((try? output("ruby-errors")) ?? "")")
        }
    }

    @Test("a locale the session has, and a locale or terminal type the startup files set, stay as they are")
    func sessionLocaleAndTerminalType() async throws {
        let base = try LoginSession.make(.zsh, startupLines: "export TERM=vt100")
        var launchEnvironment = base.launchEnvironment
        launchEnvironment["LC_ALL"] = "fr_FR.UTF-8"
        let session = LoginSession(kind: base.kind, home: base.home, output: base.output, shell: base.shell, launchEnvironment: launchEnvironment)
        let shellSetsLanguage = try LoginSession.make(.zsh, startupLines: "export LANG=pt_BR.UTF-8")
        for each in [session, shellSetsLanguage] {
            let repository = try setupEmptyRepository("main")
            try writeScript(POSIXPath.join(repository.path, ".git/hooks/pre-commit"), """
                #!/bin/sh
                \(each.recordEnvironment("pre-commit"))
                """)
            try Data("one\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "file.txt")))
            try await withLoginSession(each) { runtime in
                await runtime.shellEnvironment?.waitUntilLoaded()
                let files = try #require(try await getStatus(repository)).workingDirectory.files
                _ = try await createCommit(repository, "First\n", files)
            }
        }

        // With LC_ALL, Espalier adds no LANG: hooks get what the startup
        // files set without one, as in a terminal.
        let seen = try session.hookEnvironment("pre-commit")
        let startupLanguage = try await session.loginShellLanguage()
        #expect(seen["LC_ALL"] == "fr_FR.UTF-8")
        #expect(seen["LANG"] == startupLanguage)
        #expect(seen["LANG"] != defaultTerminalLocale())
        #expect(seen["TERM"] == "vt100")
        let shellSet = try shellSetsLanguage.hookEnvironment("pre-commit")
        #expect(shellSet["LANG"] == "pt_BR.UTF-8")
        #expect(shellSet["TERM"] == "dumb")
    }

    @Test(
        "hooks git runs itself read and write UTF-8: the login shell's locale, else a terminal's character set",
        arguments: LoginShellKind.installed
    )
    func directHooksCharacterSet(_ kind: LoginShellKind) async throws {
        let session = try LoginSession.make(kind)
        let repository = try setupEmptyRepository("main")
        for hook in ["reference-transaction", "post-checkout"] {
            try writeScript(POSIXPath.join(repository.path, ".git/hooks/\(hook)"), """
                #!/bin/sh
                \(session.recordEnvironment(hook))
                /usr/bin/locale charmap > '\(session.output)/\(hook)-charmap'
                [ "\(hook)" = reference-transaction ] && cat > /dev/null
                exit 0
                """)
        }
        try Data("one\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "file.txt")))

        // macOS's /etc/zprofile sets C.UTF-8 for zsh; bash's startup files
        // set none.
        let startupLanguage = try await session.loginShellLanguage()

        try await withLoginSession(session) { runtime in
            await runtime.shellEnvironment?.waitUntilLoaded()
            let files = try #require(try await getStatus(repository)).workingDirectory.files
            _ = try await createCommit(repository, "First\n", files)
            _ = try await git(["checkout", "-b", "topic"], repository.path, "checkout")
        }

        for hook in ["reference-transaction", "post-checkout"] {
            let seen = try session.hookEnvironment(hook)
            #expect(seen["LANG"] == startupLanguage, "\(hook)")
            #expect(seen["LC_CTYPE"] == (startupLanguage == nil ? defaultTerminalLocale() : nil), "\(hook)")
            let charmap = try String(contentsOfFile: POSIXPath.join(session.output, "\(hook)-charmap"), encoding: .utf8)
            #expect(charmap == "UTF-8\n", "\(hook)")
        }
    }

    @Test("husky 9 with lint-staged: eslint's failure is shown; Abort keeps the commit out, Continue lands it", .hangGuard(minutes: 5))
    @MainActor
    func huskyLintStaged() async throws {
        let session = try LoginSession.make(.zsh)
        let local = try setupEmptyRepository("main")
        try await installHuskyWithLintStaged(in: local)

        try await withLoginSession(session) { runtime in
            let harness = try AppHarness(
                responder: PromptResponder.answering([.hookFailure(.abort), .hookFailure(.ignore)]),
                git: runtime
            )
            let app = await harness.loadedApp()
            let repository = try await harness.addAndSelect(local, to: app)
            try harness.write("src/app.js", "const answer = 42;\ndebugger;\n", in: local)
            await repository.refresh(.status, reason: .user)
            repository.commit.draft.summary = "Add the app"

            let aborted = await #expect(throws: OperationError.self) { try await repository.commit.commit() }
            #expect(aborted?.reason == .cancelled(.hookAborted("pre-commit")))
            #expect(try await commitCount(local) == 0)
            #expect(repository.commit.draft.summary == "Add the app")

            _ = try await repository.commit.commit()
            #expect(try await commitCount(local) == 1)

            #expect(harness.prompts.history.count == 2)
            for prompt in harness.prompts.history {
                guard case .hookFailed(let name, let output) = prompt else {
                    Issue.record("Unexpected prompt \(prompt)")
                    continue
                }
                #expect(name == "pre-commit")
                // eslint's output, lint-staged's, and husky's, as a terminal
                // shows them.
                #expect(output.contains("src/app.js\n  2:1  error  Unexpected 'debugger' statement  no-debugger"))
                #expect(output.contains("[FAILED] eslint [FAILED]"))
                #expect(output.contains("husky - pre-commit script failed (code 1)"))
                #expect(!output.contains("command not found"))
            }

            // Fixed, the commit goes through without asking.
            try harness.write("src/app.js", "const answer = 42;\n", in: local)
            await repository.refresh(.status, reason: .user)
            repository.commit.draft.summary = "Remove the debugger statement"
            _ = try await repository.commit.commit()
            #expect(try await commitCount(local) == 2)
            #expect(harness.prompts.history.count == 2)
            await app.idle()
        }
    }

    @Test("husky runs hooks git runs itself, finding the user's script from its own path")
    func huskyPostCheckout() async throws {
        let session = try LoginSession.make(.zsh)
        let repository = try setupEmptyRepository("main")
        try await installHuskyWithLintStaged(in: repository)
        try writeTextFile(POSIXPath.join(repository.path, ".husky/post-checkout"), """
            \(session.recordEnvironment("post-checkout"))
            command -v node > '\(session.output)/node'
            """)
        try Data("one\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "file.txt")))

        try await withLoginSession(session) { runtime in
            await runtime.shellEnvironment?.waitUntilLoaded()
            let files = try #require(try await getStatus(repository)).workingDirectory.files
            _ = try await createCommit(repository, "First\n", files)
            _ = try await git(["checkout", "-b", "topic"], repository.path, "checkout")
        }

        let seen = try session.hookEnvironment("post-checkout")
        #expect(seen["PATH"]?.hasPrefix("node_modules/.bin:") == true)
        #expect(pathWithoutGitAndHusky(seen["PATH"]).contains(session.nodeBin))
        #expect(try String(contentsOfFile: POSIXPath.join(session.output, "node"), encoding: .utf8) == POSIXPath.join(session.nodeBin, "node") + "\n")
    }

    @Test(
        "the pre-commit framework finds itself from $0, runs its Python through mise, and fails or passes with ruff's output",
        arguments: LoginShellKind.installed
    )
    func preCommitFramework(_ kind: LoginShellKind) async throws {
        let session = try LoginSession.make(kind)
        let repository = try setupEmptyRepository("main")
        try installPreCommit(in: repository, session: session, legacyHook: "echo 'the previous hook ran' > '\(session.output)/legacy'")
        try Data("import pdb\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "tool.py")))
        let failures = Mutex<[String]>([])
        let progress = HookProgressLog()

        try await withLoginSession(session) { runtime in
            await runtime.shellEnvironment?.waitUntilLoaded()
            let files = try #require(try await getStatus(repository)).workingDirectory.files
            let options = CreateCommitOptions(onHookProgress: progress.callback, onHookFailure: { hookName, output in
                failures.withLock { $0.append("\(hookName)\n\(output)") }
                return .abort
            })
            await #expect(throws: GitError.self) {
                try await createCommit(repository, "Add the tool\n", files, options)
            }

            try Data("print('hello')\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "tool.py")))
            let fixed = try #require(try await getStatus(repository)).workingDirectory.files
            _ = try await createCommit(repository, "Add the tool\n", fixed, options)
        }

        let failure = try #require(failures.withLock { $0 }.first)
        #expect(failures.withLock { $0 }.count == 1)
        #expect(failure.hasPrefix("pre-commit\n"))
        #expect(failure.contains("ruff.....................................................Failed"))
        #expect(failure.contains("tool.py:1:1: T100 Trace found: pdb used"))
        #expect(!failure.contains("not found"))
        // The hook found its own directory from $0, where pre-commit keeps
        // the hook it replaced.
        #expect(try String(contentsOfFile: POSIXPath.join(session.output, "legacy"), encoding: .utf8) == "the previous hook ran\n")
        #expect(progress.events == ["started pre-commit", "failed pre-commit", "started pre-commit", "finished pre-commit"])
        #expect(try await commitCount(repository) == 1)
    }

    @Test("the pre-commit framework's Abort and Continue through the commit model", .hangGuard(minutes: 5))
    @MainActor
    func preCommitFrameworkPrompt() async throws {
        let session = try LoginSession.make(.zsh)
        let local = try setupEmptyRepository("main")
        try installPreCommit(in: local, session: session)

        try await withLoginSession(session) { runtime in
            let harness = try AppHarness(
                responder: PromptResponder.answering([.hookFailure(.abort), .hookFailure(.ignore)]),
                git: runtime
            )
            let app = await harness.loadedApp()
            let repository = try await harness.addAndSelect(local, to: app)
            try harness.write("tool.py", "import pdb\n", in: local)
            await repository.refresh(.status, reason: .user)
            repository.commit.draft.summary = "Add the tool"

            let aborted = await #expect(throws: OperationError.self) { try await repository.commit.commit() }
            #expect(aborted?.reason == .cancelled(.hookAborted("pre-commit")))
            #expect(try await commitCount(local) == 0)

            _ = try await repository.commit.commit()
            #expect(try await commitCount(local) == 1)
            for prompt in harness.prompts.history {
                guard case .hookFailed(_, let output) = prompt else {
                    Issue.record("Unexpected prompt \(prompt)")
                    continue
                }
                #expect(output.contains("tool.py:1:1: T100 Trace found: pdb used"))
            }
            await app.idle()
        }
    }

    @Test(
        "startup files that print to standard output change neither git's environment nor the hooks'",
        arguments: LoginShellKind.installed
    )
    func printingStartupFiles(_ kind: LoginShellKind) async throws {
        let session = try LoginSession.make(kind, startupLines: """
            echo "Welcome back, joe"
            echo "PATH=/bogus"
            echo "--printenvz--end"
            """)
        let repository = try setupEmptyRepository("main")
        let hooks = POSIXPath.join(repository.path, ".git/hooks")
        for hook in ["pre-commit", "reference-transaction"] {
            try writeScript(POSIXPath.join(hooks, hook), """
                #!/bin/sh
                \(session.recordEnvironment(hook))
                [ "\(hook)" = reference-transaction ] && cat > /dev/null
                exit 0
                """)
        }
        try Data("one\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "file.txt")))

        try await withLoginSession(session) { runtime in
            await runtime.shellEnvironment?.waitUntilLoaded()
            let shellVariables = try #require(runtime.shellEnvironment?.variables)
            #expect(!shellVariables.keys.contains { $0.contains("Welcome") || $0.contains("\n") })
            let files = try #require(try await getStatus(repository)).workingDirectory.files
            _ = try await createCommit(repository, "First\n", files)
        }

        let terminal = try await session.terminalEnvironment(in: repository.path)
        for hook in ["pre-commit", "reference-transaction"] {
            let seen = try session.hookEnvironment(hook)
            #expect(pathWithoutGitAndHusky(seen["PATH"]) == pathWithoutGitAndHusky(terminal["PATH"]), "\(hook)")
            #expect(seen["PATH"]?.contains("/bogus") == false, "\(hook)")
            #expect(seen["NVM_BIN"] == session.nodeBin, "\(hook)")
        }
    }

    @Test("a slow login shell: operations go on without it after 5 seconds and get its variables once it has loaded; hooks wait for it", .hangGuard(minutes: 5))
    @MainActor
    func slowShell() async throws {
        let session = try LoginSession.make(.zsh, startupLines: """
            while [ ! -e "$HOME/.go" ]; do sleep 0.05; done
            """)
        let local = try setupEmptyRepository("main")
        try writeScript(POSIXPath.join(local.path, ".git/hooks/pre-commit"), """
            #!/bin/sh
            \(session.recordEnvironment("pre-commit"))
            """)
        let scheduler = ManualScheduler()
        let launchEnvironment = session.launchEnvironment
        // Only the test's file ends the shell's wait, however long the
        // test takes to get there.
        let shellEnvironment = ShellEnvironment(scheduler: scheduler) {
            await getEnvironmentFromShell(launchEnvironment, timeout: .seconds(3600))
        }

        try await withLoginSession(session, shellEnvironment: shellEnvironment) { runtime in
            let harness = try AppHarness(git: runtime)
            let app = await harness.loadedApp()
            let repository = try await harness.addAndSelect(local, to: app)
            let printShellVariable = { @MainActor () async throws -> String in
                try await repository.perform(OperationDescriptor(kind: .commit)) { ctx in
                    try await git(["-c", "alias.e=!printenv NVM_BIN; true", "e"], ctx.repository.path, "printenv").stdout
                }
            }

            // The shell is still loading: after 5 seconds, the operation goes
            // on with launchd's environment.
            let early = Task { @MainActor in try await printShellVariable() }
            await scheduler.waitForSleepers()
            await scheduler.advance(by: .seconds(5))
            #expect(try await early.value == "")
            #expect(shellEnvironment.variables == nil)

            // A commit's hook loads a login shell of its own, and waits for
            // it, as long as it takes.
            try harness.write("file.txt", "one\n", in: local)
            await repository.refresh(.status, reason: .user)
            repository.commit.draft.summary = "First"
            let commit = Task { @MainActor in try await repository.commit.commit() }
            await waitUntilObserved { repository.localOperation?.hook?.name == "pre-commit" }
            try Data().write(to: URL(filePath: POSIXPath.join(session.home, ".go")))
            _ = try await commit.value
            #expect(try session.hookEnvironment("pre-commit")["NVM_BIN"] == session.nodeBin)

            // Once loaded, operations get the shell's variables. Nothing
            // reports the load once operations have stopped waiting for it.
            while shellEnvironment.variables == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(try await printShellVariable() == session.nodeBin + "\n")
            await app.idle()
        }
    }

    @Test("aborting a hook while its login shell loads ends the commit at once", .hangGuard(minutes: 5))
    func abortWhileShellLoads() async throws {
        let session = try LoginSession.make(.zsh, startupLines: """
            [ -n "$ESPALIER_SLOW" ] || { while [ ! -e "$HOME/.go" ]; do sleep 0.05; done; }
            """)
        let repository = try setupEmptyRepository("main")
        try writeScript(POSIXPath.join(repository.path, ".git/hooks/pre-commit"), """
            #!/bin/sh
            touch '\(session.output)/ran'
            """)
        try Data("one\n".utf8).write(to: URL(filePath: POSIXPath.join(repository.path, "file.txt")))
        // Git's own environment loads at once; only the hooks' login shell,
        // which starts without ESPALIER_SLOW, is slow.
        var launchEnvironment = session.launchEnvironment
        launchEnvironment["ESPALIER_SLOW"] = "1"
        let shellEnvironment = ShellEnvironment(scheduler: ManualScheduler()) { [launchEnvironment] in
            await getEnvironmentFromShell(launchEnvironment, timeout: .seconds(3600))
        }
        let aborts = Mutex<[@Sendable () -> Void]>([])
        let started = AsyncEvent<Void>()

        try await withLoginSession(session, shellEnvironment: shellEnvironment) { runtime in
            await shellEnvironment.waitUntilLoaded()
            let files = try #require(try await getStatus(repository)).workingDirectory.files
            let commit = Task {
                try await GitRuntime.withRuntime(runtime) {
                    try await createCommit(repository, "First\n", files, CreateCommitOptions(onHookProgress: { progress in
                        if case .started(_, let abort) = progress {
                            aborts.withLock { $0.append(abort) }
                            started.resolve()
                        }
                    }))
                }
            }
            try await started.wait()
            aborts.withLock { $0 }.forEach { $0() }
            let error = await #expect(throws: GitError.self) { try await commit.value }
            #expect(error?.result.stderr.contains("hook pre-commit aborted") == true)
        }

        try Data().write(to: URL(filePath: POSIXPath.join(session.home, ".go")))
        #expect(!FileManager.default.fileExists(atPath: POSIXPath.join(session.output, "ran")))
        #expect(try await commitCount(repository) == 0)
    }
}

/// The number of commits on HEAD (0 on an unborn branch).
private func commitCount(_ repository: Repository) async throws -> Int {
    let result = try await Dugite.exec(["rev-list", "--count", "HEAD"], repository.path)
    return Int(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}
