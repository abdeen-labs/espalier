// The environment Espalier takes from the user's shell when it isn't
// started from a terminal: what the shell prints, real zsh and bash
// startup files, the variables that would point git at another repository,
// failures and the timeout, and how git's runtime layers the variables.

import EspalierSupport
import Foundation
@testable import GitKit
import Testing
import TestSupport

@Suite("Shell environment", .hangGuard(minutes: 5))
struct ShellTests {
    /// An environment like the one launchd gives an app, for a shell whose
    /// startup files are in `home`.
    private func launchEnvironment(shell: String, home: String) -> [String: String] {
        ["SHELL": shell, "HOME": home, "ZDOTDIR": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    private func write(_ contents: String, to path: String) throws {
        try Data(contents.utf8).write(to: URL(filePath: path))
    }

    @Test("parses the variables the shell prints", arguments: [
        // A naive regex would skip A and name the next variable "\0B", turn C's
        // empty value into a NUL, and lose D.
        NamedCase("parses every variable, including values with newlines, equals signs, or nothing", (
            output: "\u{0}A=x\ny\u{0}\u{0}B=z\u{0}\u{0}C=\u{0}\u{0}D=1=2\u{0}",
            expected: ["A": "x\ny", "B": "z", "C": "", "D": "1=2"]
        )),
        NamedCase("leaves out records without a name, and the variables that locate git", (
            output: "\u{0}=x\u{0}\u{0}garbage\u{0}\u{0}ESPALIER_GIT_DIR=/tmp/git\u{0}\u{0}LOCAL_GIT_DIRECTORY=/tmp/git\u{0}\u{0}E=e\u{0}",
            expected: ["E": "e"]
        )),
        NamedCase("leaves out where a repository is, and keeps git's configuration", (
            output: "\u{0}GIT_DIR=/r/.git\u{0}\u{0}GIT_WORK_TREE=/r\u{0}\u{0}GIT_INDEX_FILE=/r/i\u{0}\u{0}GIT_OBJECT_DIRECTORY=/r/o\u{0}"
                + "\u{0}GIT_CONFIG_COUNT=1\u{0}\u{0}GIT_CONFIG_KEY_0=a.b\u{0}\u{0}GIT_CONFIG_VALUE_0=c\u{0}\u{0}GIT_EDITOR=vim\u{0}",
            expected: ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "a.b", "GIT_CONFIG_VALUE_0": "c", "GIT_EDITOR": "vim"]
        )),
        NamedCase("leaves out the shell process's own directory, nesting level, and last command", (
            output: "\u{0}PWD=/\u{0}\u{0}OLDPWD=/Users/joe\u{0}\u{0}SHLVL=1\u{0}\u{0}_=/usr/bin/awk\u{0}\u{0}E=e\u{0}",
            expected: ["E": "e"]
        )),
        // A greeting, a variable echoed while debugging, and a logout file's
        // goodbye: without a NUL before a name, they're left out too.
        NamedCase("leaves out what startup files print before and after the variables", (
            output: "Welcome back\nPATH=/bogus\n\u{0}A=1\u{0}\u{0}B=2\u{0}NODE_ENV=dev\nbye\n",
            expected: ["A": "1", "B": "2"]
        )),
        NamedCase("leaves out what startup files print before and after the variables", (output: "PATH=/bogus\n", expected: [:])),
    ])
    func parses(_ testCase: NamedCase<(output: String, expected: [String: String])>) {
        #expect(parseShellEnvironment(Data(testCase.value.output.utf8)) == testCase.value.expected)
    }

    @Test("only an app started outside a terminal needs the shell's environment")
    func needsPatching() {
        #expect(shellNeedsPatching(["HOME": "/Users/joe"]))
        #expect(!shellNeedsPatching(["HOME": "/Users/joe", "PWD": "/Users/joe"]))
    }

    @Test("reads what zsh's startup files export")
    func zsh() async throws {
        let home = try createTempDirectory()
        try write("""
            export PATH="/opt/espalier-test/bin:$PATH"
            export ESPALIER_SHELL_TEST=$'two\\nlines'
            export ESPALIER_EMPTY=
            """, to: POSIXPath.join(home, ".zshrc"))

        let variables = try #require(await getEnvironmentFromShell(launchEnvironment(shell: "/bin/zsh", home: home)))
        #expect(variables["PATH"]?.hasPrefix("/opt/espalier-test/bin:") == true)
        #expect(variables["ESPALIER_SHELL_TEST"] == "two\nlines")
        #expect(variables["ESPALIER_EMPTY"] == "")
        #expect(variables["HOME"] == home)
        // The shell ran in the app's directory; git and hooks run in theirs.
        #expect(variables["PWD"] == nil)
        #expect(variables["_"] == nil)
    }

    @Test("ignores what zsh's startup files print to standard output")
    func zshPrints() async throws {
        let home = try createTempDirectory()
        try write("""
            echo "Last login: today"
            echo "PATH=/bogus"
            export ESPALIER_SHELL_TEST=printed
            """, to: POSIXPath.join(home, ".zshrc"))
        try write("echo \"NODE_ENV=leaving\"\n", to: POSIXPath.join(home, ".zlogout"))

        let variables = try #require(await getEnvironmentFromShell(launchEnvironment(shell: "/bin/zsh", home: home)))
        #expect(variables["ESPALIER_SHELL_TEST"] == "printed")
        #expect(variables["PATH"]?.contains("/bogus") == false)
        #expect(variables["PATH"]?.contains("/usr/bin") == true)
        #expect(variables["NODE_ENV"] == nil)
        #expect(!variables.keys.contains { $0.contains("Last login") || $0.contains("\n") })
    }

    @Test("reads what bash's login files export, and uses bash when SHELL is empty")
    func bash() async throws {
        let home = try createTempDirectory()
        try write("export ESPALIER_SHELL_TEST=from-bash\n", to: POSIXPath.join(home, ".bash_profile"))

        let variables = try #require(await getEnvironmentFromShell(launchEnvironment(shell: "/bin/bash", home: home)))
        #expect(variables["ESPALIER_SHELL_TEST"] == "from-bash")

        let fallback = try #require(await getEnvironmentFromShell(launchEnvironment(shell: "", home: home)))
        #expect(fallback["ESPALIER_SHELL_TEST"] == "from-bash")
    }

    @Test("git runs in its own repository whatever repository the shell's variables name")
    func repositoryLocation() async throws {
        let home = try createTempDirectory()
        let repository = try setupEmptyRepository().path
        let elsewhere = try setupEmptyRepository().path
        try write("""
            export GIT_DIR='\(elsewhere)/.git'
            export GIT_WORK_TREE='\(elsewhere)'
            export GIT_INDEX_FILE='\(elsewhere)/.git/index'
            export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=espalier.fromshell GIT_CONFIG_VALUE_0=yes
            """, to: POSIXPath.join(home, ".zshrc"))
        let environment = launchEnvironment(shell: "/bin/zsh", home: home)
        let shell = ShellEnvironment(scheduler: ManualScheduler()) {
            await getEnvironmentFromShell(environment)
        }
        await shell.waitUntilLoaded()
        var runtime = TestEnvironment.runtime
        runtime.shellEnvironment = shell

        try await GitRuntime.withRuntime(runtime) {
            let located = try await git(["rev-parse", "--absolute-git-dir", "--show-toplevel"], repository, "repositoryLocation")
            #expect(located.stdout == "\(POSIXPath.join(repository, ".git"))\n\(repository)\n")
            // The shell's configuration still applies.
            #expect(try await git(["config", "espalier.fromshell"], repository, "repositoryLocation").stdout == "yes\n")
        }

        // An index Espalier sets for a call still applies.
        let index = POSIXPath.join(try createTempDirectory(), "index")
        runtime.processEnvironment["GIT_INDEX_FILE"] = index
        try await GitRuntime.withRuntime(runtime) {
            let path = try await git(["rev-parse", "--git-path", "index"], repository, "repositoryLocation")
            #expect(path.stdout == index + "\n")
        }
    }

    @Test("gives nothing when the shell can't start, exits unsuccessfully, or takes too long")
    func failures() async throws {
        let home = try createTempDirectory()
        #expect(await getEnvironmentFromShell(launchEnvironment(shell: "/nonexistent/shell", home: home)) == nil)

        try write("exit 3\n", to: POSIXPath.join(home, ".zshrc"))
        #expect(await getEnvironmentFromShell(launchEnvironment(shell: "/bin/zsh", home: home)) == nil)

        try write("sleep 30\n", to: POSIXPath.join(home, ".zshrc"))
        let start = ContinuousClock.now
        let slow = await getEnvironmentFromShell(launchEnvironment(shell: "/bin/zsh", home: home), timeout: .milliseconds(500))
        // The timeout ended the shell: without it, the shell gives its
        // variables after 30 seconds.
        #expect(slow == nil)
        #expect(ContinuousClock.now - start >= .milliseconds(500))
    }

    @Test("loads once; a failed load means no variables")
    func loading() async {
        // The patience never runs out on a scheduler no one advances.
        let gate = AsyncGate()
        let shell = ShellEnvironment(scheduler: ManualScheduler()) {
            await gate.wait()
            return ["A": "1"]
        }
        #expect(shell.variables == nil)
        gate.open()
        await shell.waitUntilLoaded()
        #expect(shell.variables == ["A": "1"])

        let failed = ShellEnvironment(scheduler: ManualScheduler()) { nil }
        await failed.waitUntilLoaded()
        #expect(failed.variables == [:])
    }

    @Test("operations wait at most the patience; a slow shell's variables arrive later")
    func patience() async {
        let scheduler = ManualScheduler()
        let gate = AsyncGate()
        let shell = ShellEnvironment(patience: .seconds(5), scheduler: scheduler) {
            await gate.wait()
            return ["A": "1"]
        }

        // A waiter goes on once the patience has passed, without the
        // variables.
        let waiter = Task { await shell.waitUntilLoaded() }
        await scheduler.waitForSleepers()
        await scheduler.advance(by: .seconds(5))
        await waiter.value
        #expect(shell.variables == nil)

        // Later waiters don't wait at all; the variables still arrive.
        await shell.waitUntilLoaded()
        gate.open()
        // Nothing reports the load once waiters have stopped waiting for it.
        while shell.variables == nil, !Task.isCancelled {
            await Task.yield()
        }
        #expect(shell.variables == ["A": "1"])
    }

    @Test("a shell that loads within the patience is waited for")
    func loadsWithinPatience() async {
        let scheduler = ManualScheduler()
        let gate = AsyncGate()
        let shell = ShellEnvironment(patience: .seconds(5), scheduler: scheduler) {
            await gate.wait()
            return ["A": "1"]
        }
        let waiter = Task { await shell.waitUntilLoaded() }
        await scheduler.waitForSleepers()
        await scheduler.advance(by: .seconds(4))
        gate.open()
        await waiter.value
        #expect(shell.variables == ["A": "1"])
    }

    @Test("git's environment is the app's, then the shell's once loaded, then what was set for git")
    func runtimeLayers() async {
        let gate = AsyncGate()
        let shell = ShellEnvironment(scheduler: ManualScheduler()) {
            await gate.wait()
            return ["PATH": "/shell/bin", "FROM_SHELL": "1", "SET": "shell", "HOME": "/Users/shell"]
        }
        var runtime = GitRuntime(
            gitDirectory: URL(filePath: "/git", directoryHint: .isDirectory),
            processEnvironment: ["PATH": "/usr/bin", "HOME": "/Users/joe"],
            shellEnvironment: shell
        )
        runtime.processEnvironment["SET"] = "git"
        runtime.processEnvironment["HOME"] = nil
        #expect(runtime.processEnvironment == ["PATH": "/usr/bin", "SET": "git"])

        gate.open()
        await shell.waitUntilLoaded()
        #expect(runtime.processEnvironment == ["PATH": "/shell/bin", "FROM_SHELL": "1", "SET": "git"])

        runtime.processEnvironment["SET"] = "again"
        #expect(runtime.processEnvironment["SET"] == "again")
    }
}
